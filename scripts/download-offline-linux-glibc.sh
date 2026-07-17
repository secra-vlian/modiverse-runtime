#!/usr/bin/env bash
# Download Modiverse offline runtime components for portable glibc platforms.
#
# Platforms (best cross-distro compatibility; uname -m + glibc):
#   linux-x86_64-glibc
#   linux-aarch64-glibc
#
# Prefers official prebuilt binaries that target older glibc (≈2.28+) where
# available. Distro-specific .deb/.rpm are intentionally omitted.
# Infra without portable binaries (nginx / postgresql / redis / zeromq) keep
# upstream source tarballs for the build farm → runtime package pipeline.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

ARCHES=("x86_64" "aarch64")
if [[ "${1:-}" == "x86_64" || "${1:-}" == "aarch64" ]]; then
  ARCHES=("$1")
fi

BASE_URL="${MDV_REPO_PUBLIC_BASE:-http://www.lixw.site:18081/repository/modiverse-secra-time/platforms}"

download() {
  local url="$1"
  local out="$2"
  echo "==> $(basename "$out")"
  if [[ -f "$out" && -s "$out" ]]; then
    echo "    skip ($(du -h "$out" | awk '{print $1}'))"
    return 0
  fi
  mkdir -p "$(dirname "$out")"
  rm -f "$out.partial"
  # Use a browser-like UA — some CDNs (nginx.org / postgresql.org) 403 bare curl.
  local ua="Mozilla/5.0 (compatible; ModiverseRepoFetcher/1.0)"
  if command -v curl >/dev/null 2>&1; then
    curl -fL --retry 3 --retry-delay 2 -A "$ua" -o "$out.partial" "$url"
  elif command -v wget >/dev/null 2>&1; then
    wget --user-agent="$ua" -O "$out.partial" "$url"
  else
    echo "need curl or wget" >&2
    return 1
  fi
  if [[ ! -s "$out.partial" ]]; then
    rm -f "$out.partial"
    echo "download failed (empty): $url" >&2
    return 1
  fi
  mv "$out.partial" "$out"
  echo "    ok ($(du -h "$out" | awk '{print $1}'))"
}

# Reuse only when the candidate is known same-arch / arch-agnostic.
reuse_or_download() {
  local url="$1"
  local out="$2"
  shift 2
  local candidate
  if [[ -f "$out" && -s "$out" ]]; then
    echo "==> $(basename "$out")"
    echo "    skip ($(du -h "$out" | awk '{print $1}'))"
    return 0
  fi
  for candidate in "$@"; do
    if [[ -f "$candidate" && -s "$candidate" ]]; then
      mkdir -p "$(dirname "$out")"
      echo "==> $(basename "$out") (reuse $(basename "$candidate"))"
      cp -f "$candidate" "$out"
      echo "    ok ($(du -h "$out" | awk '{print $1}'))"
      return 0
    fi
  done
  download "$url" "$out"
}

