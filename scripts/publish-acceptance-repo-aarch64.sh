#!/usr/bin/env bash
# Uploads the flat aarch64 acceptance repo to a Nexus raw (or similar) repository.
#
# Required env:
#   MDV_NEXUS_USER / MDV_NEXUS_PASSWORD  — or MDV_NEXUS_AUTH=user:pass
# Optional:
#   MDV_NEXUS_BASE — default http://www.lixw.site:18081/repository/modiverse-secra-time
#   MDV_ACCEPTANCE_REPO_ROOT — default runtime/acceptance-repo/aarch64
#
# Example:
#   MDV_NEXUS_USER=admin MDV_NEXUS_PASSWORD=*** scripts/publish-acceptance-repo-aarch64.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FLAT_ROOT="${MDV_ACCEPTANCE_REPO_ROOT:-$REPO_ROOT/runtime/acceptance-repo/aarch64}"
NEXUS_BASE="${MDV_NEXUS_BASE:-http://www.lixw.site:18081/repository/modiverse-secra-time}"
NEXUS_BASE="${NEXUS_BASE%/}"

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

if [[ -n "${MDV_NEXUS_AUTH:-}" ]]; then
  AUTH="$MDV_NEXUS_AUTH"
elif [[ -n "${MDV_NEXUS_USER:-}" && -n "${MDV_NEXUS_PASSWORD:-}" ]]; then
  AUTH="${MDV_NEXUS_USER}:${MDV_NEXUS_PASSWORD}"
else
  die "set MDV_NEXUS_AUTH or MDV_NEXUS_USER+MDV_NEXUS_PASSWORD"
fi

[[ -d "$FLAT_ROOT" ]] || die "missing flat repo: $FLAT_ROOT (run make-acceptance-artifacts-aarch64.sh)"

uploaded=0
while IFS= read -r -d '' file; do
  rel="${file#"$FLAT_ROOT"/}"
  url="$NEXUS_BASE/$rel"
  printf 'PUT %s\n' "$url"
  curl -fsS -u "$AUTH" --upload-file "$file" "$url" >/dev/null
  uploaded=$((uploaded + 1))
done < <(find "$FLAT_ROOT" -type f \( -name '*.tar.gz' -o -name '*.sha256' \) -print0 | sort -z)

printf 'uploaded %s files to %s\n' "$uploaded" "$NEXUS_BASE"
printf 'Acceptance baseURL: %s\n' "$NEXUS_BASE"
printf 'Next: run apps/installer/scripts/debian12-aarch64-p1-acceptance.sh on a Debian 12 aarch64 host.\n'
