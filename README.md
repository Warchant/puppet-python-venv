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

The venv path (e.g. `/opt/app/.venv`) is a symlink to a build in a sibling directory
(`/opt/app/.venv.builds/<id>/`). How a venv is built (on first run, on any change, and on
any failed check):

1. A new venv is created in a new build directory with `python -m venv`; pip is
   upgraded (best effort). The active venv is not touched.
2. All requirements are installed with one `pip install -r ... -r ...`.
3. Everything is flushed to disk (`sync -f <build>`, or `sync`).
4. Every file listed in every `RECORD` is hashed and compared.
5. The commit marker (`.requirements_state`) is written atomically (temp file, fsync,
   rename, fsync directory).
6. The venv path is switched to the new build with one `rename` of a symlink, and the
   parent directory is fsynced.
7. Old builds are deleted.

Applications using the venv path see either the old venv or the new one, never a partial
one. If any step fails, the build is retried once with `--no-cache-dir` (in case a cached
wheel is corrupted); if it fails again, the failed build is deleted, the resource fails,
and **the previous venv stays active**. The next run tries again. A power loss at any point
leaves the previous venv active; the unfinished build is deleted on the next run.

A rebuild needs disk space for two venvs. Processes already running keep the modules
they imported; restart them to use the new venv, for example with
`notify => Service['myapp']` on the `python_venv` resource.

Venvs created by 0.1.0 (a real directory at the venv path) are verified and kept in place;
the first rebuild moves them out and replaces them with a symlink.

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

- `path` (namevar): absolute path to the virtualenv directory.
- `ensure`: `present` (default) or `absent`.
- `python_executable`: Python binary for venv creation. Default: `python3`.
- `system_site_packages`: `true`/`false` (default `false`). if `true` - adds `--system-site-packages` flag to `pip install`
- `requirements`: array of requirement specs (for example `['httpx==0.27.0']`).
- `requirements_files`: array of absolute paths to requirements files.
- `pip_args`: extra args appended to the `pip install` command for requirements.
- `verify`: per-run check of installed files: `size` (default), `hash` or `none`.
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
