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
#  (git-editor-wait) Also covers `--wait`, which is the only part of the shim
#  that outlives its `open` call: those cases run the shim in the BACKGROUND
#  (`run_shim_bg`) and play the app's part by hand — renaming the marker to
#  `.claimed` and deleting it — since nothing here ever launches FEdit. A stub
#  `pgrep` alongside the stub `open` plays the other half of that part, the
#  answer to "is FEdit still alive", so that no case depends on whether a real
#  FEdit happens to be running on this machine. The spool is redirected into the
#  temp fixture with FEDIT_WAIT_DIR, except for the one case that asserts the
#  default spool path itself.
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

# (git-editor-wait) The other half of the fixture, and not optional: the shim's
# phase-2 liveness check asks `pgrep` whether FEdit is running, and the first
# answer of "no" ends the wait (there is no cold-start grace — the claim itself
# is the sighting). Without a stub, every happy-path wait test below would pass
# or fail according to whether a real FEdit happens to be running on the machine
# running the tests. Exit status is whatever the current test asked for.
# Records its argv (one line per invocation) so a test can pin BOTH what the
# shim asked (`-qx FEdit` — a typo here would make the liveness check silently
# never match the real app) and HOW OFTEN it asked (the 2 s cadence).
cat > "$STUB_BIN/pgrep" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$FEDIT_STUB_PGREP_RECORD"
exit "${FEDIT_STUB_PGREP_STATUS:-0}"
STUB
chmod 0755 "$STUB_BIN/pgrep"

PATH="$STUB_BIN:$PATH"
export PATH
FEDIT_STUB_RECORD="$RECORD"
export FEDIT_STUB_RECORD
FEDIT_STUB_PGREP_RECORD="$WORK/pgrep-args"
export FEDIT_STUB_PGREP_RECORD

# (git-editor-wait) "FEdit is running", which is what every case but the liveness
# one below wants to be true for the whole of a wait.
FEDIT_STUB_PGREP_STATUS=0
export FEDIT_STUB_PGREP_STATUS

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

# (git-editor-wait) run_shim_bg <working-directory> [arguments...] — the same
# invocation as `run_shim`, started in the background so the test can act as the
# app while the shim waits. `$BG_PID` is the SHIM's own pid, not a wrapper's:
# the subshell `exec`s into it, which is what makes `kill -TERM "$BG_PID"` (and
# the marker's recorded `$$`) mean the shim.
#
# `set -m` around the launch is load-bearing and was measured: a background job
# started by a non-interactive shell WITHOUT job control inherits SIGINT as
# SIG_IGN, and a signal ignored on entry can never be trapped — the shim's own
# INT trap would silently not exist and the SIGINT case would assert nothing.
# With job control the job gets its own process group and the default
# disposition, so the trap installs and runs.
run_shim_bg() {
    run_cwd=$1
    shift
    : > "$RECORD"
    : > "$OUT"
    : > "$ERR"
    set -m
    (
        cd "$run_cwd" || exit 1
        FEDIT_APP="$FEDIT_APP_FOR_RUN"
        export FEDIT_APP
        exec "$SHIM" "$@"
    ) > "$OUT" 2> "$ERR" &
    BG_PID=$!
    set +m
}

