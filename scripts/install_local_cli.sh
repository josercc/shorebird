#!/usr/bin/env bash
# Compile the local FlutterPatch CLI and install it over the current machine
# install (or into the default location if none exists).
#
# Usage:
#   ./scripts/install_local_cli.sh
#   ./scripts/install_local_cli.sh --print-root   # only resolve / print install dir
#   ./scripts/install_local_cli.sh --force-default # ignore existing install; use default
#
# Resolution order for the install root:
#   1. FLUTTERPATCH_ROOT (if set)
#   2. Directory of `flutterpatch` on PATH (…/bin/flutterpatch → …)
#   3. Existing default roots that look installed (~/.flutterpatch, or
#      $XDG_CONFIG_HOME/flutterpatch)
#   4. Default: ~/.flutterpatch (created if missing)
#
# Writes:
#   $ROOT/bin/flutterpatch
#   $ROOT/bin/internal/flutter.version   (from this repo)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PRINT_ROOT_ONLY=false
FORCE_DEFAULT=false

usage() {
  cat <<'EOF'
Compile local FlutterPatch CLI into the current (or default) install directory.

Options:
  --print-root      Resolve and print the install root, then exit
  --force-default   Always install to the default root (~/.flutterpatch)
  -h, --help        Show this help

Environment:
  FLUTTERPATCH_ROOT   Override install root (same as packaged installer)
  DART                Dart binary to use (must be SDK >= 3.12)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --print-root) PRINT_ROOT_ONLY=true; shift ;;
    --force-default) FORCE_DEFAULT=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Error: required command not found: $1" >&2
    exit 1
  fi
}

default_install_dir() {
  if [[ -n "${FLUTTERPATCH_ROOT:-}" ]]; then
    printf '%s' "${FLUTTERPATCH_ROOT}"
    return
  fi
  if [[ -n "${XDG_CONFIG_HOME:-}" ]]; then
    printf '%s' "${XDG_CONFIG_HOME}/flutterpatch"
    return
  fi
  printf '%s' "${HOME}/.flutterpatch"
}

# True if [root] looks like a FlutterPatch / Shorebird install.
is_flutterpatch_root() {
  local root="$1"
  [[ -f "$root/bin/internal/flutter.version" ]] \
    || [[ -x "$root/bin/flutterpatch" ]] \
    || [[ -f "$root/bin/flutterpatch.exe" ]] \
    || [[ -f "$root/bin/cache/shorebird.snapshot" ]]
}

# $ROOT/bin/flutterpatch[.exe] or $ROOT/bin/cache/*.snapshot → ROOT
root_from_binary() {
  local binary="$1"
  local bin_dir parent_dir
  bin_dir="$(cd "$(dirname "$binary")" && pwd)"
  parent_dir="$(dirname "$bin_dir")"
  if [[ "$(basename "$bin_dir")" == "cache" && "$(basename "$parent_dir")" == "bin" ]]; then
    dirname "$parent_dir"
    return
  fi
  if [[ "$(basename "$bin_dir")" == "bin" ]]; then
    printf '%s' "$parent_dir"
    return
  fi
  # Fallback: treat parent of binary as bin/
  printf '%s' "$parent_dir"
}

