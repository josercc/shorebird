#!/usr/bin/env bash
# Build a FlutterPatch CLI install archive for the current host OS/arch.
#
# Usage:
#   ./scripts/package_cli.sh [output_dir]
#
# Produces:
#   flutterpatch-cli-<version>-<os>-<arch>.zip|.tar.gz
#
# Layout inside the archive:
#   flutterpatch/
#     bin/flutterpatch[.exe]
#     bin/internal/flutter.version
#     INSTALL.txt
#
# One-click install (after publishing to cli_releases):
#   curl -fsSL https://<site>/downloads/install_cli.sh | bash
#   ./scripts/install.sh --archive dist/cli/flutterpatch-cli-*.tar.gz --force
#
# Manual: extract to ~/.flutterpatch, add .../bin to PATH.
# Install script (or first release/patch) places Flutter under bin/cache/.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="${1:-$ROOT/dist/cli}"
mkdir -p "$OUT_DIR"

VERSION="$(
  dart -e "import 'dart:io'; print(File('$ROOT/packages/shorebird_cli/pubspec.yaml').readAsStringSync().split('\n').firstWhere((l) => l.startsWith('version:')).split(':').last.trim());" \
    2>/dev/null || true
)"
if [[ -z "${VERSION:-}" ]]; then
  VERSION="$(grep -E '^version:' "$ROOT/packages/shorebird_cli/pubspec.yaml" | head -1 | awk '{print $2}')"
fi
FLUTTER_VERSION="$(tr -d '[:space:]' < "$ROOT/bin/internal/flutter.version")"

OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
ARCH="$(uname -m)"
case "$ARCH" in
  x86_64|amd64) ARCH=x64 ;;
  aarch64|arm64) ARCH=arm64 ;;
esac
case "$OS" in
  darwin) OS=macos ;;
  mingw*|msys*|cygwin*) OS=windows ;;
esac

STAGE="$OUT_DIR/stage/flutterpatch"
rm -rf "$OUT_DIR/stage"
mkdir -p "$STAGE/bin/internal"

echo "==> pub get (workspace)"
(cd "$ROOT" && dart pub get)

BIN_NAME="flutterpatch"
if [[ "$OS" == "windows" ]]; then
  BIN_NAME="flutterpatch.exe"
fi

echo "==> dart compile exe → $STAGE/bin/$BIN_NAME"
(cd "$ROOT" && dart compile exe \
  packages/shorebird_cli/bin/shorebird.dart \
  -o "$STAGE/bin/$BIN_NAME")

cp "$ROOT/bin/internal/flutter.version" "$STAGE/bin/internal/flutter.version"

cat > "$STAGE/INSTALL.txt" <<EOF
FlutterPatch CLI ${VERSION}
Platform: ${OS}-${ARCH}
Pinned Shorebird Flutter revision: ${FLUTTER_VERSION}

One-click install (recommended)
-------------------------------
macOS / Linux:
  curl -fsSL https://<your-site>/downloads/install_cli.sh | bash

Windows (PowerShell):
  iwr -UseBasicParsing https://<your-site>/downloads/install_cli.ps1 | iex

Dev / offline (this archive):
  ./scripts/install.sh --archive <this-file> --force
  .\\scripts\\install.ps1 -Archive <this-file> -Force

Manual install
--------------
1. Extract this archive somewhere permanent, e.g.:
     macOS/Linux: ~/.flutterpatch
     Windows:     %USERPROFILE%\\.flutterpatch
2. Add the bin/ directory to your PATH.
3. Open a new terminal and run:
     flutterpatch --help
     flutterpatch doctor

Notes
-----
- This package is an AOT binary + flutter.version pin.
- The install script clones the Shorebird Flutter SDK into:
     ~/.flutterpatch/bin/cache/flutter/<revision>
  (or on first release/patch if you passed --skip-flutter).
- Set FLUTTERPATCH_TOKEN and run flutterpatch init (writes flutterpatch.yaml)
  before release/patch.
- Upgrade by re-running the install script / downloading a newer archive
  (flutterpatch upgrade is not used for packaged installs).
EOF

ARCHIVE_BASE="flutterpatch-cli-${VERSION}-${OS}-${ARCH}"
if [[ "$OS" == "windows" ]]; then
  ARCHIVE="$OUT_DIR/${ARCHIVE_BASE}.zip"
  rm -f "$ARCHIVE"
  # Prefer zip(1); fall back to Windows tar (GitHub Actions has no zip).
  if command -v zip >/dev/null 2>&1; then
    (cd "$OUT_DIR/stage" && zip -qr "$ARCHIVE" flutterpatch)
  else
    (cd "$OUT_DIR/stage" && tar -a -cf "$ARCHIVE" flutterpatch)
  fi
else
  ARCHIVE="$OUT_DIR/${ARCHIVE_BASE}.tar.gz"
  rm -f "$ARCHIVE"
  (cd "$OUT_DIR/stage" && tar -czf "$ARCHIVE" flutterpatch)
fi

echo "==> Done: $ARCHIVE"
ls -lh "$ARCHIVE"
