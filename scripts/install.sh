#!/usr/bin/env bash
# FlutterPatch CLI one-click install (macOS / Linux).
#
# Mirrors Shorebird's curl|bash UX, but installs a packaged AOT archive into
# ~/.flutterpatch (does NOT git-clone this fork).
#
# Usage:
#   curl -fsSL https://<site>/downloads/install_cli.sh | bash
#   ./scripts/install.sh                 # resume / repair if already present
#   ./scripts/install.sh --force         # reinstall CLI (keeps Flutter cache)
#   ./scripts/install.sh --archive dist/cli/flutterpatch-cli-*.tar.gz
#   ./scripts/install.sh --flutter-version 3.27.4
#   ./scripts/install.sh --version 1.2.3 --skip-flutter
#
# Re-running after a failure resumes: skips CLI download when the binary
# exists, resumes an interrupted Flutter git checkout, and skips engine
# bootstrap when the toolchain cache is already present. Use --force to
# re-download/overwrite the CLI package.
#
# Prefer --flutter-version <semver|git-hash> to install only the Flutter SDK
# you will release/patch with (updates bin/internal/flutter.version and prunes
# other cached revisions). Or pass --skip-flutter to defer download until
# first release/patch.
#
# Environment:
#   FLUTTERPATCH_ROOT                 install dir (default: ~/.flutterpatch)
#   FLUTTERPATCH_DOWNLOADS_ENDPOINT   Appwrite Function executions URL
#   FLUTTERPATCH_DOWNLOADS_PROJECT_ID Appwrite project id
#   FLUTTERPATCH_CLI_URL              direct archive URL (skips catalog)
#   FLUTTERPATCH_FLUTTER_GIT_URL      Flutter fork git URL
#   FLUTTERPATCH_ENGINE_CDN           engine CDN (default: download.shorebird.dev)
#   FLUTTER_STORAGE_BASE_URL          ignored during install (unset; China Flutter
#                                     mirrors do not host Shorebird engines)
set -euo pipefail

# Shorebird engine artifacts only live on download.shorebird.dev. User shells
# often export FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn which
# returns NoSuchKey (~471B XML) for Shorebird engine hashes — unset it so
# bootstrap cannot accidentally inherit a Flutter China mirror.
if [[ -n "${FLUTTER_STORAGE_BASE_URL:-}" ]]; then
  echo "Ignoring FLUTTER_STORAGE_BASE_URL=${FLUTTER_STORAGE_BASE_URL} (Shorebird engines are not on Flutter mirrors)"
  unset FLUTTER_STORAGE_BASE_URL
fi

# Defaults mirror deploy/install_remote.sh (DNS may still be IP-backed).
_DEFAULT_DOWNLOADS_ENDPOINT="${FLUTTERPATCH_DEFAULT_DOWNLOADS_ENDPOINT:-http://139.199.88.243:8080/v1/functions/meta_ota_website_downloads/executions}"
_DEFAULT_DOWNLOADS_PROJECT="${FLUTTERPATCH_DEFAULT_DOWNLOADS_PROJECT_ID:-6a97bce0001ab547c5f8}"
_DEFAULT_FLUTTER_GIT="${FLUTTERPATCH_FLUTTER_GIT_URL:-https://github.com/shorebirdtech/flutter.git}"
_DEFAULT_ENGINE_CDN="${FLUTTERPATCH_ENGINE_CDN:-https://download.shorebird.dev}"

FORCE=false
SKIP_PATH=false
SKIP_FLUTTER=false
VERSION=""
FLUTTER_VERSION_ARG=""
ARCHIVE=""
CLI_URL="${FLUTTERPATCH_CLI_URL:-}"

usage() {
  cat <<'EOF'
FlutterPatch CLI installer

Options:
  --force                 Reinstall CLI over an existing ~/.flutterpatch (keeps Flutter cache)
  --version VER           Prefer this CLI version from the download catalog
  --flutter-version VER   Install this Shorebird Flutter (semver or git hash).
                          Pins bin/internal/flutter.version and removes other
                          cached Flutter revisions to save disk space.
  --archive PATH          Install from a local .tar.gz / .zip (dev / offline)
  --url URL               Download this archive URL (skips catalog)
  --skip-path             Do not modify shell rc files
  --skip-flutter          Do not clone/precache the Shorebird Flutter SDK
  -h, --help              Show this help

Without --force, re-running resumes and only completes missing steps.
Without --flutter-version, installs the Flutter revision pinned in the CLI package.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --force) FORCE=true; shift ;;
    --skip-path) SKIP_PATH=true; shift ;;
    --skip-flutter) SKIP_FLUTTER=true; shift ;;
    --version) VERSION="${2:-}"; shift 2 ;;
    --flutter-version) FLUTTER_VERSION_ARG="${2:-}"; shift 2 ;;
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

if [[ -n "$FLUTTER_VERSION_ARG" && "$SKIP_FLUTTER" == true ]]; then
  echo "Error: --flutter-version and --skip-flutter cannot be used together." >&2
  exit 1
fi

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

flutter_toolchain_bootstrapped() {
  local flutter_path="$1"
  # Require a real dart binary — an empty dart-sdk/ dir is a failed bootstrap.
  [[ -x "$flutter_path/bin/cache/dart-sdk/bin/dart" ]] || return 1
  [[ -f "$flutter_path/bin/cache/flutter_tools.stamp" \
    || -f "$flutter_path/bin/cache/flutter_tools.snapshot" \
    || -f "$flutter_path/bin/cache/flutter_tools.dill" ]] || return 1
  return 0
}