# (git-editor-wait) wait_for_exit <tenths-of-a-second> — bounded wait for the
# background shim, setting $STATUS to its exit status. Returns non-zero (and
# SIGKILLs the shim) if it outlives the budget, so a shim that hangs fails the
# assertion instead of hanging the harness. `$wait_ticks` is left holding how
# many polls it took, which is the only timing measurement this file makes.
#
# What makes polling for the pid sound is that this shell reaps its own
# background jobs promptly: measured, an exited job is gone from `ps` within one
# 0.1 s tick, and no zombie state was ever observed. `ps -o state=` would NOT
# have caught one anyway — measured, it prints `ZN` for a zombie, which is
# non-empty and therefore exactly as blind here as `kill -0` (which also reports
# a zombie as alive). The `wait` after the loop is what turns the reaped job's
# remembered status into $STATUS.
wait_for_exit() {
    wait_budget=$1
    wait_ticks=0
    while [ -n "$(ps -o state= -p "$BG_PID" 2>/dev/null)" ]; do
        if [ "$wait_ticks" -ge "$wait_budget" ]; then
            kill -9 "$BG_PID" 2>/dev/null
            wait "$BG_PID" 2>/dev/null
            STATUS=-1
            return 1
        fi
        sleep 0.1
        wait_ticks=$((wait_ticks + 1))
    done
    wait "$BG_PID"
    STATUS=$?
    return 0
}

# (git-editor-wait) wait_for_marker <tenths-of-a-second> — bounded wait for the
# shim to have written its marker, setting $MARKER to the spool's single entry.
# Empty $MARKER afterwards means it never appeared. The `.tmp` form is skipped
# so a poll landing inside the shim's write-then-rename never picks it up; by
# the time this returns, that rename has therefore happened.
wait_for_marker() {
    marker_budget=$1
    marker_ticks=0
    MARKER=""
    while [ "$marker_ticks" -lt "$marker_budget" ]; do
        marker_name=$(ls -A "$SPOOL" 2>/dev/null | grep -v '\.tmp$' | head -n 1)
        if [ -n "$marker_name" ]; then
            MARKER="$SPOOL/$marker_name"
            return 0
        fi
        sleep 0.1
        marker_ticks=$((marker_ticks + 1))
    done
    return 1
}

# (git-editor-wait) The number of entries in the spool — 0 is the "the shim
# cleaned up after itself" assertion every failure case makes.
spool_entry_count() {
    ls -A "$SPOOL" 2>/dev/null | wc -l | tr -d ' '
}

FEDIT_APP_FOR_RUN="$APP"

# (git-editor-wait) Every run below writes its markers here instead of into the
# real ~/Library/Application Support/FEdit/wait. Exported once: the shim reads
# it in wait mode only, so the non-wait cases are unaffected. The two cases that
# assert the DEFAULT spelling unset it deliberately, in their own subshells.
SPOOL="$WORK/spool"
FEDIT_WAIT_DIR="$SPOOL"
export FEDIT_WAIT_DIR

# The whole file's expectations rest on /tmp being reachable as /private/tmp.
section "Fixture sanity"
check "$([ -d "$CANON" ] && echo yes || echo no)" "the temp fixture is reachable at $CANON"
check "$([ -x "$STUB_BIN/open" ] && echo yes || echo no)" "stub open is executable and first on PATH"
check_equal "$(command -v pgrep)" "$STUB_BIN/pgrep" "stub pgrep shadows the real one, so liveness is the test's to decide"

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

# MARK: - (git-editor-wait) --wait: usage errors

section "git-editor-wait: --wait takes exactly one regular file"
rm -rf "$SPOOL"
run_shim "$PROJ" --wait
check_equal "$STATUS" "64" "--wait with no path exits 64 (EX_USAGE)"
check "$(grep -q '^usage: fedit' "$ERR" && echo yes || echo no)" "usage goes to stderr"
check_equal "$(wc -c < "$OUT" | tr -d ' ')" "0" "nothing is written to stdout"
check_equal "$(wc -c < "$RECORD" | tr -d ' ')" "0" "open is never invoked"
check_equal "$(spool_entry_count)" "0" "no marker is left in the spool"

# A lone `-w` is a usage error, not exit 66 for a missing path — which is what
# would happen if the alias were not recognized as a flag at all.
run_shim "$PROJ" -w
check_equal "$STATUS" "64" "-w is the same flag as --wait"

run_shim "$PROJ" --wait notes.md a.py
check_equal "$STATUS" "64" "--wait with two paths exits 64"
check_equal "$(wc -c < "$RECORD" | tr -d ' ')" "0" "open is never invoked"
check_equal "$(spool_entry_count)" "0" "no marker is left in the spool"

