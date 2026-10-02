# Changelog

All notable changes to this project will be documented in this file.

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
- Repairing a venv deletes it first: the venv is unusable during a rebuild, and stays
  unusable (and reported as failed) if the rebuild fails, e.g. without network.
- Each Puppet run executes the venv's Python once to verify the venv (instead of
  `pip freeze`).

## Release 0.1.0

**Features**

**Bugfixes**

**Known Issues**
