#!/usr/bin/env bash
# FlutterPatch CLI one-click install (macOS / Linux).
#
# Mirrors Shorebird's curl|bash UX, but installs a packaged AOT archive into
# ~/.flutterpatch (does NOT git-clone this fork).
#
# Usage:
#   curl -fsSL https://<site>/downloads/install_cli.sh | bash
#   ./scripts/install.sh --force
#   ./scripts/install.sh --archive dist/cli/flutterpatch-cli-*.tar.gz
#   ./scripts/install.sh --version 1.2.3 --skip-flutter
#
# Environment:
#   FLUTTERPATCH_ROOT                 install dir (default: ~/.flutterpatch)
#   FLUTTERPATCH_DOWNLOADS_ENDPOINT   Appwrite Function executions URL
#   FLUTTERPATCH_DOWNLOADS_PROJECT_ID Appwrite project id
#   FLUTTERPATCH_CLI_URL              direct archive URL (skips catalog)
#   FLUTTERPATCH_FLUTTER_GIT_URL      Flutter fork git URL
#   FLUTTER_STORAGE_BASE_URL          engine CDN (default: download.shorebird.dev)
set -euo pipefail

# Defaults mirror deploy/install_remote.sh (DNS may still be IP-backed).
_DEFAULT_DOWNLOADS_ENDPOINT="${FLUTTERPATCH_DEFAULT_DOWNLOADS_ENDPOINT:-http://139.199.88.243:8080/v1/functions/meta_ota_website_downloads/executions}"
_DEFAULT_DOWNLOADS_PROJECT="${FLUTTERPATCH_DEFAULT_DOWNLOADS_PROJECT_ID:-6a97bce0001ab547c5f8}"
_DEFAULT_FLUTTER_GIT="${FLUTTERPATCH_FLUTTER_GIT_URL:-https://github.com/shorebirdtech/flutter.git}"
_DEFAULT_ENGINE_CDN="${FLUTTER_STORAGE_BASE_URL:-https://download.shorebird.dev}"

FORCE=false
SKIP_PATH=false
SKIP_FLUTTER=false
VERSION=""
ARCHIVE=""
CLI_URL="${FLUTTERPATCH_CLI_URL:-}"

usage() {
  cat <<'EOF'
FlutterPatch CLI installer

Options:
  --force           Overwrite an existing ~/.flutterpatch install
  --version VER     Prefer this CLI version from the download catalog
  --archive PATH    Install from a local .tar.gz / .zip (dev / offline)
  --url URL         Download this archive URL (skips catalog)
  --skip-path       Do not modify shell rc files
  --skip-flutter    Do not clone/precache the Shorebird Flutter SDK
  -h, --help        Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --force) FORCE=true; shift ;;
    --skip-path) SKIP_PATH=true; shift ;;
    --skip-flutter) SKIP_FLUTTER=true; shift ;;
    --version) VERSION="${2:-}"; shift 2 ;;
    --archive) ARCHIVE="${2:-}"; shift 2 ;;
    --url) CLI_URL="${2:-}"; shift 2 ;;
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

need_cmd curl
need_cmd tar
need_cmd uname
need_cmd mktemp

if [[ -z "$ARCHIVE" ]]; then
  need_cmd python3
fi

install_dir() {
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

host_os() {
  case "$(uname -s | tr '[:upper:]' '[:lower:]')" in
    darwin*) echo macos ;;
    linux*) echo linux ;;
    mingw*|msys*|cygwin*) echo windows ;;
    *)
      echo "Error: unsupported OS $(uname -s)" >&2
      exit 1
      ;;
  esac
}

host_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo x64 ;;
    aarch64|arm64) echo arm64 ;;
    *)
      echo "Error: unsupported arch $(uname -m)" >&2
      exit 1
      ;;
  esac
}

downloads_endpoint() {
  printf '%s' "${FLUTTERPATCH_DOWNLOADS_ENDPOINT:-$_DEFAULT_DOWNLOADS_ENDPOINT}"
}

downloads_project() {
  printf '%s' "${FLUTTERPATCH_DOWNLOADS_PROJECT_ID:-${FLUTTERPATCH_DOWNLOADS_PROJECT:-$_DEFAULT_DOWNLOADS_PROJECT}}"
}