run_shim "$PROJ" --wait sub
check_equal "$STATUS" "64" "--wait on a directory exits 64 (no file, so nothing could claim it)"
check "$(grep -q 'regular file' "$ERR" && echo yes || echo no)" "the diagnostic says what it wanted"
check_equal "$(wc -c < "$RECORD" | tr -d ' ')" "0" "open is never invoked"
check_equal "$(spool_entry_count)" "0" "no marker is left in the spool"

run_shim "$PROJ" --wait /tmp/does-not-exist.md
check_equal "$STATUS" "66" "--wait on a nonexistent path keeps the shipped 66"
check_equal "$(spool_entry_count)" "0" "no marker is left in the spool"

# MARK: - (git-editor-wait) --wait: the happy path

section "git-editor-wait: marker, claim, release"
rm -rf "$SPOOL"
run_shim_bg "$PROJ" --wait notes.md
if wait_for_marker 50; then
    WAIT_PATH="$CANON/proj/notes.md"
    check_equal "$(spool_entry_count)" "1" "the shim writes exactly one marker (and no leftover .tmp)"
    check_equal "$(head -n 1 "$MARKER")" "$BG_PID" "its first line is the shim's own pid"
    check_equal "$(tail -n +2 "$MARKER")" "$WAIT_PATH" "the rest is the canonical path"
    # `$(...)` strips trailing newlines, so the two checks above cannot see one:
    # pid + LF + path and nothing else is a byte count. BYTES on both sides — the
    # expected side is built with the same `printf` the shim uses and measured
    # the same way, because `${#var}` counts CHARACTERS, and a path with any
    # non-ASCII byte in it would then fail a marker that is perfectly correct.
    check_equal "$(wc -c < "$MARKER" | tr -d ' ')" \
        "$(printf '%s\n%s' "$BG_PID" "$WAIT_PATH" | wc -c | tr -d ' ')" \
        "and there is no trailing newline (a path may contain newlines of its own)"

    check "$([ -n "$(ps -o state= -p "$BG_PID" 2>/dev/null)" ] && echo yes || echo no)" \
        "the shim is still waiting while the marker sits unclaimed"

    # Play the app: claim the marker (phase 1 ends), but do not release it yet.
    mv "$MARKER" "$MARKER.claimed"
    sleep 0.5
    check "$([ -n "$(ps -o state= -p "$BG_PID" 2>/dev/null)" ] && echo yes || echo no)" \
        "a CLAIM alone does not end the wait — that is only the acknowledgement"

    # Now close the window.
    rm -f "$MARKER.claimed"
    if wait_for_exit 10; then
        check_equal "$STATUS" "0" "releasing the claim exits the shim 0, within ~1 s"
        check_equal "$(spool_entry_count)" "0" "the spool is left empty"
        check_equal "$(cat "$RECORD")" "-a
$APP
$WAIT_PATH" "open was handed the same canonical path the marker named"
    else
        check no "the shim exited within 1 s of the claim being released"
    fi
else
    check no "the shim wrote a marker into the spool"
    kill -9 "$BG_PID" 2>/dev/null
fi

section "git-editor-wait: released before the claim is ever seen"
rm -rf "$SPOOL"
run_shim_bg "$PROJ" --wait notes.md
if wait_for_marker 50; then
    # The window opened and closed between two polls: the marker is simply gone,
    # with no `.claimed` to be found. That means the same as a released claim.
    rm -f "$MARKER"
    if wait_for_exit 20; then
        check_equal "$STATUS" "0" "a marker that vanishes without a claim still exits 0"
    else
        check no "the shim exited within 2 s of the marker vanishing"
    fi
else
    check no "the shim wrote a marker into the spool"
    kill -9 "$BG_PID" 2>/dev/null
fi

# MARK: - (git-editor-wait) --wait: bounded failure paths

