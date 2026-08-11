#!/usr/bin/env bash
#
#  install.sh
#  FEdit
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
#  Builds the Release configuration and installs FEdit.app into /Applications
#  (or into the directory given as the single optional argument), then installs
#  the `fedit` command-line shim into the first writable directory it finds:
#
#      scripts/install.sh [destination-directory]
#
#  The build goes into a fixed derived-data path under $TMPDIR, so the freshly
#  built bundle can be located without guessing at Xcode's default DerivedData
#  paths. Deliberately NOT inside the repo: a checkout under an iCloud-synced
#  folder (~/Documents with "Desktop & Documents" sync, say) gets
#  com.apple.FinderInfo stamped onto the bundle mid-build, which aborts the
#  CodeSign phase — and syncing hundreds of MB of derived data to iCloud helps
#  no one. Runnable from any working directory.
#

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_ROOT=$(dirname -- "$SCRIPT_DIR")
readonly SCRIPT_DIR PROJECT_ROOT
readonly PROJECT="$PROJECT_ROOT/FEdit.xcodeproj"
readonly SCHEME="FEdit"
readonly CONFIGURATION="Release"
readonly DERIVED_DATA="${TMPDIR:-/tmp}/FEdit-DerivedData"
readonly APP_NAME="FEdit.app"
readonly DEFAULT_DEST="/Applications"

die() {
    printf 'install.sh: %s\n' "$*" >&2
    exit 1
}

warn() {
    printf 'install.sh: %s\n' "$*" >&2
}

# (cli-open) Installs the `fedit` shim next to the app, with its APP= default
# rewritten to wherever the app actually went — so a non-default destination
# still yields a working command. Deliberately NON-FATAL and never `sudo`: a
# shim that cannot be placed must not fail an otherwise-good app install.
install_cli_shim() {
    local shim_source="$SCRIPT_DIR/fedit"
    if [ ! -f "$shim_source" ]; then
        warn "CLI shim not found at $shim_source — skipping (the app itself is installed)"
        return 0
    fi

    # /opt/homebrew/bin before /usr/local/bin: on Apple Silicon the former is
    # the one that is normally on PATH. $HOME/.local/bin is the last resort and
    # the only one created on demand.
    local candidates=()
    if [ -n "${FEDIT_BIN_DIR:-}" ]; then
        candidates+=("$FEDIT_BIN_DIR")
    fi
    candidates+=("/opt/homebrew/bin" "/usr/local/bin" "$HOME/.local/bin")

    local bin_dir=""
    local candidate
    for candidate in "${candidates[@]}"; do
        if [ ! -d "$candidate" ]; then
            [ "$candidate" = "$HOME/.local/bin" ] || continue
            mkdir -p "$candidate" 2>/dev/null || continue
        fi
        [ -w "$candidate" ] || continue
        bin_dir="$candidate"
        break
    done

    if [ -z "$bin_dir" ]; then
        warn "no writable directory for the fedit command (tried ${candidates[*]}) — skipping"
        warn "install it yourself with: install -m 0755 '$shim_source' <a-directory-on-your-PATH>/fedit"
        return 0
    fi

    local staged
    staged=$(mktemp "${TMPDIR:-/tmp}/fedit-shim.XXXXXX") || {
        warn "could not create a temporary file for the fedit shim — skipping"
        return 0
    }

    # `&`, `|` and `\` are special on sed's replacement side; the destination is
    # an arbitrary path, so escape them.
    local app_escaped
    app_escaped=$(printf '%s' "$INSTALLED_APP" | sed -e 's/[\\&|]/\\&/g')
    if ! sed "s|^APP=\${FEDIT_APP:-.*}\$|APP=\${FEDIT_APP:-$app_escaped}|" "$shim_source" > "$staged"; then
        rm -f "$staged"
        warn "could not stage the fedit shim — skipping"
        return 0
    fi

    # Verify by EVALUATION, not by string match: what has to be true is that the
    # staged shim, run with no FEDIT_APP in the environment, ends up with APP
    # pointing at the bundle we just installed. Evaluating its own APP= line in a
    # clean shell asserts exactly that, and keeps working if the line's spelling
    # (quoting, a different parameter expansion) ever changes. Fail loudly rather
    # than installing a shim that silently points at /Applications while the app
    # went somewhere else.
    local app_line resolved
    app_line=$(grep -m 1 '^APP=' "$staged") || app_line=""
    resolved=""
    if [ -n "$app_line" ]; then
        resolved=$(env -i /bin/sh -c "FEDIT_APP=''; $app_line; printf '%s' \"\$APP\"" 2>/dev/null) || resolved=""
    fi
    if [ "$resolved" != "$INSTALLED_APP" ]; then
        rm -f "$staged"
        warn "the staged fedit shim resolves APP to '$resolved', not '$INSTALLED_APP' — skipping"
        warn "install it yourself and set FEDIT_APP=$INSTALLED_APP"
        return 0
    fi

    if ! install -m 0755 "$staged" "$bin_dir/fedit"; then
        rm -f "$staged"
        warn "could not install the fedit command into $bin_dir — skipping"
        return 0
    fi
    rm -f "$staged"

    printf 'Installed %s\n' "$bin_dir/fedit"
    case ":$PATH:" in
        *":$bin_dir:"*) ;;
        *) printf '%s is not on your PATH — add it to run `fedit` directly.\n' "$bin_dir" ;;
    esac
}