# Resolve semver (flutter_release/<ver>) or a git hash to a full revision.
resolve_flutter_revision() {
  local want="$1"
  need_cmd git
  want="$(printf '%s' "$want" | tr -d '[:space:]' | sed 's/^v//')"
  if [[ -z "$want" ]]; then
    echo "Error: empty --flutter-version" >&2
    return 1
  fi

  # Semver-like → Shorebird release branch tip.
  if [[ "$want" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.+-][0-9A-Za-z.+-]*)?$ ]]; then
    echo "Resolving Flutter $want via flutter_release/$want …" >&2
    local line rev
    line="$(git ls-remote --heads "$_DEFAULT_FLUTTER_GIT" "refs/heads/flutter_release/${want}" | head -1 || true)"
    rev="$(printf '%s' "$line" | awk '{print $1}')"
    if [[ -z "$rev" ]]; then
      echo "Error: no Shorebird Flutter release branch flutter_release/$want" >&2
      echo "  Check: flutterpatch flutter versions list (after install), or pass a git hash." >&2
      return 1
    fi
    printf '%s' "$rev"
    return 0
  fi

  # Git hash (short or full).
  if [[ "$want" =~ ^[0-9a-fA-F]{7,40}$ ]]; then
    echo "Resolving Flutter git revision $want …" >&2
    local line rev
    line="$(git ls-remote "$_DEFAULT_FLUTTER_GIT" "$want" | head -1 || true)"
    rev="$(printf '%s' "$line" | awk '{print $1}')"
    if [[ -n "$rev" ]]; then
      printf '%s' "$rev"
      return 0
    fi
    # Ambiguous short hash may not appear in ls-remote; accept as-is if full-ish.
    if [[ ${#want} -ge 40 ]]; then
      printf '%s' "$(printf '%s' "$want" | tr '[:upper:]' '[:lower:]')"
      return 0
    fi
    echo "Error: could not resolve git revision $want on $_DEFAULT_FLUTTER_GIT" >&2
    return 1
  fi

  echo "Error: --flutter-version must be a Flutter semver (e.g. 3.27.4) or git hash." >&2
  return 1
}

pin_flutter_version() {
  local root="$1" rev="$2" label="$3"
  local version_file="$root/bin/internal/flutter.version"
  mkdir -p "$root/bin/internal"
  printf '%s\n' "$rev" >"$version_file"
  echo "Pinned Flutter ${label} → $rev ($version_file)"
}

# Keep only the active revision under bin/cache/flutter/.
prune_other_flutter_sdks() {
  local root="$1" keep_rev="$2"
  local cache="$root/bin/cache/flutter"
  [[ -d "$cache" ]] || return 0
  local dir name
  for dir in "$cache"/*; do
    [[ -e "$dir" ]] || continue
    name="$(basename "$dir")"
    if [[ "$name" == "$keep_rev" ]]; then
      continue
    fi
    echo "Removing unused Flutter cache: $dir"
    rm -rf "$dir"
  done
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
  elif [[ -d "$flutter_path/.git" ]]; then
    echo "Resuming incomplete Flutter checkout ($rev)…"
    git -C "$flutter_path" -c advice.detachedHead=false fetch --filter=tree:0 origin "$rev" || true
    git -C "$flutter_path" -c advice.detachedHead=false checkout "$rev"
  else
    echo "Installing Shorebird Flutter ($rev)…"
    rm -rf "$flutter_path"
    git clone --filter=tree:0 "$_DEFAULT_FLUTTER_GIT" --no-checkout "$flutter_path"
    git -C "$flutter_path" -c advice.detachedHead=false checkout "$rev"
  fi

  if flutter_toolchain_bootstrapped "$flutter_path"; then
    echo "Flutter engine artifacts already present; skipping bootstrap"
    prune_other_flutter_sdks "$root" "$rev"
    return 0
  fi

  # Clear incomplete bootstrap leftovers so Flutter can re-download cleanly.
  rm -rf "$flutter_path/bin/cache/dart-sdk" \
    "$flutter_path/bin/cache/dart-sdk.old" \
    "$flutter_path/bin/cache"/dart-sdk-*.zip

  echo "Bootstrapping Flutter engine artifacts…"
  FLUTTER_STORAGE_BASE_URL="$_DEFAULT_ENGINE_CDN" \
    "$flutter_path/bin/flutter" --disable-analytics >/dev/null 2>&1 || true
  FLUTTER_STORAGE_BASE_URL="$_DEFAULT_ENGINE_CDN" \
    "$flutter_path/bin/flutter" --version

  prune_other_flutter_sdks "$root" "$rev"
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

RESUME=false
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
    RESUME=true
    echo "Existing install detected at $ROOT; resuming (use --force to reinstall CLI)…"
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
SKIP_CLI_PACKAGE=false

# Resume: keep an already-extracted CLI binary unless forced / explicitly given.
if [[ "$RESUME" == true && -x "$BIN_DIR/flutterpatch" && -z "$ARCHIVE" && -z "$CLI_URL" && -z "$VERSION" ]]; then
  SKIP_CLI_PACKAGE=true
  echo "CLI binary already present; skipping download"
fi

if [[ "$SKIP_CLI_PACKAGE" != true ]]; then
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
fi

if [[ ! -x "$BIN_DIR/flutterpatch" ]]; then
  echo "Error: expected executable at $BIN_DIR/flutterpatch" >&2
  exit 1
fi

if [[ -n "$FLUTTER_VERSION_ARG" ]]; then
  RESOLVED_FLUTTER_REV="$(resolve_flutter_revision "$FLUTTER_VERSION_ARG")"
  pin_flutter_version "$ROOT" "$RESOLVED_FLUTTER_REV" "$FLUTTER_VERSION_ARG"
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
