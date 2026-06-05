#!/usr/bin/env bash
# Assemble a real .app bundle around the SwiftPM executable so that macOS TCC
# (microphone / accessibility / speech) attaches to a stable bundle identity.
set -euo pipefail

APP_NAME="Dictation"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

BIN_PATH="$(swift build -c release --show-bin-path)"
EXECUTABLE="${BIN_PATH}/${APP_NAME}"

if [[ ! -f "$EXECUTABLE" ]]; then
  echo "error: executable not found at $EXECUTABLE — run 'swift build -c release' first" >&2
  exit 1
fi

APP_DIR="${ROOT}/.build/${APP_NAME}.app"
CONTENTS="${APP_DIR}/Contents"

rm -rf "$APP_DIR"
mkdir -p "${CONTENTS}/MacOS" "${CONTENTS}/Resources"

cp "$EXECUTABLE" "${CONTENTS}/MacOS/${APP_NAME}"
cp "${ROOT}/Resources/Info.plist" "${CONTENTS}/Info.plist"

# Ad-hoc sign so the Accessibility/Microphone grants persist across rebuilds.
codesign --force --deep --sign - "$APP_DIR" >/dev/null 2>&1 || \
  echo "warning: ad-hoc codesign failed; permissions may need re-granting after rebuilds" >&2

echo "Built ${APP_DIR}"