usage() {
    printf 'usage: install.sh [destination-directory]   (default: %s)\n' "$DEFAULT_DEST"
}

# --- Arguments ---

case "${1:-}" in
    -h|--help)
        usage
        exit 0
        ;;
esac

if [ "$#" -gt 1 ]; then
    usage >&2
    exit 2
fi

DEST="${1:-$DEFAULT_DEST}"
[ -e "$DEST" ] || die "destination does not exist: $DEST"
[ -d "$DEST" ] || die "destination is not a directory: $DEST"
[ -w "$DEST" ] || die "destination is not writable: $DEST (re-run with sudo?)"
DEST=$(cd -- "$DEST" && pwd)
readonly DEST
readonly INSTALLED_APP="$DEST/$APP_NAME"

[ -d "$PROJECT" ] || die "project not found: $PROJECT"
command -v xcodebuild >/dev/null 2>&1 || die "xcodebuild not found — install Xcode and its command line tools"

# --- Build ---

printf 'Building %s (%s) into %s\n\n' "$SCHEME" "$CONFIGURATION" "$DERIVED_DATA"
if ! xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -derivedDataPath "$DERIVED_DATA" \
    build; then
    die "xcodebuild failed (see the output above) — nothing was installed"
fi

readonly BUILT_APP="$DERIVED_DATA/Build/Products/$CONFIGURATION/$APP_NAME"
[ -d "$BUILT_APP" ] || die "build reported success but $APP_NAME is missing at $BUILT_APP"

# --- Install ---

# Remove any old copy first: merging into an existing bundle would leave stale
# files behind and invalidate the ad-hoc code signature.
if [ -e "$INSTALLED_APP" ]; then
    printf '\nRemoving existing %s\n' "$INSTALLED_APP"
    rm -rf "$INSTALLED_APP" || die "could not remove $INSTALLED_APP"
fi

# ditto rather than cp -R: it preserves extended attributes and the ad-hoc
# code signature.
printf 'Copying %s to %s\n' "$BUILT_APP" "$INSTALLED_APP"
ditto "$BUILT_APP" "$INSTALLED_APP" || die "could not copy $APP_NAME to $DEST"

printf '\nInstalled %s\n' "$INSTALLED_APP"

install_cli_shim

printf 'If FEdit is already running, quit it and relaunch to pick up this build.\n'
