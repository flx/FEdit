#!/bin/sh
#
#  run.sh
#  FeditShimTests
#
#  Copyright © 2026 Felix Matschke
#
#  This file is part of FEdit.
#
#  FEdit is free software: you can redistribute it and/or modify it under
#  the terms of the GNU General Public License as published by the Free
#  Software Foundation, either version 3 of the License, or (at your
#  option) any later version.
#
#  FEdit is distributed in the hope that it will be useful, but WITHOUT
#  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
#  FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License
#  for more details.
#
#  You should have received a copy of the GNU General Public License
#  along with FEdit. If not, see <https://www.gnu.org/licenses/>.
#
#  Standalone assertion harness for `scripts/fedit` (cli-open Tier 3): argument
#  validation, path canonicalization and the exit-code contract. Needs no GUI
#  and never launches FEdit — a stub `open` first on PATH records what it was
#  handed. Run manually:
#
#      sh scripts/FeditShimTests/run.sh
#
#  Same PASS/FAIL/summary shape as the swiftc harnesses under scripts/.
#

set -u

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
SHIM=$(dirname -- "$SCRIPT_DIR")/fedit

[ -x "$SHIM" ] || {
    printf 'run.sh: shim not found or not executable: %s\n' "$SHIM" >&2
    exit 1
}

# MARK: - Tiny test harness

failureCount=0

check() {
    if [ "$1" = "yes" ]; then
        printf '  PASS: %s\n' "$2"
    else
        failureCount=$((failureCount + 1))
        printf '  FAIL: %s\n' "$2"
    fi
}

check_equal() {
    # check_equal <actual> <expected> <message>
    if [ "$1" = "$2" ]; then
        printf '  PASS: %s\n' "$3"
    else
        failureCount=$((failureCount + 1))
        printf '  FAIL: %s\n' "$3"
        printf '        expected: %s\n' "$2"
        printf '        actual:   %s\n' "$1"
    fi
}

section() {
    printf '\n== %s ==\n' "$1"
}

# MARK: - Fixture: stub `open` on PATH, a fake FEdit.app, and some real files

# Deliberately under /tmp, which is a symlink to /private/tmp: the expected
# paths below are spelled /private/... by hand, so they assert that the shim
# really canonicalizes rather than just prefixing $PWD.
WORK=$(mktemp -d /tmp/FeditShimTests-XXXXXX) || exit 1
CANON="/private$WORK"

cleanup() {
    rm -rf "$WORK"
}
trap cleanup EXIT

STUB_BIN="$WORK/bin"
mkdir -p "$STUB_BIN"
RECORD="$WORK/open-args"

cat > "$STUB_BIN/open" <<'STUB'
#!/bin/sh
# Records each argument on its own line (so embedded spaces are unambiguous)
# and exits with whatever the test asked for.
for arg in "$@"; do
    printf '%s\n' "$arg" >> "$FEDIT_STUB_RECORD"
done
exit "${FEDIT_STUB_STATUS:-0}"
STUB
chmod 0755 "$STUB_BIN/open"

PATH="$STUB_BIN:$PATH"
export PATH
FEDIT_STUB_RECORD="$RECORD"
export FEDIT_STUB_RECORD

APP="$WORK/FEdit.app"
mkdir -p "$APP/Contents/MacOS"
CANON_APP="$CANON/FEdit.app"

PROJ="$WORK/proj"
mkdir -p "$PROJ/sub"
printf '# Hi\n' > "$PROJ/notes.md"
printf 'x = 1\n' > "$PROJ/a.py"
printf '# B\n' > "$PROJ/b.md"
printf '# Spaced\n' > "$PROJ/a b.md"
ln -s "$PROJ" "$WORK/link-to-proj"

OUT="$WORK/stdout"
ERR="$WORK/stderr"
STATUS=0

# run_shim <working-directory> [arguments...] — resets the recorder first, so
# an empty $RECORD afterwards means "open was never invoked".
run_shim() {
    run_cwd=$1
    shift
    : > "$RECORD"
    : > "$OUT"
    : > "$ERR"
    ( cd "$run_cwd" && FEDIT_APP="$FEDIT_APP_FOR_RUN" "$SHIM" "$@" ) > "$OUT" 2> "$ERR"
    STATUS=$?
}

FEDIT_APP_FOR_RUN="$APP"

