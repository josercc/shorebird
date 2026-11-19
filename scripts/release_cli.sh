#!/usr/bin/env bash
# Bump FlutterPatch CLI version, regenerate version.dart, commit, tag, push.
#
# Triggers GitHub Action package_cli on push of tag cli-v*.
#
# Usage:
#   ./scripts/release_cli.sh 1.18.4
#   ./scripts/release_cli.sh cli-v1.18.4
#   ./scripts/release_cli.sh 1.18.4 --dry-run
#   ./scripts/release_cli.sh 1.18.4 --all
#   ./scripts/release_cli.sh 1.18.4 --no-push
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# Prefer project FVM Flutter/Dart (.fvmrc → 3.47.2 / Dart 3.13+).
# Global fvm default (e.g. 3.41.9 / Dart 3.11) cannot resolve deps like
# very_good_analysis ^10.3.0 / cli_completion ^0.6.0.
if [[ -x "$ROOT/.fvm/flutter_sdk/bin/dart" ]]; then
  export PATH="$ROOT/.fvm/flutter_sdk/bin:$PATH"
fi

PUBSPEC="packages/shorebird_cli/pubspec.yaml"
VERSION_DART="packages/shorebird_cli/lib/src/version.dart"

DRY_RUN=false
PUSH=true
COMMIT_ALL=false
VERSION_ARG=""

usage() {
  cat <<'USAGE'
Release FlutterPatch CLI (bump + generate + commit + tag + push)

Usage:
  ./scripts/release_cli.sh <version> [options]

Arguments:
  <version>     Semver, with or without cli-v prefix (e.g. 1.18.4 or cli-v1.18.4)

Options:
  --dry-run     Print actions only; do not write/commit/tag/push
  --all         Commit all CLI/package tracked + common untracked release files
  --no-push     Commit and tag locally; do not push
  -h, --help    Show this help
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    --all) COMMIT_ALL=true; shift ;;
    --no-push) PUSH=false; shift ;;
    -h|--help) usage; exit 0 ;;
    -*)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
    *)
      if [[ -n "$VERSION_ARG" ]]; then
        echo "Unexpected argument: $1" >&2
        usage >&2
        exit 1
      fi
      VERSION_ARG="$1"
      shift
      ;;
  esac
done

if [[ -z "$VERSION_ARG" ]]; then
  echo "Error: version required" >&2
  usage >&2
  exit 1
fi

VERSION="${VERSION_ARG#cli-v}"
VERSION="${VERSION#v}"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]]; then
  echo "Error: invalid semver: $VERSION_ARG (got $VERSION)" >&2
  exit 1
fi
TAG="cli-v${VERSION}"

if [[ ! -f "$PUBSPEC" ]]; then
  echo "Error: missing $PUBSPEC" >&2
  exit 1
fi

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Error: required command not found: $1" >&2
    exit 1
  fi
}
need_cmd git
need_cmd dart
need_cmd python3

CURRENT="$(grep -E '^version:' "$PUBSPEC" | head -1 | awk '{print $2}')"
BRANCH="$(git rev-parse --abbrev-ref HEAD)"
REMOTE="$(git remote | head -1)"
REMOTE="${REMOTE:-origin}"

if [[ "$COMMIT_ALL" == true ]]; then
  COMMIT_MODE="all CLI dirty"
else
  COMMIT_MODE="version + release scripts"
fi

echo "==> Release FlutterPatch CLI"
echo "    current:  ${CURRENT}"
echo "    next:     ${VERSION}"
echo "    tag:      ${TAG}"
echo "    branch:   ${BRANCH}"
echo "    remote:   ${REMOTE}"
echo "    dry-run:  ${DRY_RUN}"
echo "    push:     ${PUSH}"
echo "    commit:   ${COMMIT_MODE}"

if git rev-parse "$TAG" >/dev/null 2>&1; then
  echo "Error: tag already exists locally: $TAG" >&2
  exit 1
fi
if git ls-remote --tags "$REMOTE" "refs/tags/${TAG}" 2>/dev/null | grep -q .; then
  echo "Error: tag already exists on ${REMOTE}: $TAG" >&2
  exit 1
fi

if [[ "$CURRENT" == "$VERSION" ]]; then
  echo "Warn: pubspec already at ${VERSION}; will regenerate version.dart and tag" >&2
fi

run() {
  if [[ "$DRY_RUN" == true ]]; then
    printf '    [dry-run]'
    printf ' %q' "$@"
    printf '\n'
  else
    "$@"
  fi
}

echo "==> bump pubspec.yaml → ${VERSION}"
if [[ "$DRY_RUN" == true ]]; then
  echo "    [dry-run] set version: ${VERSION} in ${PUBSPEC}"
else
  python3 -c '
import sys
from pathlib import Path
path = Path(sys.argv[1])
version = sys.argv[2]
lines = path.read_text().splitlines(keepends=True)
out = []
replaced = False
for line in lines:
    if line.startswith("version:") and not replaced:
        out.append(f"version: {version}\n")
        replaced = True
    else:
        out.append(line)
if not replaced:
    raise SystemExit(f"version: line not found in {path}")
path.write_text("".join(out))
print(f"    wrote {path}")
' "$PUBSPEC" "$VERSION"
fi

echo "==> build_runner (sync version.dart)"
echo "    dart: $(command -v dart) ($(dart --version 2>&1 | head -1))"
if [[ "$DRY_RUN" == true ]]; then
  echo "    [dry-run] (cd packages/shorebird_cli && dart run build_runner build)"
else
  (cd packages/shorebird_cli && dart run build_runner build)
  if ! grep -q "packageVersion = '${VERSION}'" "$VERSION_DART"; then
    echo "Error: ${VERSION_DART} does not contain packageVersion = '${VERSION}'" >&2
    cat "$VERSION_DART" >&2
    exit 1
  fi
  echo "    ok: $(tr -d '\n' < "$VERSION_DART")"
fi

echo "==> git commit"
run git add "$PUBSPEC" "$VERSION_DART"
for f in scripts/package_cli.sh scripts/install_local_cli.sh scripts/release_cli.sh; do
  if [[ -e "$f" ]]; then
    run git add "$f"
  fi
done
if [[ "$COMMIT_ALL" == true ]]; then
  run git add -u
  run git add packages/shorebird_cli packages/shorebird_code_push_client scripts || true
fi

MSG="chore(shorebird_cli): release ${VERSION}

Sync pubspec + generated version.dart for CLI package_cli tag ${TAG}."

if [[ "$DRY_RUN" == true ]]; then
  echo "    [dry-run] git commit"
  echo "$MSG" | sed 's/^/      | /'
else
  if git diff --cached --quiet; then
    echo "Error: nothing staged to commit (already released?)" >&2
    exit 1
  fi
  git commit -m "$MSG"
fi

echo "==> create tag ${TAG}"
run git tag -a "$TAG" -m "FlutterPatch CLI ${VERSION}"

if [[ "$PUSH" == true ]]; then
  echo "==> push ${BRANCH} + ${TAG} → ${REMOTE}"
  run git push "$REMOTE" "HEAD:${BRANCH}"
  run git push "$REMOTE" "$TAG"
  echo "==> Done. GitHub Action package_cli should build tag ${TAG}."
  echo "    https://github.com/josercc/shorebird/actions"
else
  echo "==> Done locally (not pushed). Push when ready:"
  echo "    git push ${REMOTE} HEAD:${BRANCH}"
  echo "    git push ${REMOTE} ${TAG}"
fi
