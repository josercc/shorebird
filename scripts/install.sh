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
#   FLUTTERPATCH_CURL_USE_PROXY       set to 1 to honor http(s)_proxy for CLI
#                                     downloads (default: bypass; Clash/V2Ray
#                                     often leave keep-alive open → curl 28)
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

# Local Clash/V2Ray proxies (http_proxy=127.0.0.1:7890) often proxy the Appwrite
# response then keep the socket open without Content-Length → curl hangs until
# --max-time and exits 28 even after the full body arrived. Bypass proxy unless
# the user explicitly opts in.
# Run curl with default proxy bypass for FlutterPatch download hosts.
# Usage: curl_fp [curl args...]
curl_fp() {
  if [[ "${FLUTTERPATCH_CURL_USE_PROXY:-}" == "1" ]]; then
    curl "$@"
    return $?
  fi
  # --proxy "" disables env http(s)_proxy for this request.
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

# Run a command with a wall-clock timeout (macOS has no GNU timeout by default).
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

# macOS /usr/bin/python3 is often a CLT stub that hangs on a GUI prompt.
python3_is_usable() {
  command -v python3 >/dev/null 2>&1 || return 1
  run_with_timeout 5 python3 -c 'print("ok")' >/dev/null 2>&1
}

# Parse catalog JSON file → print: url\tversion\tsha256\tfilename
# Prefer jq, then macOS JXA (no CLT/python), then a real python3.
parse_catalog_file() {
  local catalog_file="$1" os_name="$2" arch="$3" want_version="$4"

  if command -v jq >/dev/null 2>&1; then
    jq -r --arg os "$os_name" --arg arch "$arch" --arg want "$want_version" '
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
              and (
                $want == ""
                or (((.version // "") | ltrimstr("v") | ltrimstr("V"))
                    == ($want | ltrimstr("v") | ltrimstr("V")))
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

  # macOS ships osascript/JXA; avoids /usr/bin/python3 CLT stub hangs on Intel Macs.
  if [[ "$(uname -s)" == "Darwin" ]] && command -v osascript >/dev/null 2>&1; then
    CATALOG_FILE="$catalog_file" OS_NAME="$os_name" ARCH_NAME="$arch" WANT_VERSION="$want_version" \
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
const want = env('WANT_VERSION');
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
const wantN = String(want || '').replace(/^[vV]/, '');
let candidates = (data.cli || []).filter(function (r) {
  const p = String(r.platform || '').toLowerCase();
  const a = String(r.arch || '').toLowerCase();
  if (p !== osName || !archSet[a]) return false;
  if (!wantN) return true;
  return String(r.version || '').replace(/^[vV]/, '') === wantN;
});
if (!candidates.length) {
  throw new Error('no CLI package for ' + osName + '-' + arch + (want ? (' version ' + want) : ''));
}
candidates.sort(function (a, b) { return verCmp(b.version, a.version); });
const row = candidates[0];
const url = String(row.download_url || '').trim();
if (!url) throw new Error('catalog row missing download_url');
// Final expression is written to stdout by osascript (console.log goes to stderr).
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
    python3 - "$catalog_file" "$os_name" "$arch" "$want_version" <<'PY'
import json, sys

path, os_name, arch, want = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
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
    return $?
  fi

  echo "Error: cannot parse download catalog (need jq, or macOS osascript, or a working python3)." >&2
  echo "  macOS tip: /usr/bin/python3 may hang waiting for Xcode CLT — use:" >&2
  echo "    xcode-select --install   # or: brew install python jq" >&2
  echo "  Or skip catalog: ./install_cli.sh --url <archive-url>" >&2
  return 1
}

# True if file looks like a usable Appwrite / catalog JSON payload.
catalog_file_usable() {
  local f="$1"
  [[ -s "$f" ]] || return 1
  # Minimal structural check — full parse happens later.
  grep -q '"cli"' "$f" 2>/dev/null || return 1
  grep -qE '"ok"[[:space:]]*:[[:space:]]*true|"responseBody"' "$f" 2>/dev/null
}

# Resolve catalog → print: url\tversion\tsha256\tfilename
resolve_from_catalog() {
  local os="$1" arch="$2" want_version="$3"
  local endpoint project payload catalog_file curl_rc=0
  local attempt=1 max_attempts=3
  endpoint="$(downloads_endpoint)"
  project="$(downloads_project)"
  if [[ -z "$endpoint" || -z "$project" ]]; then
    echo "Error: set FLUTTERPATCH_DOWNLOADS_ENDPOINT and FLUTTERPATCH_DOWNLOADS_PROJECT_ID, or pass --url / --archive." >&2
    return 1
  fi

  catalog_file="$(mktemp "${TMPDIR:-/tmp}/flutterpatch-catalog.XXXXXX")"

  payload='{"action":"list_cli"}'
  echo "  fetching catalog from $endpoint …" >&2
  warn_if_proxy_set
  # Some Appwrite / local-proxy paths deliver the full body then leave the
  # socket open (curl exit 28 with N bytes received). Prefer Connection: close
  # and bypass http_proxy by default. Accept a usable JSON body even if curl
  # later times out (exit 28).
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
      echo "  Often caused by http_proxy (e.g. 127.0.0.1:7890) holding the connection open." >&2
      echo "  Retry without proxy:" >&2
      echo "    env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY \\" >&2
      echo "      curl --connect-timeout 10 --max-time 30 -o /tmp/fp-catalog.json \\" >&2
      echo "      -H 'Content-Type: application/json' -H 'X-Appwrite-Project: $project' \\" >&2
      echo "      -d '{\"action\":\"list_cli\"}' '$endpoint'" >&2
      echo "  Or: NO_PROXY='*' ./install_cli.sh --force" >&2
      echo "  Or: ./install_cli.sh --url <archive-url> / --archive /path/to.tgz" >&2
      return 1
    fi
    sleep $((attempt * 2))
    attempt=$((attempt + 1))
  done

  echo "  parsing catalog for ${os}-${arch}…" >&2
  if ! parse_catalog_file "$catalog_file" "$os" "$arch" "$want_version"; then
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
        # Older installs only exported PATH; pin the install root too.
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
    # Always keep Flutter cache across CLI reinstalls (--force / upgrade).
    # --skip-flutter only skips init/bootstrap, not cache preservation.
    TMP_KEEP="$(mktemp -d "${TMPDIR:-/tmp}/flutterpatch-keep.XXXXXX")"
    if [[ -d "$ROOT/bin/cache/flutter" ]]; then
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
    warn_if_proxy_set
    curl_fp -fL --connect-timeout 15 --max-time 600 --progress-bar -o "$ARCHIVE_PATH" "$CLI_URL"
  else
    echo "Resolving latest package from download catalog…"
    IFS=$'\t' read -r url resolved_version resolved_sha resolved_name < <(resolve_from_catalog "$OS" "$ARCH" "$VERSION")
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

  export FLUTTERPATCH_ROOT="$ROOT"
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
