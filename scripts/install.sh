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
#  (or into the directory given as the single optional argument):
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
printf 'If FEdit is already running, quit it and relaunch to pick up this build.\n'
