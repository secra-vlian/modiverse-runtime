#!/usr/bin/env bash
# Rebuild meta/SHA256SUMS + meta/index.json for a modiverse-repository platform.
# Usage:
#   scripts/rebuild-modiverse-repository-index.sh linux-x86_64-glibc
#   scripts/rebuild-modiverse-repository-index.sh linux-aarch64-glibc
#   scripts/rebuild-modiverse-repository-index.sh   # all known platforms

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BASE_URL="${MDV_REPO_PUBLIC_BASE:-http://www.lixw.site:18081/repository/modiverse-runtime/platforms}"

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

# name|version|kind|packageType|relpath
declare -a PACKAGE_DEFS=(
  "nginx|1.26.3|infra|source|source/nginx/nginx-1.26.3.tar.gz"
  "postgresql|17.10|infra|source|source/postgresql/postgresql-17.10.tar.bz2"
  "redis|8.0.0|infra|source|source/redis/redis-8.0.0.tar.gz"
  "zeromq|4.3.5|infra|source|source/zeromq/zeromq-4.3.5.tar.gz"
  "poppler|22.12.0|tools|source|source/poppler/poppler-22.12.0.tar.xz"
  "tusd|2.9.2|infra|binary|binary/tusd/tusd_v2.9.2.tar.gz"
  "otelcol-contrib|0.155.0|observability|binary|binary/opentelemetry/otelcol-contrib.tar.gz"
  "otelcol|0.155.0|observability|binary|binary/opentelemetry/otelcol.tar.gz"
  "ffmpeg|8.1|tools|binary|binary/ffmpeg/ffmpeg.tar.xz"
  "fonts-wqy-zenhei|0.9.45-8|fonts|binary|binary/fonts/fonts-wqy-zenhei_0.9.45-8_all.deb"
  "fonts-wqy-microhei|0.2.0-beta-3.1|fonts|binary|binary/fonts/fonts-wqy-microhei_0.2.0-beta-3.1_all.deb"
)

openobserve_path() {
  local arch="$1"
  case "$arch" in
    x86_64) echo "binary/openobserve/openobserve-v0.91.0-linux-amd64.tar.gz" ;;
    aarch64) echo "binary/openobserve/openobserve-v0.91.0-linux-arm64.tar.gz" ;;
    *) return 1 ;;
  esac
}

libreoffice_meta() {
  local arch="$1"
  case "$arch" in
    x86_64) echo "7.4.7.2|binary/libreoffice/libreoffice-7.4.7.tar.gz" ;;
    aarch64) echo "25.8.7|binary/libreoffice/libreoffice-25.8.7.tar.gz" ;;
    *) return 1 ;;
  esac
}

rebuild_one() {
  local platform="$1"
  local root="$REPO_ROOT/modiverse-repository/$platform"
  if [[ ! -d "$root" ]]; then
    echo "skip missing platform dir: $root" >&2
    return 1
  fi

  local arch
  case "$platform" in
    linux-x86_64-glibc) arch=x86_64 ;;
    linux-aarch64-glibc) arch=aarch64 ;;
    debian-12-amd64) arch=amd64 ;;
    *)
      arch="${platform##*-}"
      ;;
  esac

  mkdir -p "$root/meta"
  local sums="$root/meta/SHA256SUMS"
  : >"$sums"

  local tmp
  tmp="$(mktemp)"
  local first=1

  emit_pkg() {
    local name="$1" version="$2" kind="$3" ptype="$4" rel="$5"
    local abs="$root/$rel"
    if [[ ! -f "$abs" ]]; then
      echo "  warn: missing $rel" >&2
      return 0
    fi
    local digest size filename
    digest="$(sha256_file "$abs")"
    size="$(wc -c <"$abs" | tr -d ' ')"
    filename="$(basename "$rel")"
    printf "%s  %s\n" "$digest" "$rel" >>"$sums"

    if [[ $first -eq 0 ]]; then
      printf ',\n' >>"$tmp"
    fi
    first=0
    cat >>"$tmp" <<EOF
    {
      "name": "$name",
      "version": "$version",
      "kind": "$kind",
      "packageType": "$ptype",
      "os": "linux",
      "osVersion": "glibc",
      "arch": "$arch",
      "platform": "$platform",
      "path": "$rel",
      "filename": "$filename",
      "size": $size,
      "sha256": "$digest",
      "downloadUrl": "$BASE_URL/$platform/$rel"
    }
EOF
  }

  local def
  for def in "${PACKAGE_DEFS[@]}"; do
    IFS='|' read -r name version kind ptype rel <<<"$def"
    emit_pkg "$name" "$version" "$kind" "$ptype" "$rel"
  done

  local oo_rel
  if oo_rel="$(openobserve_path "$arch")"; then
    emit_pkg "openobserve" "0.91.0" "observability" "binary" "$oo_rel"
  fi
  local lo_meta lo_ver lo_rel
  if lo_meta="$(libreoffice_meta "$arch")"; then
    IFS='|' read -r lo_ver lo_rel <<<"$lo_meta"
    emit_pkg "libreoffice" "$lo_ver" "tools" "binary" "$lo_rel"
  fi

  cat >"$root/meta/index.json" <<EOF
{
  "schemaVersion": 1,
  "repository": "modiverse-runtime",
  "platform": {
    "os": "linux",
    "version": "glibc",
    "arch": "$arch",
    "id": "$platform"
  },
  "source": "modiverse-repository/$platform",
  "packages": [
$(cat "$tmp")
  ]
}
EOF
  rm -f "$tmp"
  echo "wrote $root/meta/index.json ($(wc -l <"$root/meta/index.json" | tr -d ' ') lines)"
}

PLATFORMS=("$@")
if [[ ${#PLATFORMS[@]} -eq 0 ]]; then
  PLATFORMS=(linux-x86_64-glibc linux-aarch64-glibc)
fi

rc=0
for p in "${PLATFORMS[@]}"; do
  rebuild_one "$p" || rc=1
done
exit "$rc"