# Resolve catalog → print: url\tversion\tsha256\tfilename
resolve_from_catalog() {
  local os="$1" arch="$2" want_version="$3"
  local endpoint project payload resp
  endpoint="$(downloads_endpoint)"
  project="$(downloads_project)"
  if [[ -z "$endpoint" || -z "$project" ]]; then
    echo "Error: set FLUTTERPATCH_DOWNLOADS_ENDPOINT and FLUTTERPATCH_DOWNLOADS_PROJECT_ID, or pass --url / --archive." >&2
    return 1
  fi

  payload='{"action":"list_cli"}'
  resp="$(curl -fsSL \
    -H "Content-Type: application/json" \
    -H "X-Appwrite-Project: ${project}" \
    -d "$payload" \
    "$endpoint")"

  python3 - "$resp" "$os" "$arch" "$want_version" <<'PY'
import json, sys

raw, os_name, arch, want = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
data = json.loads(raw)
# Appwrite Function wrapper may nest JSON in responseBody.
if isinstance(data, dict) and isinstance(data.get("responseBody"), str):
    try:
        data = json.loads(data["responseBody"])
    except json.JSONDecodeError:
        pass
if not isinstance(data, dict) or data.get("ok") is False:
    print(f"Error: catalog request failed: {data}", file=sys.stderr)
    sys.exit(1)
rows = data.get("cli") or []
candidates = [
    r for r in rows
    if str(r.get("platform", "")).lower() == os_name
    and str(r.get("arch", "")).lower() in {arch, "amd64" if arch == "x64" else arch, "x86_64" if arch == "x64" else arch}
]
if want:
    want_n = want.lstrip("vV")
    candidates = [r for r in candidates if str(r.get("version", "")).lstrip("vV") == want_n]
if not candidates:
    print(
        f"Error: no CLI package for {os_name}-{arch}"
        + (f" version {want}" if want else ""),
        file=sys.stderr,
    )
    sys.exit(1)

def ver_key(v: str):
    parts = []
    for p in str(v).lstrip("vV").replace("-", ".").split("."):
        parts.append(int(p) if p.isdigit() else p)
    return parts

candidates.sort(key=lambda r: ver_key(r.get("version") or ""), reverse=True)
row = candidates[0]
url = (row.get("download_url") or "").strip()
if not url:
    print("Error: catalog row missing download_url", file=sys.stderr)
    sys.exit(1)
print("\t".join([
    url,
    str(row.get("version") or "").strip(),
    str(row.get("sha256") or "").strip().lower(),
    str(row.get("filename") or "").strip(),
]))
PY
}

add_to_path() {
  local bin_dir="$1"
  local found_rc=false
  local rc_file
  echo "Adding FlutterPatch to your PATH"

  for rc_file in "$HOME/.bashrc" "$HOME/.zshrc"; do
    if [[ -e "$rc_file" ]]; then
      found_rc=true
      if grep -Fq "$bin_dir" "$rc_file" 2>/dev/null; then
        echo "Already present in $rc_file"
      else
        echo "Updating $rc_file"
        printf '\n# FlutterPatch CLI\nexport PATH="%s:$PATH"\n' "$bin_dir" >>"$rc_file"
      fi
    fi
  done

  if [[ "$found_rc" != true ]]; then
    echo "Unable to determine shell type. Add FlutterPatch to your PATH manually:"
    echo "  export PATH=\"$bin_dir:\$PATH\""
  fi
}

verify_sha256() {
  local file="$1" expect="$2"
  [[ -z "$expect" ]] && return 0
  local actual=""
  if command -v shasum >/dev/null 2>&1; then
    actual="$(shasum -a 256 "$file" | awk '{print $1}')"
  elif command -v sha256sum >/dev/null 2>&1; then
    actual="$(sha256sum "$file" | awk '{print $1}')"
  else
    echo "Warning: no sha256 tool; skipping checksum verify" >&2
    return 0
  fi
  actual="$(printf '%s' "$actual" | tr '[:upper:]' '[:lower:]')"
  expect="$(printf '%s' "$expect" | tr '[:upper:]' '[:lower:]')"
  if [[ "$actual" != "$expect" ]]; then
    echo "Error: sha256 mismatch (expected $expect, got $actual)" >&2
    return 1
  fi
}

