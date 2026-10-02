#!/usr/bin/env bash
# End-to-end test of python_venv with real puppet, python and pip (needs network for PyPI).
#
#   docker run --rm -v "$PWD:/app" -w /app <image with puppet 7 + python3-venv> spec/e2e/e2e.sh
#
# Optional: LEGACY_LIBDIR=<path to module 0.1.0 lib/> to test adoption of 0.1.0 venvs.
set -euo pipefail

MODULE_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$(mktemp -d)"
VENV="$WORK/venv"
REQ="$WORK/requirements.txt"
LOG="$WORK/puppet.log"
mkdir -p "$WORK/modules"
chmod 777 "$WORK" # rebuilds must work under a world-writable parent
ln -s "$MODULE_DIR" "$WORK/modules/puppetvenv"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0

manifest() { # $1 = extra attributes
  cat <<EOF
python_venv { '$VENV':
  ensure             => present,
  requirements_files => ['$REQ'],
  requirements       => ['idna==3.7'],
  $1
}
EOF
}

# apply <extra attributes> [modulepath]; prints the detailed exit code
apply() {
  local rc=0
  puppet apply --detailed-exitcodes --modulepath "${2:-$WORK/modules}" -e "$(manifest "${1:-}")" >"$LOG" 2>&1 || rc=$?
  echo "$rc"
}

check() { # check <description> <actual> <expected>
  if [ "$2" = "$3" ]; then
    PASS=$((PASS + 1)); echo "ok   - $1"
  else
    FAIL=$((FAIL + 1)); echo "FAIL - $1 (got '$2', expected '$3')"; sed 's/^/       /' "$LOG"
  fi
}

log_has() { grep -q -- "$1" "$LOG" && echo yes || echo no; }

site_file() { # path of an installed module file
  "$VENV/bin/python" -I -c "import $1; print($1.__file__)"
}

builds() { ls -A "$WORK/.venv.builds" 2>/dev/null | wc -l; }

echo 'six==1.16.0' > "$REQ"

# --- install and idempotency -------------------------------------------------
check 'fresh install changes' "$(apply)" 2
check 'fresh install committed format 2 marker' "$(grep -c '"format": 2' "$VENV/.requirements_state")" 1
check '  ... venv path is a symlink to a build' "$([ -L "$VENV" ] && readlink "$VENV" | cut -d/ -f1)" .venv.builds
check '  ... and only that build exists' "$(builds)" 1
check 'second run is a no-op' "$(apply)" 0

# --- zero-sized and truncated files are detected and repaired ----------------
: > "$(site_file six)"
check 'zero-sized six.py triggers rebuild' "$(apply)" 2
check '  ... with a reason' "$(log_has 'verification failed')" yes
check '  ... and six imports again' "$("$VENV/bin/python" -I -c 'import six; print(six.__version__)')" 1.16.0
check '  ... next run is a no-op' "$(apply)" 0

IDNA="$(site_file idna)"
truncate -s 10 "$(dirname "$IDNA")/core.py"
check 'truncated idna/core.py triggers rebuild' "$(apply)" 2
check '  ... next run is a no-op' "$(apply)" 0

# --- same-size corruption: only verify => hash catches it --------------------
SIX="$(site_file six)"
printf 'X' | dd of="$SIX" bs=1 seek=100 conv=notrunc status=none
check 'same-size corruption passes verify => size' "$(apply)" 0
check 'same-size corruption caught by verify => hash' "$(apply 'verify => hash,')" 2
check '  ... next run is a no-op' "$(apply 'verify => hash,')" 0

# --- commit marker and drift --------------------------------------------------
rm "$VENV/.requirements_state"
check 'missing marker triggers rebuild' "$(apply)" 2

echo '{"format": 2, "inpu' > "$VENV/.requirements_state"
check 'truncated marker triggers rebuild' "$(apply)" 2

"$VENV/bin/pip" uninstall -q -y idna
check 'externally removed package triggers rebuild' "$(apply)" 2

"$VENV/bin/pip" install -q 'six==1.15.0'
check 'externally changed package triggers rebuild' "$(apply)" 2
check '  ... and restores the pinned version' "$("$VENV/bin/python" -I -c 'import six; print(six.__version__)')" 1.16.0

