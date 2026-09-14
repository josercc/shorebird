#!/usr/bin/env bash
# FlutterPatch CLI one-click install (macOS / Linux).
#
# Installs the latest packaged CLI into ~/.flutterpatch.
# If that install already exists, exits without changing anything unless --force.
# Flutter SDKs are installed later via `flutterpatch flutter install|use`.
#
# Usage:
#   curl -fsSL https://<site>/downloads/install_cli.sh | bash
#   ./scripts/install.sh              # skip if already installed
#   ./scripts/install.sh --force      # reinstall / upgrade to latest CLI
#
# Environment:
#   FLUTTERPATCH_ROOT                 install dir (default: ~/.flutterpatch)
#   FLUTTERPATCH_DOWNLOADS_ENDPOINT   Appwrite Function executions URL
#   FLUTTERPATCH_DOWNLOADS_PROJECT_ID Appwrite project id
#   FLUTTERPATCH_CLI_URL              direct archive URL (skips catalog)
#   FLUTTERPATCH_CURL_USE_PROXY       set to 1 to honor http(s)_proxy
set -euo pipefail

_DEFAULT_DOWNLOADS_ENDPOINT="${FLUTTERPATCH_DEFAULT_DOWNLOADS_ENDPOINT:-http://139.199.88.243:8080/v1/functions/meta_ota_website_downloads/executions}"
_DEFAULT_DOWNLOADS_PROJECT="${FLUTTERPATCH_DEFAULT_DOWNLOADS_PROJECT_ID:-6a97bce0001ab547c5f8}"

FORCE=false

usage() {
  cat <<'EOF'
FlutterPatch CLI installer

Options:
  --force     Reinstall / upgrade to the latest CLI (keeps Flutter cache)
  -h, --help  Show this help

Without --force, skips if ~/.flutterpatch/bin/flutterpatch already exists.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --force) FORCE=true; shift ;;
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

curl_fp() {
  if [[ "${FLUTTERPATCH_CURL_USE_PROXY:-}" == "1" ]]; then
    curl "$@"
    return $?
  fi
  curl --proxy "" --noproxy "*" "$@"
  return $?
}

warn_if_proxy_set() {
  if [[ "${FLUTTERPATCH_CURL_USE_PROXY:-}" == "1" ]]; then
    return 0
  fi
  if [[ -n "${http_proxy:-}${HTTP_PROXY:-}${https_proxy:-}${HTTPS_PROXY:-}${ALL_PROXY:-}${all_proxy:-}" ]]; then
    echo "  note: bypassing http(s)_proxy for FlutterPatch downloads (set FLUTTERPATCH_CURL_USE_PROXY=1 to keep proxy)" >&2
  fi
}

run_with_timeout() {
  local secs="$1"
  shift
  "$@" &
  local pid=$!
  local waited=0
  while kill -0 "$pid" 2>/dev/null; do
    if (( waited >= secs )); then
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      return 124
    fi
    sleep 1
    waited=$((waited + 1))
  done
  wait "$pid"
}

python3_is_usable() {
  command -v python3 >/dev/null 2>&1 || return 1
  run_with_timeout 5 python3 -c 'print("ok")' >/dev/null 2>&1
}