resolve_install_root() {
  local candidate exe

  if [[ "$FORCE_DEFAULT" == true ]]; then
    default_install_dir
    return
  fi

  if [[ -n "${FLUTTERPATCH_ROOT:-}" ]]; then
    printf '%s' "${FLUTTERPATCH_ROOT}"
    return
  fi

  if command -v flutterpatch >/dev/null 2>&1; then
    exe="$(command -v flutterpatch)"
    # Prefer real path when the binary is a symlink into the install tree.
    if command -v realpath >/dev/null 2>&1; then
      exe="$(realpath "$exe")"
    elif command -v readlink >/dev/null 2>&1; then
      # macOS readlink has no -f; follow one level if linked.
      if [[ -L "$exe" ]]; then
        local linked
        linked="$(readlink "$exe")"
        if [[ "$linked" != /* ]]; then
          linked="$(cd "$(dirname "$exe")" && pwd)/$linked"
        fi
        exe="$linked"
      fi
    fi
    candidate="$(root_from_binary "$exe")"
    if is_flutterpatch_root "$candidate"; then
      printf '%s' "$candidate"
      return
    fi
  fi

  for candidate in \
    "${HOME}/.flutterpatch" \
    "${XDG_CONFIG_HOME:+$XDG_CONFIG_HOME/flutterpatch}"; do
    [[ -z "$candidate" ]] && continue
    if is_flutterpatch_root "$candidate"; then
      printf '%s' "$candidate"
      return
    fi
  done

  default_install_dir
}

INSTALL_ROOT="$(resolve_install_root)"

if [[ "$PRINT_ROOT_ONLY" == true ]]; then
  echo "$INSTALL_ROOT"
  if is_flutterpatch_root "$INSTALL_ROOT"; then
    echo "(existing install)" >&2
  else
    echo "(default; not installed yet)" >&2
  fi
  exit 0
fi

# very_good_analysis ^10.3.0 (workspace root) requires Dart SDK ^3.12.0.
MIN_DART_MAJOR=3
MIN_DART_MINOR=12

dart_version_ok() {
  local dart_bin="$1" ver major minor
  [[ -x "$dart_bin" ]] || return 1
  ver="$("$dart_bin" --version 2>&1 | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
  [[ -n "$ver" ]] || return 1
  major="${ver%%.*}"
  minor="${ver#*.}"
  minor="${minor%%.*}"
  if (( major > MIN_DART_MAJOR )); then
    return 0
  fi
  if (( major == MIN_DART_MAJOR && minor >= MIN_DART_MINOR )); then
    return 0
  fi
  return 1
}

# Prefer an explicit DART=, then PATH / Homebrew / FVM Flutter SDKs.
resolve_dart() {
  local candidate fvm_root

  if [[ -n "${DART:-}" ]]; then
    if dart_version_ok "$DART"; then
      printf '%s' "$DART"
      return
    fi
    echo "Error: DART=$DART is older than ${MIN_DART_MAJOR}.${MIN_DART_MINOR}" >&2
    exit 1
  fi

  for candidate in \
    "$(command -v dart 2>/dev/null || true)" \
    /opt/homebrew/bin/dart \
    /usr/local/bin/dart; do
    [[ -z "$candidate" ]] && continue
    if dart_version_ok "$candidate"; then
      printf '%s' "$candidate"
      return
    fi
  done

  fvm_root="${FVM_CACHE_PATH:-${FVM_HOME:-$HOME/fvm}}/versions"
  if [[ -d "$fvm_root" ]]; then
    # Newest version directory first (lexicographic works for x.y.z).
    while IFS= read -r candidate; do
      if dart_version_ok "$candidate"; then
        printf '%s' "$candidate"
        return
      fi
    done < <(find "$fvm_root" -path '*/bin/cache/dart-sdk/bin/dart' -type f 2>/dev/null | sort -r)
  fi

  echo "Error: need Dart SDK >= ${MIN_DART_MAJOR}.${MIN_DART_MINOR} (workspace very_good_analysis ^10.3.0)." >&2
  echo "  PATH dart is too old, or missing. Install Dart 3.12+ / Flutter 3.42+, or set DART=..." >&2
  if command -v dart >/dev/null 2>&1; then
    echo "  current: $(command -v dart) → $(dart --version 2>&1)" >&2
  fi
  exit 1
}

DART_BIN="$(resolve_dart)"
echo "==> Using Dart: $DART_BIN ($("$DART_BIN" --version 2>&1))"

BIN_DIR="$INSTALL_ROOT/bin"
INTERNAL_DIR="$BIN_DIR/internal"
BIN_NAME="flutterpatch"
case "$(uname -s | tr '[:upper:]' '[:lower:]')" in
  mingw*|msys*|cygwin*) BIN_NAME="flutterpatch.exe" ;;
esac
OUT_BIN="$BIN_DIR/$BIN_NAME"
TMP_BIN="$BIN_DIR/.${BIN_NAME}.tmp.$$"
PIN_SRC="$REPO_ROOT/bin/internal/flutter.version"

if [[ ! -f "$PIN_SRC" ]]; then
  echo "Error: missing Flutter pin file: $PIN_SRC" >&2
  exit 1
fi

if is_flutterpatch_root "$INSTALL_ROOT"; then
  echo "==> Replacing existing install at: $INSTALL_ROOT"
else
  echo "==> No FlutterPatch install found; installing to default: $INSTALL_ROOT"
fi

mkdir -p "$INTERNAL_DIR"

echo "==> pub get (workspace)"
(cd "$REPO_ROOT" && "$DART_BIN" pub get)

# Keep --version in sync with packages/shorebird_cli/pubspec.yaml.
echo "==> build_runner (sync lib/src/version.dart)"
(cd "$REPO_ROOT/packages/shorebird_cli" && "$DART_BIN" run build_runner build)

echo "==> dart compile exe → $OUT_BIN"
cleanup_tmp() {
  rm -f "$TMP_BIN"
}
trap cleanup_tmp EXIT

(cd "$REPO_ROOT" && "$DART_BIN" compile exe \
  packages/shorebird_cli/bin/shorebird.dart \
  -o "$TMP_BIN")

mv -f "$TMP_BIN" "$OUT_BIN"
chmod +x "$OUT_BIN"
trap - EXIT

cp "$PIN_SRC" "$INTERNAL_DIR/flutter.version"

echo "==> Done"
echo "    binary:  $OUT_BIN"
echo "    version pin: $INTERNAL_DIR/flutter.version ($(tr -d '[:space:]' <"$INTERNAL_DIR/flutter.version"))"
if ! command -v flutterpatch >/dev/null 2>&1 \
  || [[ "$(command -v flutterpatch)" != "$OUT_BIN" && "$(realpath "$(command -v flutterpatch)" 2>/dev/null || true)" != "$OUT_BIN" ]]; then
  echo
  echo "Add to PATH if needed:"
  echo "  export FLUTTERPATCH_ROOT=\"$INSTALL_ROOT\""
  echo "  export PATH=\"$BIN_DIR:\$PATH\""
fi
"$OUT_BIN" --version 2>/dev/null || "$OUT_BIN" version 2>/dev/null || true
