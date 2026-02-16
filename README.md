# python_venv

[![codecov](https://codecov.io/gh/warchantua/puppet-python-venv/branch/main/graph/badge.svg)](https://codecov.io/gh/warchantua/puppet-python-venv)

Manage Python virtual environments with deterministic dependency state in Puppet.

> To activate this badge, enable Codecov for this repository. If the repo is private,
> add `CODECOV_TOKEN` in repository secrets.

This module provides the custom resource type `python_venv`, which:

- creates and removes venvs;
- installs dependencies from one or many `requirements.txt` files;
- supports additional individual dependencies;
- tracks dependency state and detects drift between Puppet runs.


## Compatibility

- Puppet: 7.x (`>= 7.24 < 9.0.0`)
- OS: Linux only
- Scope: Linux distro-independent (no distro-specific logic in the resource type)

## What "deterministic state" means here

`python_venv` stores an internal state file in the venv and compares it on every run.
If the expected dependency inputs or installed package state changes, Puppet re-syncs the
environment so the venv converges back to what is declared.

In practice, your manifest is the source of truth for the venv content.

## Resource reference: `python_venv`

### Parameters

- `path` (namevar): absolute path to the virtualenv directory.
- `ensure`: `present` (default) or `absent`.
- `python_executable`: Python binary for venv creation. Default: `python3`.
- `system_site_packages`: `true`/`false` (default `false`). if `true` - adds `--system-site-packages` flag to `pip install`
- `requirements`: array of requirement specs (for example `['httpx==0.27.0']`).
- `requirements_files`: array of absolute paths to requirements files.
- `pip_args`: extra args appended to `pip install` commands.

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