extract_archive() {
  local archive="$1" dest="$2"
  mkdir -p "$dest"
  case "$archive" in
    *.tar.gz|*.tgz)
      tar -xzf "$archive" -C "$dest"
      ;;
    *.zip)
      need_cmd unzip
      unzip -q "$archive" -d "$dest"
      ;;
    *)
      echo "Error: unsupported archive format: $archive" >&2
      return 1
      ;;
  esac
}

# package_cli layout is flutterpatch/{bin,...}; accept either that or a flat bin/.
normalize_extract_tree() {
  local staging="$1"
  if [[ -d "$staging/flutterpatch/bin" ]]; then
    printf '%s' "$staging/flutterpatch"
    return
  fi
  if [[ -d "$staging/bin" ]]; then
    printf '%s' "$staging"
    return
  fi
  # Some archives nest one extra directory.
  local child
  child="$(find "$staging" -mindepth 1 -maxdepth 1 -type d | head -1 || true)"
  if [[ -n "$child" && -d "$child/bin" ]]; then
    printf '%s' "$child"
    return
  fi
  echo "Error: archive missing bin/ (expected flutterpatch/bin/...)" >&2
  return 1
}

init_flutter_toolchain() {
  local root="$1"
  local version_file="$root/bin/internal/flutter.version"
  if [[ ! -f "$version_file" ]]; then
    echo "Warning: missing $version_file; skipping Flutter init" >&2
    return 0
  fi
  need_cmd git
  local rev
  rev="$(tr -d '[:space:]' <"$version_file")"
  if [[ -z "$rev" ]]; then
    echo "Warning: empty flutter.version; skipping Flutter init" >&2
    return 0
  fi

  local flutter_path="$root/bin/cache/flutter/$rev"
  mkdir -p "$root/bin/cache/flutter"
  if [[ -x "$flutter_path/bin/flutter" ]]; then
    echo "Flutter SDK already present at $flutter_path"
  else
    echo "Installing Shorebird Flutter ($rev)…"
    rm -rf "$flutter_path"
    git clone --filter=tree:0 "$_DEFAULT_FLUTTER_GIT" --no-checkout "$flutter_path"
    git -C "$flutter_path" -c advice.detachedHead=false checkout "$rev"
  fi

  echo "Bootstrapping Flutter engine artifacts…"
  FLUTTER_STORAGE_BASE_URL="$_DEFAULT_ENGINE_CDN" \
    "$flutter_path/bin/flutter" --disable-analytics >/dev/null 2>&1 || true
  FLUTTER_STORAGE_BASE_URL="$_DEFAULT_ENGINE_CDN" \
    "$flutter_path/bin/flutter" --version
}

# -------------------- main --------------------

OS="$(host_os)"
ARCH="$(host_arch)"
ROOT="$(install_dir)"
BIN_DIR="$ROOT/bin"

if [[ "$OS" == "windows" ]]; then
  echo "Error: use install.ps1 on Windows." >&2
  exit 1
fi

echo "FlutterPatch CLI installer"
echo "  target: $ROOT"
echo "  platform: ${OS}-${ARCH}"

if [[ -d "$ROOT" ]]; then
  if [[ "$FORCE" == true ]]; then
    echo "Existing install detected. Overwriting (--force)…"
    # Keep Flutter cache if present to save bandwidth unless force-clean later.
    TMP_KEEP="$(mktemp -d "${TMPDIR:-/tmp}/flutterpatch-keep.XXXXXX")"
    if [[ -d "$ROOT/bin/cache/flutter" && "$SKIP_FLUTTER" != true ]]; then
      mv "$ROOT/bin/cache/flutter" "$TMP_KEEP/flutter" || true
    fi
    rm -rf "$ROOT"
    mkdir -p "$ROOT"
    if [[ -d "$TMP_KEEP/flutter" ]]; then
      mkdir -p "$ROOT/bin/cache"
      mv "$TMP_KEEP/flutter" "$ROOT/bin/cache/flutter"
    fi
    rm -rf "$TMP_KEEP"
  else
    echo "Error: existing FlutterPatch installation at $ROOT. Use --force to overwrite." >&2
    exit 1
  fi