section "git-editor-wait: nothing ever claims the marker"
rm -rf "$SPOOL"
FEDIT_WAIT_ACK_TIMEOUT=1
export FEDIT_WAIT_ACK_TIMEOUT
run_shim_bg "$PROJ" --wait notes.md
if wait_for_exit 50; then
    check_equal "$STATUS" "1" "an open that is never acknowledged gives up and exits 1"
    check_equal "$(spool_entry_count)" "0" "the abandoned marker is removed"
    check "$(grep -q 'did not open' "$ERR" && echo yes || echo no)" "with a diagnostic on stderr"
    check_equal "$(wc -c < "$OUT" | tr -d ' ')" "0" "and nothing on stdout"
else
    check no "the shim gave up within 5 s of FEDIT_WAIT_ACK_TIMEOUT=1"
fi
unset FEDIT_WAIT_ACK_TIMEOUT

section "git-editor-wait: an unusable FEDIT_WAIT_ACK_TIMEOUT is refused up front"
# The whole point is the ORDER: the value is checked before the spool is touched,
# before the marker is written and before `open` runs. A check that came later
# would abort the script with a marker already in the spool (nothing ever claims
# it, nothing removes it) and a window already open that nobody is waiting for.
# bad_ack_timeout_case <value> <label>
bad_ack_timeout_case() {
    rm -rf "$SPOOL"
    mkdir -p "$SPOOL"
    FEDIT_WAIT_ACK_TIMEOUT=$1
    export FEDIT_WAIT_ACK_TIMEOUT
    run_shim "$PROJ" --wait notes.md
    check_equal "$STATUS" "78" "FEDIT_WAIT_ACK_TIMEOUT=$2 exits 78 (EX_CONFIG)"
    check "$(grep -q 'FEDIT_WAIT_ACK_TIMEOUT' "$ERR" && echo yes || echo no)" \
        "…with a diagnostic naming the variable, on stderr"
    check_equal "$(wc -c < "$RECORD" | tr -d ' ')" "0" "…and open is never invoked"
    check_equal "$(spool_entry_count)" "0" "…and the spool is left empty (no orphaned marker)"
    unset FEDIT_WAIT_ACK_TIMEOUT
}
bad_ack_timeout_case abc abc
bad_ack_timeout_case 0 0
# Leading zeros are rejected, not normalized: `$(( 08 ))` is an OCTAL parse
# error (a `set -e` abort at the arithmetic, AFTER the marker and the window —
# the exact ordering this section exists to forbid) and `$(( 030 ))` is
# silently 24. And a value long enough to wrap int64 once multiplied by the
# poll rate would turn the bounded phase into an instant or a near-infinite
# one, so the length is capped at 6 digits.
bad_ack_timeout_case 08 08
bad_ack_timeout_case 030 030
bad_ack_timeout_case 9999999 '9999999 (7 digits)'
# No case for an EMPTY value on purpose: `${FEDIT_WAIT_ACK_TIMEOUT:-30}` means
# set-but-empty is "unset", so an empty value is the 30 s default and never
# reaches the check at all (measured — the case existed here and failed).