# Parse catalog JSON → print: url\tversion\tsha256\tfilename (latest for os/arch).
parse_catalog_file() {
  local catalog_file="$1" os_name="$2" arch="$3"

  if command -v jq >/dev/null 2>&1; then
    jq -r --arg os "$os_name" --arg arch "$arch" '
      (if (.responseBody | type) == "string" then (.responseBody | fromjson) else . end) as $d
      | if ($d | type) != "object" or $d.ok == false then
          error("catalog request failed")
        else
          ($d.cli // [])
          | map(select(
              ((.platform // "") | ascii_downcase) == $os
              and (
                ((.arch // "") | ascii_downcase) == $arch
                or ($arch == "x64" and (((.arch // "") | ascii_downcase) == "amd64"
                    or ((.arch // "") | ascii_downcase) == "x86_64"))
              )
            ))
          | if length == 0 then
              error("no CLI package for \($os)-\($arch)")
            else
              sort_by(
                ((.version // "") | ltrimstr("v") | ltrimstr("V") | gsub("-"; ".") | split(".")
                  | map(tonumber? // .))
              )
              | reverse
              | .[0]
              | [
                  (.download_url // ""),
                  (.version // ""),
                  ((.sha256 // "") | ascii_downcase),
                  (.filename // "")
                ]
              | @tsv
            end
        end
    ' "$catalog_file"
    return $?
  fi

  if [[ "$(uname -s)" == "Darwin" ]] && command -v osascript >/dev/null 2>&1; then
    CATALOG_FILE="$catalog_file" OS_NAME="$os_name" ARCH_NAME="$arch" \
      osascript -l JavaScript <<'JS'
ObjC.import('Foundation');
function env(name) {
  const v = $.NSProcessInfo.processInfo.environment.objectForKey(name);
  return v ? ObjC.unwrap(v) : '';
}
function readUtf8(path) {
  const ns = $.NSString.stringWithContentsOfFileEncodingError(
    $(path), $.NSUTF8StringEncoding, null);
  if (!ns) throw new Error('cannot read catalog file: ' + path);
  return ObjC.unwrap(ns);
}
function verKey(v) {
  return String(v || '').replace(/^[vV]/, '').replace(/-/g, '.').split('.').map(function (p) {
    return /^\d+$/.test(p) ? Number(p) : p;
  });
}
function verCmp(a, b) {
  const aa = verKey(a), bb = verKey(b);
  const n = Math.max(aa.length, bb.length);
  for (let i = 0; i < n; i++) {
    const x = aa[i], y = bb[i];
    if (x === undefined) return -1;
    if (y === undefined) return 1;
    if (x === y) continue;
    if (typeof x === 'number' && typeof y === 'number') return x < y ? -1 : 1;
    return String(x) < String(y) ? -1 : 1;
  }
  return 0;
}
const path = env('CATALOG_FILE');
const osName = env('OS_NAME');
const arch = env('ARCH_NAME');
let data = JSON.parse(readUtf8(path));
if (data && typeof data.responseBody === 'string') {
  try { data = JSON.parse(data.responseBody); } catch (e) {}
}
if (!data || typeof data !== 'object' || data.ok === false) {
  throw new Error('catalog request failed');
}
const archSet = {};
archSet[arch] = true;
if (arch === 'x64') { archSet.amd64 = true; archSet.x86_64 = true; }
let candidates = (data.cli || []).filter(function (r) {
  const p = String(r.platform || '').toLowerCase();
  const a = String(r.arch || '').toLowerCase();
  return p === osName && archSet[a];
});
if (!candidates.length) {
  throw new Error('no CLI package for ' + osName + '-' + arch);
}
candidates.sort(function (a, b) { return verCmp(b.version, a.version); });
const row = candidates[0];
const url = String(row.download_url || '').trim();
if (!url) throw new Error('catalog row missing download_url');
[
  url,
  String(row.version || '').trim(),
  String(row.sha256 || '').trim().toLowerCase(),
  String(row.filename || '').trim()
].join('\t');
JS
    return $?
  fi

  if python3_is_usable; then
    python3 - "$catalog_file" "$os_name" "$arch" <<'PY'
import json, sys

path, os_name, arch = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)
if isinstance(data, dict) and isinstance(data.get("responseBody"), str):
    try:
        data = json.loads(data["responseBody"])
    except json.JSONDecodeError:
        pass
if not isinstance(data, dict) or data.get("ok") is False:
    print(f"Error: catalog request failed: {data}", file=sys.stderr)
    sys.exit(1)
rows = data.get("cli") or []
arch_ok = {arch}
if arch == "x64":
    arch_ok.update({"amd64", "x86_64"})
candidates = [
    r for r in rows
    if str(r.get("platform", "")).lower() == os_name
    and str(r.get("arch", "")).lower() in arch_ok
]
if not candidates:
    print(f"Error: no CLI package for {os_name}-{arch}", file=sys.stderr)
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
    return $?
  fi

  echo "Error: cannot parse download catalog (need jq, or macOS osascript, or a working python3)." >&2
  return 1
}

catalog_file_usable() {
  local f="$1"
  [[ -s "$f" ]] || return 1
  grep -q '"cli"' "$f" 2>/dev/null || return 1
  grep -qE '"ok"[[:space:]]*:[[:space:]]*true|"responseBody"' "$f" 2>/dev/null
}

resolve_from_catalog() {
  local os="$1" arch="$2"
  local endpoint project payload catalog_file curl_rc=0
  local attempt=1 max_attempts=3
  endpoint="$(downloads_endpoint)"
  project="$(downloads_project)"
  if [[ -z "$endpoint" || -z "$project" ]]; then
    echo "Error: set FLUTTERPATCH_DOWNLOADS_ENDPOINT and FLUTTERPATCH_DOWNLOADS_PROJECT_ID, or FLUTTERPATCH_CLI_URL." >&2
    return 1
  fi

  catalog_file="$(mktemp "${TMPDIR:-/tmp}/flutterpatch-catalog.XXXXXX")"
  payload='{"action":"list_cli"}'
  echo "  fetching catalog from $endpoint …" >&2
  warn_if_proxy_set

  while (( attempt <= max_attempts )); do
    : >"$catalog_file"
    set +e
    curl_fp -fsS \
      --connect-timeout 15 \
      --max-time 60 \
      --retry 0 \
      -H "Content-Type: application/json" \
      -H "Connection: close" \
      -H "X-Appwrite-Project: ${project}" \
      -d "$payload" \
      -o "$catalog_file" \
      "$endpoint"
    curl_rc=$?
    set -e

    if [[ "$curl_rc" -eq 0 ]] || catalog_file_usable "$catalog_file"; then
      if [[ "$curl_rc" -ne 0 ]]; then
        echo "  warning: catalog curl exited $curl_rc after receiving a usable body; continuing…" >&2
      fi
      break
    fi

    echo "  catalog fetch attempt $attempt/$max_attempts failed (curl exit $curl_rc)" >&2
    if (( attempt == max_attempts )); then
      rm -f "$catalog_file"
      echo "Error: failed to fetch download catalog from $endpoint (curl exit $curl_rc)" >&2
      return 1
    fi
    sleep $((attempt * 2))
    attempt=$((attempt + 1))
  done

  echo "  parsing catalog for ${os}-${arch}…" >&2
  if ! parse_catalog_file "$catalog_file" "$os" "$arch"; then
    rm -f "$catalog_file"
    return 1
  fi
  rm -f "$catalog_file"
}

add_to_path() {
  local bin_dir="$1"
  local root_dir
  root_dir="$(cd "$(dirname "$bin_dir")" && pwd)"
  local found_rc=false
  local rc_file
  echo "Adding FlutterPatch to your PATH"

  for rc_file in "$HOME/.bashrc" "$HOME/.zshrc"; do
    if [[ -e "$rc_file" ]]; then
      found_rc=true
      if grep -Fq "FLUTTERPATCH_ROOT=" "$rc_file" 2>/dev/null && grep -Fq "$bin_dir" "$rc_file" 2>/dev/null; then
        echo "Already present in $rc_file"
      elif grep -Fq "$bin_dir" "$rc_file" 2>/dev/null; then
        echo "Updating $rc_file (FLUTTERPATCH_ROOT)"
        printf '\n# FlutterPatch CLI install root\nexport FLUTTERPATCH_ROOT="%s"\n' "$root_dir" >>"$rc_file"
      else
        echo "Updating $rc_file"
        printf '\n# FlutterPatch CLI\nexport FLUTTERPATCH_ROOT="%s"\nexport PATH="%s:$PATH"\n' \
          "$root_dir" "$bin_dir" >>"$rc_file"
      fi
    fi
  done

  if [[ "$found_rc" != true ]]; then
    echo "Unable to determine shell type. Add FlutterPatch to your PATH manually:"
    echo "  export FLUTTERPATCH_ROOT=\"$root_dir\""
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
  local child
  child="$(find "$staging" -mindepth 1 -maxdepth 1 -type d | head -1 || true)"
  if [[ -n "$child" && -d "$child/bin" ]]; then
    printf '%s' "$child"
    return
  fi
  echo "Error: archive missing bin/ (expected flutterpatch/bin/...)" >&2
  return 1
}

# -------------------- main --------------------

OS="$(host_os)"
ARCH="$(host_arch)"
ROOT="$(install_dir)"
BIN_DIR="$ROOT/bin"
CLI_URL="${FLUTTERPATCH_CLI_URL:-}"

if [[ "$OS" == "windows" ]]; then
  echo "Error: use install.ps1 on Windows." >&2
  exit 1
fi

echo "FlutterPatch CLI installer"
echo "  target: $ROOT"
echo "  platform: ${OS}-${ARCH}"

if [[ -x "$BIN_DIR/flutterpatch" && "$FORCE" != true ]]; then
  echo "Install already present at $ROOT; skipping."
  echo "  Upgrade CLI:  ./scripts/install.sh --force"
  echo "  Flutter SDKs: flutterpatch flutter install|use <version>"
  exit 0
fi

if [[ "$FORCE" == true && -d "$ROOT" ]]; then
  echo "Reinstalling CLI (--force); keeping Flutter cache if present…"
  TMP_KEEP="$(mktemp -d "${TMPDIR:-/tmp}/flutterpatch-keep.XXXXXX")"
  if [[ -d "$ROOT/bin/cache/flutter" ]]; then
    mv "$ROOT/bin/cache/flutter" "$TMP_KEEP/flutter" || true
  fi
  rm -rf "$ROOT"
  mkdir -p "$ROOT/bin/cache"
  if [[ -d "$TMP_KEEP/flutter" ]]; then
    mv "$TMP_KEEP/flutter" "$ROOT/bin/cache/flutter"
  fi
  rm -rf "$TMP_KEEP"
fi

mkdir -p "$ROOT"

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/flutterpatch-install.XXXXXX")"
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

ARCHIVE_PATH=""
RESOLVED_VERSION=""
RESOLVED_SHA=""

if [[ -n "$CLI_URL" ]]; then
  case "$CLI_URL" in
    *.zip) ARCHIVE_PATH="$WORKDIR/cli.zip" ;;
    *) ARCHIVE_PATH="$WORKDIR/cli.tar.gz" ;;
  esac
  echo "Downloading $CLI_URL …"
  warn_if_proxy_set
  curl_fp -fL --connect-timeout 15 --max-time 600 --progress-bar -o "$ARCHIVE_PATH" "$CLI_URL"
else
  echo "Resolving latest package from download catalog…"
  IFS=$'\t' read -r url resolved_version resolved_sha resolved_name < <(resolve_from_catalog "$OS" "$ARCH")
  if [[ -z "${url:-}" ]]; then
    echo "Error: catalog resolve returned an empty download URL" >&2
    exit 1
  fi
  RESOLVED_VERSION="$resolved_version"
  RESOLVED_SHA="$resolved_sha"
  case "${resolved_name:-$url}" in
    *.zip) ARCHIVE_PATH="$WORKDIR/cli.zip" ;;
    *) ARCHIVE_PATH="$WORKDIR/cli.tar.gz" ;;
  esac
  echo "Downloading FlutterPatch CLI ${RESOLVED_VERSION:-} (${OS}-${ARCH})…"
  warn_if_proxy_set
  curl_fp -fL --connect-timeout 15 --max-time 600 --progress-bar -o "$ARCHIVE_PATH" "$url"
  verify_sha256 "$ARCHIVE_PATH" "$RESOLVED_SHA"
fi

STAGE="$WORKDIR/stage"
mkdir -p "$STAGE"
extract_archive "$ARCHIVE_PATH" "$STAGE"
SRC="$(normalize_extract_tree "$STAGE")"

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

RELOAD_REQUIRED=false
case ":$PATH:" in
  *:"$BIN_DIR":*) ;;
  *)
    RELOAD_REQUIRED=true
    add_to_path "$BIN_DIR" >&2
    ;;
esac

echo ""
echo "FlutterPatch CLI has been installed to $ROOT"
if [[ -n "$RESOLVED_VERSION" ]]; then
  echo "  version: $RESOLVED_VERSION"
fi

if "$BIN_DIR/flutterpatch" --help >/dev/null 2>&1; then
  echo "  binary: ok"
fi

if [[ "$RELOAD_REQUIRED" == true ]]; then
  cat <<EOF

Close and reopen your terminal to start using FlutterPatch, or run:

  export FLUTTERPATCH_ROOT="$ROOT"
  export PATH="$BIN_DIR:\$PATH"

Then:

  flutterpatch flutter use <version>   # install + set default Flutter SDK
  flutterpatch doctor
  export FLUTTERPATCH_TOKEN=<dashboard token>
  cd <your-flutter-app> && flutterpatch init
EOF
else
  cat <<EOF

Next:

  flutterpatch flutter use <version>   # install + set default Flutter SDK
  flutterpatch doctor
  export FLUTTERPATCH_TOKEN=<dashboard token>
  cd <your-flutter-app> && flutterpatch init
EOF
fi