: > "$VENV/bin/pip"
check 'zero-sized bin/pip triggers rebuild' "$(apply)" 2
check '  ... next run is a no-op' "$(apply)" 0

# --- atomic switch: the venv stays importable during a rebuild ------------------
echo 'six==1.17.0' > "$REQ"
OLD_BUILD="$(readlink "$VENV")"
STOP="$WORK/stop"
(
  n=0; bad=0
  while [ ! -f "$STOP" ]; do
    n=$((n + 1))
    "$VENV/bin/python" -I -c 'import six, idna' 2>/dev/null || bad=$((bad + 1))
  done
  echo "$n $bad" > "$WORK/probe"
) &
PROBE=$!
check 'changed requirements file triggers rebuild' "$(apply)" 2
touch "$STOP"; wait "$PROBE"
read -r PROBES PROBE_FAILURES < "$WORK/probe"
echo "       ($PROBES imports during the rebuild)"
check '  ... venv stayed importable during the rebuild' "$PROBE_FAILURES" 0
check '  ... switched to a new build' "$([ "$(readlink "$VENV")" != "$OLD_BUILD" ] && echo yes)" yes
check '  ... and removed the old one' "$(builds)" 1
check '  ... with the new version' "$("$VENV/bin/python" -I -c 'import six; print(six.__version__)')" 1.17.0
check '  ... next run is a no-op' "$(apply)" 0

# --- failures never report success and never destroy a venv needlessly --------
touch "$VENV/sentinel"
mv "$REQ" "$REQ.bak"
check 'missing requirements file fails' "$(apply)" 4
check '  ... without touching the venv' "$([ -f "$VENV/sentinel" ] && echo kept || echo deleted)" kept
mv "$REQ.bak" "$REQ"
check '  ... and the venv is still in sync afterwards' "$(apply)" 0

ACTIVE="$(readlink "$VENV")"
echo 'this-package-does-not-exist-e2e==0.0.1' > "$REQ"
check 'failing pip install fails the run' "$(apply)" 4
check '  ... without reporting the venv as in sync' "$(log_has "changed 'out_of_sync' to 'insync'")" no
check '  ... and keeps the previous venv active' "$(readlink "$VENV")" "$ACTIVE"
check '  ... and working' "$("$VENV/bin/python" -I -c 'import six; print(six.__version__)')" 1.17.0
check '  ... and removes the failed build' "$(builds)" 1
check '  ... and still fails on the next run' "$(apply)" 4
echo 'six==1.17.0' > "$REQ"
check '  ... and is in sync again when fixed, without a rebuild' "$(apply)" 0

# --- adoption of venvs created by 0.1.0 ---------------------------------------
if [ -n "${LEGACY_LIBDIR:-}" ]; then
  rm -rf "$VENV"
  mkdir -p "$WORK/legacy/puppetvenv"
  ln -s "$LEGACY_LIBDIR" "$WORK/legacy/puppetvenv/lib"
  check '0.1.0 creates a venv' "$(apply '' "$WORK/legacy")" 2
  touch "$VENV/sentinel"
  check '0.1.1 adopts a valid 0.1.0 venv' "$(apply)" 2
  check '  ... without rebuilding it' "$([ -f "$VENV/sentinel" ] && echo kept || echo deleted)" kept
  check '  ... in place' "$([ -L "$VENV" ] && echo symlink || echo directory)" directory
  check '  ... next run is a no-op' "$(apply)" 0

  rm -rf "$VENV"
  check '0.1.0 creates a venv' "$(apply '' "$WORK/legacy")" 2
  : > "$(site_file six)"
  check '0.1.1 rebuilds a corrupted 0.1.0 venv' "$(apply)" 2
  check '  ... with a reason' "$(log_has 'state from 0.1.0 failed verification')" yes
  check '  ... into a build behind a symlink' "$([ -L "$VENV" ] && echo symlink || echo directory)" symlink
  check '  ... and removes the old directory' "$(builds)" 1
  check '  ... next run is a no-op' "$(apply)" 0
fi

echo
echo "passed: $PASS, failed: $FAIL"
[ "$FAIL" -eq 0 ]