section "git-editor-wait: FEdit dies still holding the claim"
# The liveness check, and the reason it has no cold-start state: the shim is in
# phase 2, so FEdit *did* claim the marker — a `pgrep` that then reports nothing
# means it died holding the claim, and nobody will ever release it.
rm -rf "$SPOOL"
: > "$FEDIT_STUB_PGREP_RECORD"
FEDIT_STUB_PGREP_STATUS=1
export FEDIT_STUB_PGREP_STATUS
run_shim_bg "$PROJ" --wait notes.md
if wait_for_marker 50; then
    # Play the app claiming the marker, and then dying: the claim stays.
    mv "$MARKER" "$MARKER.claimed"
    if wait_for_exit 30; then
        check_equal "$STATUS" "1" "a claim outliving FEdit ends the wait with 1 rather than hanging"
        check_equal "$(spool_entry_count)" "0" "and the shim removes the orphaned .claimed on its way out"
        check "$(grep -q 'quit without closing' "$ERR" && echo yes || echo no)" \
            "with a diagnostic on stderr"
        # Discriminating: the check runs on the FIRST poll of phase 2, not on the
        # 2 s liveness cadence — at the cadence this would take ~20 ticks.
        check "$([ "$wait_ticks" -lt 15 ] && echo yes || echo no)" \
            "…on the first poll of phase 2 (measured: ${wait_ticks} × 0.1 s)"
        # The exact spelling matters: `-x` is what keeps FEditHelper-style names
        # from matching, and a typo here would never match the real app at all —
        # while this stub, which ignores its argv, would keep every case green.
        check_equal "$(head -1 "$FEDIT_STUB_PGREP_RECORD")" "-qx FEdit" \
            "…and the liveness question is exactly \`pgrep -qx FEdit\`"
    else
        check no "the shim gave up within 3 s of FEdit disappearing"
    fi
else
    check no "the shim wrote a marker into the spool"
    kill -9 "$BG_PID" 2>/dev/null
fi
FEDIT_STUB_PGREP_STATUS=0
export FEDIT_STUB_PGREP_STATUS

section "git-editor-wait: a pgrep that cannot answer does not kill a healthy wait"
# Only pgrep's own "no match" (status 1) means FEdit is gone. 127 — no pgrep on
# PATH at all — must read as "cannot tell, keep waiting": before this was
# discriminated, a missing pgrep killed every healthy wait on its FIRST phase-2
# poll and deleted the app's live claim on the way out. The claim being released
# normally must still end the wait with 0.
rm -rf "$SPOOL"
: > "$FEDIT_STUB_PGREP_RECORD"
FEDIT_STUB_PGREP_STATUS=127
export FEDIT_STUB_PGREP_STATUS
run_shim_bg "$PROJ" --wait notes.md
if wait_for_marker 50; then
    mv "$MARKER" "$MARKER.claimed"
    # Hold the claim across the tick-0 liveness check (and a few polls beyond),
    # then release it the way a closing window would.
    sleep 1
    rm -f "$MARKER.claimed"
    if wait_for_exit 30; then
        check_equal "$STATUS" "0" "pgrep status 127 is 'cannot tell', and the released claim still ends the wait with 0"
        # Cadence: in the ~1 s the claim was held (ticks 0..~5) only tick 0 may
        # ask; a regression to asking every tick would record ~5 lines. Two are
        # allowed for a slow machine reaching tick 10.
        pgrep_calls=$(wc -l < "$FEDIT_STUB_PGREP_RECORD" | tr -d ' ')
        check "$([ "$pgrep_calls" -ge 1 ] && [ "$pgrep_calls" -le 2 ] && echo yes || echo no)" \
            "liveness was asked on the 2 s cadence, not every 0.2 s poll (${pgrep_calls} call(s) in ~1 s)"
    else
        check no "the shim exited within its budget after the claim was released"
    fi
else
    check no "the shim wrote a marker into the spool"
    kill -9 "$BG_PID" 2>/dev/null
fi
FEDIT_STUB_PGREP_STATUS=0
export FEDIT_STUB_PGREP_STATUS

section "git-editor-wait: open itself fails"
rm -rf "$SPOOL"
FEDIT_STUB_STATUS=3
export FEDIT_STUB_STATUS
# Synchronous on purpose: a failed `open` never reaches the wait at all.
run_shim "$PROJ" --wait notes.md
check_equal "$STATUS" "3" "the shim exits with open's own status"
check_equal "$(spool_entry_count)" "0" "and takes its marker with it (nothing will ever claim it)"
unset FEDIT_STUB_STATUS

