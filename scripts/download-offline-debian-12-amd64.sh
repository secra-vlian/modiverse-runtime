#!/usr/bin/env bash
# Download Modiverse offline component packages for Debian 12 amd64.
#
# DEPRECATED for new offline bundles: prefer portable glibc platforms via
#   scripts/download-offline-linux-glibc.sh   # linux-x86_64-glibc + linux-aarch64-glibc
# Prefer running on Debian 12 (or bookworm container). On macOS/host without apt,
# the script still downloads source/binary packages and known .deb URLs.

set -euo pipefail

ROOT="$(pwd)/modiverse-repository/debian-12-amd64"

mkdir -p "$ROOT"/{deb/nginx,deb/postgresql,deb/fonts,source/redis,source/zeromq,source/poppler,binary/tusd,binary/opentelemetry,binary/openobserve,binary/ffmpeg,binary/libreoffice,meta}

echo "Repository: $ROOT"

download() {
  local url="$1"
  local out="$2"
  echo "==> $(basename "$out")"
  if [[ -f "$out" && -s "$out" ]]; then
    echo "    skip ($(du -h "$out" | awk '{print $1}'))"
    return 0
  fi
  if command -v wget >/dev/null 2>&1; then
    wget -O "$out.partial" "$url" && mv "$out.partial" "$out"
  else
    curl -fL --retry 3 --retry-delay 2 -o "$out.partial" "$url" && mv "$out.partial" "$out"
  fi
  echo "    ok ($(du -h "$out" | awk '{print $1}'))"
}

HAVE_APT=0
if command -v apt >/dev/null 2>&1 && command -v apt-get >/dev/null 2>&1; then
  HAVE_APT=1
fi

#######################################
# 基础工具（仅 Debian/apt 环境）
#######################################

if [[ "$HAVE_APT" -eq 1 ]]; then
  apt update
  apt install -y \
      wget \
      curl \
      jq \
      gnupg \
      ca-certificates \
      apt-transport-https
fi

#######################################
# Nginx 1.26.3
#######################################

echo "== Download nginx 1.26.3 =="

if [[ "$HAVE_APT" -eq 1 ]]; then
  wget -qO- https://nginx.org/keys/nginx_signing.key \
   | gpg --dearmor \
   > /usr/share/keyrings/nginx-archive-keyring.gpg

  cat >/etc/apt/sources.list.d/nginx.list <<EOF
deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] http://nginx.org/packages/debian bookworm nginx
EOF

  apt update
  (
    cd "$ROOT/deb/nginx"
    apt download nginx=1.26.3-1~bookworm || true
  )
else
  download \
    "https://nginx.org/packages/debian/pool/nginx/n/nginx/nginx_1.26.3-1~bookworm_amd64.deb" \
    "$ROOT/deb/nginx/nginx_1.26.3-1~bookworm_amd64.deb"
fi

#######################################
# PostgreSQL 17
#######################################

echo "== Download PostgreSQL 17 =="

if [[ "$HAVE_APT" -eq 1 ]]; then
  wget -qO- https://www.postgresql.org/media/keys/ACCC4CF8.asc \
   | gpg --dearmor \
   > /usr/share/keyrings/postgresql.gpg

  cat >/etc/apt/sources.list.d/pgdg.list <<EOF
deb [signed-by=/usr/share/keyrings/postgresql.gpg] http://apt.postgresql.org/pub/repos/apt bookworm-pgdg main
EOF

  apt update
  (
    cd "$ROOT/deb/postgresql"
    # postgresql-contrib-17 is absorbed into postgresql-17 on current PGDG; keep attempt for compatibility.
    apt download \
      postgresql-17 \
      postgresql-client-17 \
      postgresql-contrib-17 || true
  )
else
  download \
    "https://apt.postgresql.org/pub/repos/apt/pool/main/p/postgresql-17/postgresql-17_17.10-1.pgdg12+1_amd64.deb" \
    "$ROOT/deb/postgresql/postgresql-17_17.10-1.pgdg12+1_amd64.deb"
  download \
    "https://apt.postgresql.org/pub/repos/apt/pool/main/p/postgresql-17/postgresql-client-17_17.10-1.pgdg12+1_amd64.deb" \
    "$ROOT/deb/postgresql/postgresql-client-17_17.10-1.pgdg12+1_amd64.deb"
fi

#######################################
# Redis 8 Source
#######################################

echo "== Download Redis 8 =="
download \
  "https://download.redis.io/releases/redis-8.0.0.tar.gz" \
  "$ROOT/source/redis/redis-8.0.0.tar.gz"

