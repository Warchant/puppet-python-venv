# python_venv

[![codecov](https://codecov.io/github/Warchant/puppet-python-venv/graph/badge.svg?token=C3U1bn63qx)](https://codecov.io/github/Warchant/puppet-python-venv)

Manage Python virtual environments with deterministic dependency state in Puppet.

> To activate this badge, enable Codecov for this repository. If the repo is private,
> add `CODECOV_TOKEN` in repository secrets.

This module provides the custom resource type `python_venv`, which:

- creates and removes venvs;
- installs dependencies from one or many `requirements.txt` files;
- supports additional individual dependencies;
- tracks dependency state and detects drift between Puppet runs.


## Compatibility

- Puppet: 7.x and 8.x (`>= 7.24 < 9.0.0`)
- Ruby: 3.1 and 3.2. CI tests Puppet 7 on Ruby 3.1.5 and Puppet 8 on Ruby 3.2.
  Ruby 4.0 is not supported: Puppet 8 does not install on it (facter requires Ruby < 4.0).
- Python: 3.9 or newer on the managed node (CI tests 3.9)
- OS: Linux only
- Scope: Linux distro-independent (no distro-specific logic in the resource type)

## What "deterministic state" means here

A `python_venv` reported as in sync means: the venv was built from the declared inputs,
every installed file was flushed to disk and verified against its package's `RECORD`
(sha256), and it still passes the per-run check.

How a venv is built (on first run, on any change, and on any failed check):

1. A new venv is created with `python -m venv`; pip is upgraded (best effort).
2. All requirements are installed with one `pip install -r ... -r ...`.
3. Everything is flushed to disk (`sync -f <venv>`, or `sync`).
4. Every file listed in every `RECORD` is hashed and compared.
5. The commit marker (`.requirements_state`) is written atomically (temp file, fsync,
   rename, fsync directory).

If any step fails, the build is retried once with `--no-cache-dir` (in case a cached
wheel is corrupted); if it fails again, the resource fails and no new marker is written,
so the next run tries again.

Where the new venv is built depends on `atomic`:

| | `atomic => false` (default) | `atomic => true` |
|---|---|---|
| Rebuild | delete the venv (marker first), build at the venv path | build in `.<name>.builds/<id>/` next to it, then switch the venv path (a symlink) with one `rename` and fsync the parent |
| Disk space | one venv | two venvs during a rebuild |
| During a rebuild | venv unavailable | old venv in use |
| Failed rebuild / power loss | no venv until a later run succeeds | old venv stays active; the unfinished build is deleted on the next run |

Use `atomic => true` for venvs that must stay available and where the disk has room for a
second copy. Changing `atomic` takes effect at the next rebuild, which converts the layout
(and removes `.<name>.builds/` when switching back to `false`). Point applications at the
venv path, never at a build directory: builds are deleted when replaced.

Processes already running keep the modules they imported; restart them to use the new
venv, for example with `notify => Service['myapp']` on the `python_venv` resource.

Venvs created by 0.1.0 are verified and kept in place. With `atomic => true`, their first
rebuild moves the directory out and puts the symlink in its place; this one-time migration
takes two renames, so for a moment the venv path does not exist. Every rebuild after that
is a single atomic rename.

On every run the marker is compared with the declared inputs and the interpreter, and
the venv is checked according to `verify`:

| `verify`         | per-run check                                   | catches                               |
|------------------|-------------------------------------------------|---------------------------------------|
| `size` (default) | `stat` every file in `RECORD`, compare its size | missing, zero-sized, truncated files  |
| `hash`           | sha256 of every file in `RECORD`                | any content change (reads whole venv) |
| `none`           | inputs and marker only                          | changed requirements                  |

Packages installed, removed or changed outside Puppet are detected with `size` and `hash`.

> Bytecode created at runtime (`__pycache__` files not listed in `RECORD`) is not verified.
> Use the venv path, not a build directory: builds are deleted when replaced.

In practice, your manifest is the source of truth for the venv content.

## Resource reference: `python_venv`

### Parameters

- `path` (namevar): absolute path of the venv. With `atomic => true` it is a symlink to the
  active build in `.<name>.builds/` next to it; point applications at this path.
- `ensure`: `present` (default) or `absent`.
- `python_executable`: Python binary for venv creation. Default: `python3`.
- `system_site_packages`: `true`/`false` (default `false`). if `true` - adds `--system-site-packages` flag to `pip install`
- `requirements`: array of requirement specs (for example `['httpx==0.27.0']`).
- `requirements_files`: array of absolute paths to requirements files.
- `pip_args`: extra args appended to the `pip install` command for requirements.
- `verify`: per-run check of installed files: `size` (default), `hash` or `none`.
  See [What "deterministic state" means here](#what-deterministic-state-means-here).
- `atomic`: `false` (default) rebuilds in place; `true` builds next to the active venv and
  switches atomically (needs space for two venvs).
  See [What "deterministic state" means here](#what-deterministic-state-means-here).

> Note: `requirements_state` is an internal property used by the provider. Do not set it manually.

## Usage

### 1) Minimal venv

```puppet
python_venv { '/opt/apps/myapp/.venv':
  ensure => present,
}
```

### 2) One requirements file

```puppet
python_venv { '/opt/apps/myapp/.venv':
  ensure             => present,
  python_executable  => '/usr/bin/python3',
  requirements_files => ['/opt/apps/myapp/requirements.txt'],
}
```

### 3) Multiple requirements files + individual dependencies

```puppet
python_venv { '/opt/apps/myapp/.venv':
  ensure               => present,
  python_executable    => '/usr/bin/python3',
  system_site_packages => false,
  requirements_files   => [
    '/opt/apps/myapp/requirements/base.txt',
    '/opt/apps/myapp/requirements/prod.txt',
  ],
  requirements         => [
    'gunicorn==22.0.0',
    'uvicorn[standard]==0.30.6',
  ],
  pip_args             => ['--no-cache-dir'],
}
```

### 4) Remove a venv

```puppet
python_venv { '/opt/apps/myapp/.venv':
  ensure => absent,
}
```

## Notes

- `requirements_files` must be absolute paths.
- The provider auto-requires files listed in `requirements_files`.
- If no dependencies are set, the venv is created without package installation.