section "git-editor-wait: a signal ends the wait"
# signal_case <signal-name> <expected-status>
signal_case() {
    sig=$1
    expected=$2
    rm -rf "$SPOOL"
    run_shim_bg "$PROJ" --wait notes.md
    if wait_for_marker 50; then
        kill -"$sig" "$BG_PID" 2>/dev/null
        if wait_for_exit 30; then
            check_equal "$STATUS" "$expected" "SIG$sig exits 128+signo ($expected), not 0"
            check_equal "$(spool_entry_count)" "0" "SIG$sig removes the marker on the way out"
        else
            check no "SIG$sig ended the wait within 3 s"
        fi
    else
        check no "the shim wrote a marker before being sent SIG$sig"
        kill -9 "$BG_PID" 2>/dev/null
    fi
}
signal_case INT 130
signal_case TERM 143
signal_case HUP 129

# MARK: - (git-editor-wait) The spool location

section "git-editor-wait: no HOME at all (a cron/launchd context)"
rm -rf "$SPOOL"
# The regression this guards: the spool is resolved INSIDE wait mode, so a
# missing HOME must not disturb a plain open under `set -u`.
: > "$RECORD"
: > "$OUT"
: > "$ERR"
( cd "$PROJ" && unset HOME FEDIT_WAIT_DIR && FEDIT_APP="$APP" "$SHIM" notes.md ) > "$OUT" 2> "$ERR"
STATUS=$?
check_equal "$STATUS" "0" "plain fedit still works with HOME unset"
check_equal "$(cat "$RECORD")" "-a
$APP
$CANON/proj/notes.md" "…and still opens the canonical path"

: > "$RECORD"
: > "$OUT"
: > "$ERR"
( cd "$PROJ" && unset HOME FEDIT_WAIT_DIR && FEDIT_APP="$APP" "$SHIM" --wait notes.md ) > "$OUT" 2> "$ERR"
STATUS=$?
check_equal "$STATUS" "78" "--wait with neither HOME nor FEDIT_WAIT_DIR exits 78 (EX_CONFIG)"
check "$(grep -q 'HOME' "$ERR" && echo yes || echo no)" "the diagnostic names what is missing"
check_equal "$(wc -c < "$RECORD" | tr -d ' ')" "0" "open is never invoked — nothing is opened it could not wait for"

section "git-editor-wait: the default spool path IS the protocol constant"
# The app spells this same path as `WaitMarkers.spoolDirectory`, and
# OpenRequestTests asserts that side against the identical literal. This is the
# only thing holding the two halves together, so it is asserted from a fake HOME
# rather than from FEDIT_WAIT_DIR (which the rest of this file uses).
FAKE_HOME="$WORK/fake-home"
mkdir -p "$FAKE_HOME"
set -m
(
    cd "$PROJ" || exit 1
    unset FEDIT_WAIT_DIR
    HOME="$FAKE_HOME"
    export HOME
    FEDIT_APP="$APP"
    export FEDIT_APP
    exec "$SHIM" --wait notes.md
) > "$OUT" 2> "$ERR" &
BG_PID=$!
set +m
SPOOL="$FAKE_HOME/Library/Application Support/FEdit/wait"
if wait_for_marker 50; then
    check yes "the marker lands in \$HOME/Library/Application Support/FEdit/wait"
    check_equal "$(head -n 1 "$MARKER")" "$BG_PID" "…written by this shim"
    rm -f "$MARKER"
    if wait_for_exit 20; then
        check_equal "$STATUS" "0" "and releasing it there ends the wait"
    else
        check no "the shim exited after its default-spool marker was released"
    fi
else
    check no "the marker lands in \$HOME/Library/Application Support/FEdit/wait"
    kill -9 "$BG_PID" 2>/dev/null
fi
SPOOL="$WORK/spool"

# MARK: - Summary

printf '\n==================================\n'
if [ "$failureCount" -eq 0 ]; then
    printf 'ALL TESTS PASSED\n'
    exit 0
else
    printf '%s TEST(S) FAILED\n' "$failureCount"
    exit 1
fi