else
  mkdir -p "$ROOT"
fi

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/flutterpatch-install.XXXXXX")"
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

ARCHIVE_PATH=""
RESOLVED_VERSION=""
RESOLVED_SHA=""

if [[ -n "$ARCHIVE" ]]; then
  if [[ ! -f "$ARCHIVE" ]]; then
    echo "Error: archive not found: $ARCHIVE" >&2
    exit 1
  fi
  ARCHIVE_PATH="$ARCHIVE"
  echo "Using local archive: $ARCHIVE_PATH"
elif [[ -n "$CLI_URL" ]]; then
  case "$CLI_URL" in
    *.zip) ARCHIVE_PATH="$WORKDIR/cli.zip" ;;
    *) ARCHIVE_PATH="$WORKDIR/cli.tar.gz" ;;
  esac
  echo "Downloading $CLI_URL …"
  curl -fL --progress-bar -o "$ARCHIVE_PATH" "$CLI_URL"
else
  echo "Resolving latest package from download catalog…"
  IFS=$'\t' read -r url resolved_version resolved_sha resolved_name < <(resolve_from_catalog "$OS" "$ARCH" "$VERSION")
  RESOLVED_VERSION="$resolved_version"
  RESOLVED_SHA="$resolved_sha"
  case "${resolved_name:-$url}" in
    *.zip) ARCHIVE_PATH="$WORKDIR/cli.zip" ;;
    *) ARCHIVE_PATH="$WORKDIR/cli.tar.gz" ;;
  esac
  echo "Downloading FlutterPatch CLI ${RESOLVED_VERSION:-} (${OS}-${ARCH})…"
  curl -fL --progress-bar -o "$ARCHIVE_PATH" "$url"
  verify_sha256 "$ARCHIVE_PATH" "$RESOLVED_SHA"
fi

STAGE="$WORKDIR/stage"
mkdir -p "$STAGE"
extract_archive "$ARCHIVE_PATH" "$STAGE"
SRC="$(normalize_extract_tree "$STAGE")"

# Copy package contents into install root.
# Prefer rsync if available; fall back to tar pipe.
if command -v rsync >/dev/null 2>&1; then
  rsync -a "$SRC"/ "$ROOT"/
else
  tar -C "$SRC" -cf - . | tar -C "$ROOT" -xf -
fi

chmod +x "$BIN_DIR/flutterpatch" 2>/dev/null || true

if [[ ! -x "$BIN_DIR/flutterpatch" ]]; then
  echo "Error: expected executable at $BIN_DIR/flutterpatch" >&2
  exit 1
fi

if [[ "$SKIP_FLUTTER" != true ]]; then
  init_flutter_toolchain "$ROOT"
else
  echo "Skipping Flutter SDK init (--skip-flutter). It will download on first release/patch."
fi

RELOAD_REQUIRED=false
case ":$PATH:" in
  *:"$BIN_DIR":*) ;;
  *)
    RELOAD_REQUIRED=true
    if [[ "$SKIP_PATH" != true ]]; then
      add_to_path "$BIN_DIR" >&2
    fi
    ;;
esac

echo ""
echo "FlutterPatch CLI has been installed to $ROOT"
if [[ -n "$RESOLVED_VERSION" ]]; then
  echo "  version: $RESOLVED_VERSION"
fi

# Smoke-check without requiring PATH.
if "$BIN_DIR/flutterpatch" --help >/dev/null 2>&1; then
  echo "  binary: ok"
fi

if [[ "$RELOAD_REQUIRED" == true ]]; then
  cat <<EOF

Close and reopen your terminal to start using FlutterPatch, or run:

  export PATH="$BIN_DIR:\$PATH"

Then:

  flutterpatch doctor
  export FLUTTERPATCH_TOKEN=<dashboard token>
  cd <your-flutter-app> && flutterpatch init
EOF
else
  cat <<EOF

Next:

  flutterpatch doctor
  export FLUTTERPATCH_TOKEN=<dashboard token>
  cd <your-flutter-app> && flutterpatch init
EOF
fi