download_arch() {
  local arch="$1"
  local platform="linux-${arch}-glibc"
  local root="$REPO_ROOT/modiverse-repository/${platform}"
  local legacy="$REPO_ROOT/modiverse-repository/debian-12-amd64"

  # Map vendor archive naming.
  local go_arch ffmpeg_label oo_arch lo_url lo_version lo_filename
  case "$arch" in
    x86_64)
      go_arch="amd64"
      ffmpeg_label="linux64"
      oo_arch="amd64"
      # 7.4.7 has no aarch64 builds; keep for x86_64 until both arches align on 25.8+.
      lo_version="7.4.7.2"
      lo_filename="libreoffice-7.4.7.tar.gz"
      lo_url="https://downloadarchive.documentfoundation.org/libreoffice/old/7.4.7.2/deb/x86_64/LibreOffice_7.4.7.2_Linux_x86-64_deb.tar.gz"
      ;;
    aarch64)
      go_arch="arm64"
      ffmpeg_label="linuxarm64"
      oo_arch="arm64"
      lo_version="25.8.7"
      lo_filename="libreoffice-25.8.7.tar.gz"
      lo_url="https://download.documentfoundation.org/libreoffice/stable/25.8.7/deb/aarch64/LibreOffice_25.8.7_Linux_aarch64_deb.tar.gz"
      ;;
    *)
      echo "unsupported arch: $arch" >&2
      return 1
      ;;
  esac

  mkdir -p "$root"/{source/{nginx,redis,zeromq,poppler,postgresql},binary/{tusd,opentelemetry,openobserve,ffmpeg,libreoffice,fonts},meta}

  echo
  echo "======== $platform ========"
  echo "Repository: $root"

  #######################################
  # Sources (build farm → runtime; arch-agnostic content)
  #######################################

  echo "== Source packages (self-build runtime) =="
  # nginx.org source mirror via GitHub release-compatible tarball layout differs;
  # prefer official download with browser UA (see download()).
  reuse_or_download \
    "https://nginx.org/download/nginx-1.26.3.tar.gz" \
    "$root/source/nginx/nginx-1.26.3.tar.gz" \
    "$REPO_ROOT/modiverse-repository/linux-x86_64-glibc/source/nginx/nginx-1.26.3.tar.gz" \
    "$REPO_ROOT/modiverse-repository/linux-aarch64-glibc/source/nginx/nginx-1.26.3.tar.gz"

  reuse_or_download \
    "https://ftp.postgresql.org/pub/source/v17.10/postgresql-17.10.tar.bz2" \
    "$root/source/postgresql/postgresql-17.10.tar.bz2" \
    "$REPO_ROOT/modiverse-repository/linux-x86_64-glibc/source/postgresql/postgresql-17.10.tar.bz2" \
    "$REPO_ROOT/modiverse-repository/linux-aarch64-glibc/source/postgresql/postgresql-17.10.tar.bz2"

  reuse_or_download \
    "https://download.redis.io/releases/redis-8.0.0.tar.gz" \
    "$root/source/redis/redis-8.0.0.tar.gz" \
    "$legacy/source/redis/redis-8.0.0.tar.gz"

  reuse_or_download \
    "https://github.com/zeromq/libzmq/releases/download/v4.3.5/zeromq-4.3.5.tar.gz" \
    "$root/source/zeromq/zeromq-4.3.5.tar.gz" \
    "$legacy/source/zeromq/zeromq-4.3.5.tar.gz"

  reuse_or_download \
    "https://poppler.freedesktop.org/poppler-22.12.0.tar.xz" \
    "$root/source/poppler/poppler-22.12.0.tar.xz" \
    "$legacy/source/poppler/poppler-22.12.0.tar.xz"

  #######################################
  # Portable prebuilt binaries (prefer glibc≈2.28 targets)
  # Only reuse debian-12-amd64 artifacts when filling x86_64 (same arch).
  #######################################

  echo "== Prebuilt binaries ($arch) =="

  local -a reuse_tusd=() reuse_otel_contrib=() reuse_otel=() reuse_oo=() reuse_ffmpeg=() reuse_lo=()
  if [[ "$arch" == "x86_64" ]]; then
    reuse_tusd=("$legacy/binary/tusd/tusd_v2.9.2.tar.gz")
    reuse_otel_contrib=("$legacy/binary/opentelemetry/otelcol-contrib.tar.gz")
    reuse_otel=("$legacy/binary/opentelemetry/otelcol.tar.gz")
    reuse_oo=("$legacy/binary/openobserve/openobserve-v0.91.0-linux-amd64.tar.gz")
    reuse_ffmpeg=("$legacy/binary/ffmpeg/ffmpeg.tar.xz")
    reuse_lo=("$legacy/binary/libreoffice/libreoffice-7.4.7.tar.gz")
  fi

  # ${arr[@]+"${arr[@]}"} avoids unbound-variable under `set -u` when empty.
  reuse_or_download \
    "https://github.com/tus/tusd/releases/download/v2.9.2/tusd_linux_${go_arch}.tar.gz" \
    "$root/binary/tusd/tusd_v2.9.2.tar.gz" \
    ${reuse_tusd[@]+"${reuse_tusd[@]}"}

  reuse_or_download \
    "https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v0.155.0/otelcol-contrib_0.155.0_linux_${go_arch}.tar.gz" \
    "$root/binary/opentelemetry/otelcol-contrib.tar.gz" \
    ${reuse_otel_contrib[@]+"${reuse_otel_contrib[@]}"}

  reuse_or_download \
    "https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v0.155.0/otelcol_0.155.0_linux_${go_arch}.tar.gz" \
    "$root/binary/opentelemetry/otelcol.tar.gz" \
    ${reuse_otel[@]+"${reuse_otel[@]}"}

  reuse_or_download \
    "https://downloads.openobserve.ai/releases/openobserve/v0.91.0/openobserve-v0.91.0-linux-${oo_arch}.tar.gz" \
    "$root/binary/openobserve/openobserve-v0.91.0-linux-${oo_arch}.tar.gz" \
    ${reuse_oo[@]+"${reuse_oo[@]}"}

  # BtbN static builds target RHEL/CentOS 8 (glibc 2.28) — widest glibc portability.
  reuse_or_download \
    "https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-n8.1-latest-${ffmpeg_label}-gpl-8.1.tar.xz" \
    "$root/binary/ffmpeg/ffmpeg.tar.xz" \
    ${reuse_ffmpeg[@]+"${reuse_ffmpeg[@]}"}

  reuse_or_download \
    "$lo_url" \
    "$root/binary/libreoffice/${lo_filename}" \
    ${reuse_lo[@]+"${reuse_lo[@]}"}

  # Arch-independent font debs (safe on both platforms; not a system dpkg install).
  reuse_or_download \
    "http://ftp.debian.org/debian/pool/main/f/fonts-wqy-zenhei/fonts-wqy-zenhei_0.9.45-8_all.deb" \
    "$root/binary/fonts/fonts-wqy-zenhei_0.9.45-8_all.deb" \
    "$legacy/deb/fonts/fonts-wqy-zenhei_0.9.45-8_all.deb"

  reuse_or_download \
    "http://ftp.debian.org/debian/pool/main/f/fonts-wqy-microhei/fonts-wqy-microhei_0.2.0-beta-3.1_all.deb" \
    "$root/binary/fonts/fonts-wqy-microhei_0.2.0-beta-3.1_all.deb" \
    "$legacy/deb/fonts/fonts-wqy-microhei_0.2.0-beta-3.1_all.deb"

  #######################################
  # Manifest + index
  #######################################

  cat >"$root/meta/manifest.yaml" <<EOF