# The whole file's expectations rest on /tmp being reachable as /private/tmp.
section "Fixture sanity"
check "$([ -d "$CANON" ] && echo yes || echo no)" "the temp fixture is reachable at $CANON"
check "$([ -x "$STUB_BIN/open" ] && echo yes || echo no)" "stub open is executable and first on PATH"

# MARK: - A15 Help

section "A15: --help / -h"
run_shim "$PROJ" --help
check_equal "$STATUS" "0" "--help exits 0"
check "$(head -n 1 "$OUT" | grep -q '^usage: fedit' && echo yes || echo no)" "--help prints usage on stdout"
check_equal "$(wc -c < "$ERR" | tr -d ' ')" "0" "--help writes nothing to stderr"
check_equal "$(wc -c < "$RECORD" | tr -d ' ')" "0" "--help never invokes open"

run_shim "$PROJ" -h
check_equal "$STATUS" "0" "-h exits 0"
check "$(head -n 1 "$OUT" | grep -q '^usage: fedit' && echo yes || echo no)" "-h prints usage on stdout"
check_equal "$(wc -c < "$RECORD" | tr -d ' ')" "0" "-h never invokes open"

# MARK: - A14 No arguments

section "A14: no arguments"
run_shim "$PROJ"
check_equal "$STATUS" "0" "no-arg exits with open's status (0)"
check_equal "$(cat "$RECORD")" "-a
$APP" "no-arg invokes open with the app and NO file operands"

FEDIT_STUB_STATUS=3
export FEDIT_STUB_STATUS
run_shim "$PROJ"
check_equal "$STATUS" "3" "no-arg propagates open's non-zero status (3), it does not hardcode 0"
unset FEDIT_STUB_STATUS

# MARK: - A12/A13 Nonexistent paths

section "A12: nonexistent path"
run_shim "$PROJ" /tmp/does-not-exist.md
check_equal "$STATUS" "66" "a nonexistent path exits 66 (EX_NOINPUT)"
check_equal "$(cat "$ERR")" "fedit: no such file or directory: /tmp/does-not-exist.md" \
    "the message names the offending path, on stderr"
check_equal "$(wc -c < "$OUT" | tr -d ' ')" "0" "nothing is written to stdout"
check_equal "$(wc -c < "$RECORD" | tr -d ' ')" "0" "open is never invoked"

section "A13: all-or-nothing validation"
run_shim "$PROJ" notes.md /tmp/nope
check_equal "$STATUS" "66" "a good path followed by a bad one exits 66"
check_equal "$(cat "$ERR")" "fedit: no such file or directory: /tmp/nope" "the bad path is named"
check_equal "$(wc -c < "$RECORD" | tr -d ' ')" "0" "open is never invoked, so notes.md does NOT open either"

run_shim "$PROJ" /tmp/nope notes.md
check_equal "$STATUS" "66" "a bad path followed by a good one exits 66"
check_equal "$(wc -c < "$RECORD" | tr -d ' ')" "0" "open is never invoked"

section "A12b: a broken symlink is a nonexistent path"
ln -s "$PROJ/gone.md" "$PROJ/broken.md"
run_shim "$PROJ" broken.md
check_equal "$STATUS" "66" "a dangling symlink exits 66"
check_equal "$(wc -c < "$RECORD" | tr -d ' ')" "0" "open is never invoked"
rm -f "$PROJ/broken.md"

# MARK: - A16 Path handling

section "A16: relative path with . and .."
run_shim "$PROJ" ./sub/../notes.md
check_equal "$STATUS" "0" "exits 0"
check_equal "$(cat "$RECORD")" "-a
$APP
$CANON/proj/notes.md" "./sub/../notes.md is passed as a canonical absolute path"

section "A16: a path with a space"
run_shim "$PROJ" "a b.md"
check_equal "$(cat "$RECORD")" "-a
$APP
$CANON/proj/a b.md" "the space survives as one single operand"

section "A16: several paths keep their order"
run_shim "$PROJ" notes.md a.py
check_equal "$(cat "$RECORD")" "-a
$APP
$CANON/proj/notes.md
$CANON/proj/a.py" "two operands, one per argument, in argument order"

run_shim "$PROJ" a.py notes.md
check_equal "$(cat "$RECORD")" "-a
$APP
$CANON/proj/a.py
$CANON/proj/notes.md" "reversing the arguments reverses the operands"

section "A16: symlinks are resolved (the shim canonicalizes, by design)"
run_shim "$WORK" link-to-proj/notes.md
check_equal "$(cat "$RECORD")" "-a
$APP
$CANON/proj/notes.md" "a symlinked directory is resolved to its real path"

