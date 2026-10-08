# Changelog

All notable changes to this project will be documented in this file.

## Release 0.1.3

**Bugfixes**

- Verification after install always failed for a wheel that ships a `.pyc` file, for
  example numpy 1.26.4 (`numpy/distutils/__pycache__/conv_template.cpython-310.pyc`):
  `size 8281, expected 8269`. pip compiles the `.pyc` again after it unpacks the wheel,
  so the file never matches the wheel's `RECORD` row. The retry without the pip cache
  failed the same way, and the venv was never built. The verifier now checks only that
  a `.pyc` file exists. pip records the `.pyc` files that it compiles without hash and
  size, so this check was already presence-only for all other `.pyc` files.

## Release 0.1.2

**Features**

- New `combined` parameter. `true` (default) installs all `requirements_files` and
  `requirements` with one `pip install`, as in 0.1.1. `false` runs one `pip install`
  for each requirements file, in order, then one for `requirements`, as in 0.1.0.

**Bugfixes**

- A hash-pinned requirements file combined with files or `requirements` without hashes
  failed with `Hashes are required in --require-hashes mode`: pip turns on
  `--require-hashes` for the whole `pip install` call. Set `combined => false` to
  install each file with its own `pip install`.

## Release 0.1.1

Guarantees that a `python_venv` reported as in sync is fully installed, flushed to
disk and verified. Fixes 0-byte / truncated files and `ImportError`s after power loss
or disk corruption going undetected.

**Features**

- Every installed file is verified against its package's `RECORD` (sha256 and size)
  after each install, before the venv is committed.
- New `verify` parameter selects the check on every run: `size` (default, stat-only),
  `hash` (full sha256) or `none`.
- Installed files are flushed to disk (`sync -f`, falling back to `sync`) before the
  venv is committed; the state file is written atomically (temp file, fsync, rename,
  fsync directory) and serves as the commit marker.
- Any change or failed check rebuilds the venv from scratch. A failed build is retried
  once with `--no-cache-dir`, in case a cached wheel is corrupted.
- New `atomic` parameter. `false` (default) rebuilds in place: one venv on disk.
  `true` builds the new venv next to the active one (`.<name>.builds/<id>`) and
  atomically switches the venv path (a symlink) to it: applications see the old venv or
  the new one, never a partial one, and a failed build leaves the previous venv active,
  at the cost of disk space for two venvs during a rebuild.
- The interpreter (version and real path) and `system_site_packages` are recorded;
  a change triggers a rebuild.
- Venvs created by 0.1.0 with matching requirements are adopted without reinstalling
  if they pass full verification, otherwise they are rebuilt.
- Tested on Puppet 7 and 8 (CI matrix); the inline verifier is tested with a real
  Python 3.9.

**Bugfixes**

- A failing check (e.g. `pip freeze` crashing because of a corrupted file) was treated
  as "in sync"; all checks now fail closed.
- If `pip freeze` failed during install, drift detection was disabled for good.
- Reinstalling did not use `--force-reinstall`, so corrupted files of already-installed
  versions were never repaired. Rebuilding from scratch replaces this.
- Recreating an incomplete venv kept the old `site-packages` and state file.
- Removing a file from `requirements_files` was not detected.
- `ensure => absent` and the zero-sized venv cleanup called the non-existent
  `Puppet::FileSystem.rmtree`.
- A failed install was logged as `requirements_state changed 'out_of_sync' to 'insync'`
  before the error. The rebuild now runs as the property change, so only the failure is
  reported.

**Behavior changes**

- All requirements files are installed with a single `pip install -r ... -r ...`, so
  one resolver sees every requirement. Conflicting pins across files now fail instead
  of the last file winning.
- With the default `atomic => false`, a rebuild deletes the venv first: it is unusable
  during the rebuild, and stays unusable (reported as failed) if the rebuild fails, e.g.
  without network.
- Each Puppet run executes the venv's Python once to verify the venv (instead of
  `pip freeze`).

## Release 0.1.0

**Features**

**Bugfixes**

**Known Issues**