platform:
  os: linux
  libc: glibc
  arch: ${arch}
  id: ${platform}
  notes: >
    Portable glibc baseline (prefer builds linked against glibc ≥2.28).
    Prefer packageType=binary; source packages feed the build farm.

packages:
  nginx:
    version: 1.26.3
    packageType: source
  postgresql:
    version: 17.10
    packageType: source
  redis:
    version: 8.0.0
    packageType: source
  zeromq:
    version: 4.3.5
    packageType: source
  poppler:
    version: 22.12.0
    packageType: source
  tusd:
    version: 2.9.2
    packageType: binary
  opentelemetry:
    contrib: 0.155.0
    packageType: binary
  openobserve:
    version: 0.91.0
    packageType: binary
  ffmpeg:
    version: 8.1
    packageType: binary
    baseline: glibc-2.28
  libreoffice:
    version: ${lo_version}
    packageType: binary
EOF

  cat >"$root/meta/versions.env" <<EOF
PLATFORM=${platform}
ARCH=${arch}
NGINX_VERSION=1.26.3
POSTGRESQL_VERSION=17.10
REDIS_VERSION=8.0.0
ZEROMQ_VERSION=4.3.5
TUSD_VERSION=2.9.2
OTEL_VERSION=0.155.0
OPENOBSERVE_VERSION=0.91.0
FFMPEG_VERSION=8.1
LIBREOFFICE_VERSION=${lo_version}
POPPLER_VERSION=22.12.0
EOF

  echo "== Rebuild index =="
  MDV_REPO_PUBLIC_BASE="$BASE_URL" \
    "$REPO_ROOT/scripts/rebuild-modiverse-repository-index.sh" "$platform"

  echo
  echo "Finished: $platform"
  find "$root" -type f ! -name '.DS_Store' | sort
  du -sh "$root"
}

for arch in "${ARCHES[@]}"; do
  download_arch "$arch"
done

echo
echo "================================="
echo "All requested platforms finished"
echo "Run: scripts/rebuild-modiverse-repository-index.sh <platform>"
echo "================================="