section "A16: a directory argument"
run_shim "$PROJ" sub
check_equal "$(cat "$RECORD")" "-a
$APP
$CANON/proj/sub" "a directory is passed through like any other path"

run_shim "$PROJ" .
check_equal "$(cat "$RECORD")" "-a
$APP
$CANON/proj" "'.' becomes the canonical current directory"

# MARK: - A25 (shell half): one invocation, two operands

section "A25: two files in one invocation"
run_shim "$PROJ" notes.md b.md
check_equal "$STATUS" "0" "exits 0"
check_equal "$(cat "$RECORD")" "-a
$APP
$CANON/proj/notes.md
$CANON/proj/b.md" "both operands are recorded, in order, in one open call"

# MARK: - A17 Too many paths

section "A17: more than 8 paths"
i=1
while [ "$i" -le 9 ]; do
    printf 'x\n' > "$PROJ/many-$i.md"
    i=$((i + 1))
done
run_shim "$PROJ" many-1.md many-2.md many-3.md many-4.md many-5.md many-6.md many-7.md many-8.md many-9.md
check_equal "$STATUS" "64" "9 paths exits 64 (EX_USAGE)"
check "$(grep -q '^usage: fedit' "$ERR" && echo yes || echo no)" "usage goes to stderr"
check_equal "$(wc -c < "$OUT" | tr -d ' ')" "0" "nothing is written to stdout"
check_equal "$(wc -c < "$RECORD" | tr -d ' ')" "0" "open is never invoked"

run_shim "$PROJ" many-1.md many-2.md many-3.md many-4.md many-5.md many-6.md many-7.md many-8.md
check_equal "$STATUS" "0" "exactly 8 paths is still allowed"
check_equal "$(wc -l < "$RECORD" | tr -d ' ')" "10" "8 operands plus -a and the app path are recorded"

# MARK: - A23 FEdit.app not found

section "A23: FEDIT_APP points at a nonexistent bundle"
FEDIT_APP_FOR_RUN="$WORK/nowhere/FEdit.app"
FEDIT_STUB_STATUS=1
export FEDIT_STUB_STATUS

run_shim "$PROJ"
check_equal "$STATUS" "69" "no-arg with a missing bundle exits 69 (EX_UNAVAILABLE)"
check_equal "$(cat "$ERR")" \
    "fedit: FEdit.app not found (looked in $WORK/nowhere/FEdit.app and LaunchServices); set FEDIT_APP" \
    "the message names the path it looked in, on stderr"
check_equal "$(cat "$RECORD")" "-a
FEdit" "the LaunchServices fallback was tried first"

run_shim "$PROJ" notes.md
check_equal "$STATUS" "69" "with operands and a missing bundle it also exits 69"
check_equal "$(cat "$RECORD")" "-a
FEdit
$CANON/proj/notes.md" "the fallback still carries the canonical operand"

unset FEDIT_STUB_STATUS

section "A23b: the LaunchServices fallback SUCCEEDING is not an error"
# Same missing bundle as above, but this time `open -a FEdit` succeeds — a copy
# of FEdit registered somewhere else. The shim must exit 0 and say nothing.
run_shim "$PROJ" notes.md
check_equal "$STATUS" "0" "a missing bundle plus a successful LaunchServices open exits 0"
check_equal "$(cat "$RECORD")" "-a
FEdit
$CANON/proj/notes.md" "open was asked for the app NAMED FEdit, not the missing path"
check_equal "$(wc -c < "$ERR" | tr -d ' ')" "0" "no diagnostic is printed when the fallback works"

run_shim "$PROJ"
check_equal "$STATUS" "0" "no-arg with a missing bundle and a working fallback exits 0"
check_equal "$(cat "$RECORD")" "-a
FEdit" "the no-arg fallback carries no operands"

FEDIT_APP_FOR_RUN="$APP"

section "A23c: a real bundle at FEDIT_APP takes the DIRECT branch"
run_shim "$PROJ" notes.md
check_equal "$STATUS" "0" "exits 0"
check_equal "$(cat "$RECORD")" "-a
$APP
$CANON/proj/notes.md" "open is handed the bundle PATH, so LaunchServices is never consulted"

# MARK: - Summary

printf '\n==================================\n'
if [ "$failureCount" -eq 0 ]; then
    printf 'ALL TESTS PASSED\n'
    exit 0
else
    printf '%s TEST(S) FAILED\n' "$failureCount"
    exit 1
fi