#######################################
# ZeroMQ 4.3.5
#######################################

echo "== Download ZeroMQ =="
download \
  "https://github.com/zeromq/libzmq/releases/download/v4.3.5/zeromq-4.3.5.tar.gz" \
  "$ROOT/source/zeromq/zeromq-4.3.5.tar.gz"

#######################################
# tusd 2.9.2
#######################################

echo "== Download tusd =="
download \
  "https://github.com/tus/tusd/releases/download/v2.9.2/tusd_linux_amd64.tar.gz" \
  "$ROOT/binary/tusd/tusd_v2.9.2.tar.gz"

#######################################
# OpenTelemetry Collector
#######################################

echo "== Download OpenTelemetry =="
download \
  "https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v0.155.0/otelcol-contrib_0.155.0_linux_amd64.tar.gz" \
  "$ROOT/binary/opentelemetry/otelcol-contrib.tar.gz"
download \
  "https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v0.155.0/otelcol_0.155.0_linux_amd64.tar.gz" \
  "$ROOT/binary/opentelemetry/otelcol.tar.gz"

#######################################
# OpenObserve
# GitHub assets for v0.91.0 were removed; official CDN hosts the binary tarball.
#######################################

echo "== Download OpenObserve =="
download \
  "https://downloads.openobserve.ai/releases/openobserve/v0.91.0/openobserve-v0.91.0-linux-amd64.tar.gz" \
  "$ROOT/binary/openobserve/openobserve-v0.91.0-linux-amd64.tar.gz"

#######################################
# FFmpeg 8.1 (BtbN static linux64 gpl)
# Original autobuild tag URL 404; pin to n8.1 latest channel matching manifest 8.1.x.
#######################################

echo "== Download FFmpeg =="
download \
  "https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-n8.1-latest-linux64-gpl-8.1.tar.xz" \
  "$ROOT/binary/ffmpeg/ffmpeg.tar.xz"

#######################################
# LibreOffice 7.4.7
# stable/ URL expired; use documentfoundation archive (7.4.7.2).
#######################################

echo "== Download LibreOffice =="
download \
  "https://downloadarchive.documentfoundation.org/libreoffice/old/7.4.7.2/deb/x86_64/LibreOffice_7.4.7.2_Linux_x86-64_deb.tar.gz" \
  "$ROOT/binary/libreoffice/libreoffice-7.4.7.tar.gz"

#######################################
# Poppler
#######################################

echo "== Download Poppler =="
download \
  "https://poppler.freedesktop.org/poppler-22.12.0.tar.xz" \
  "$ROOT/source/poppler/poppler-22.12.0.tar.xz"

#######################################
# Fonts
#######################################

echo "== Download Fonts =="

if [[ "$HAVE_APT" -eq 1 ]]; then
  (
    cd "$ROOT/deb/fonts"
    apt download \
      fontconfig \
      fonts-wqy-zenhei \
      fonts-wqy-microhei
  )
else
  download \
    "http://ftp.debian.org/debian/pool/main/f/fontconfig/fontconfig_2.14.1-4_amd64.deb" \
    "$ROOT/deb/fonts/fontconfig_2.14.1-4_amd64.deb"
  download \
    "http://ftp.debian.org/debian/pool/main/f/fonts-wqy-zenhei/fonts-wqy-zenhei_0.9.45-8_all.deb" \
    "$ROOT/deb/fonts/fonts-wqy-zenhei_0.9.45-8_all.deb"
  download \
    "http://ftp.debian.org/debian/pool/main/f/fonts-wqy-microhei/fonts-wqy-microhei_0.2.0-beta-3.1_all.deb" \
    "$ROOT/deb/fonts/fonts-wqy-microhei_0.2.0-beta-3.1_all.deb"
fi

#######################################
# Manifest
#######################################

cat >"$ROOT/meta/manifest.yaml" <<EOF
platform:
  os: Debian
  version: 12
  arch: amd64

packages:
  nginx:
    version: 1.26.3
  postgresql:
    version: 17
  redis:
    version: 8.0
  zeromq:
    version: 4.3.5
  tusd:
    version: 2.9.2
  opentelemetry:
    contrib: 0.155.0
  openobserve:
    version: 0.91.0
  ffmpeg:
    version: 8.1
  libreoffice:
    version: 7.4.7.2
  poppler:
    version: 22.12.0
EOF

echo
echo "================================="
echo "Download finished"
echo
echo "Repository:"
echo "$ROOT"
echo "================================="
find "$ROOT" -type f ! -name '.DS_Store' | sort
du -sh "$ROOT"
