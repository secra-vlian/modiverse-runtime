#!/usr/bin/env bash
# musl delivery builders for aarch64 hybrid Runtime (sourced by build-aarch64.sh).

# nginx from official Alpine musl apk + runtime deps.
build_nginx_musl() {
  local stage="$STAGE_ROOT/nginx"
  rm -rf "$stage"
  mkdir -p "$stage/logs" "$stage/run" "$stage/tmp"
  stage_from_alpine_apks "$stage" \
    "${MDV_ALPINE_BRANCH_stable}|main|${MDV_ALPINE_NGINX_PKG}|${MDV_ALPINE_NGINX_VER}" \
    "${MDV_ALPINE_BRANCH_stable}|main|pcre2|10.46-r0" \
    "${MDV_ALPINE_BRANCH_stable}|main|openssl|3.5.7-r0" \
    "${MDV_ALPINE_BRANCH_stable}|main|zlib|1.3.2-r0"
  mkdir -p "$stage/bin" "$stage/conf"
  if [[ -d "$stage/etc/nginx" ]]; then
    cp -a "$stage/etc/nginx/." "$stage/conf/"
  fi
  cat >"$stage/bin/nginx" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)"
exec "$ROOT/sbin/nginx" -p "$ROOT/" -c "$ROOT/conf/nginx.conf" "$@"
EOF
  chmod 0755 "$stage/bin/nginx"
  finalize_musl_component nginx "$NGINX_VERSION" "$stage" musl-official-apk \
    "Delivery: Alpine ${MDV_ALPINE_BRANCH_stable} ${MDV_ALPINE_NGINX_PKG}-${MDV_ALPINE_NGINX_VER} (+ pcre2, openssl, zlib)"
}

# postgresql from official Alpine musl apk closure.
build_postgresql_musl() {
  local stage="$STAGE_ROOT/postgresql"
  rm -rf "$stage"
  mkdir -p "$stage"
  stage_from_alpine_apks "$stage" \
    "${MDV_ALPINE_BRANCH_stable}|main|${MDV_ALPINE_POSTGRESQL_PKG}|${MDV_ALPINE_POSTGRESQL_VER}" \
    "${MDV_ALPINE_BRANCH_stable}|main|postgresql17-client|17.10-r0" \
    "${MDV_ALPINE_BRANCH_stable}|main|postgresql-common|1.2-r1" \
    "${MDV_ALPINE_BRANCH_stable}|main|icu-libs|76.1-r1" \
    "${MDV_ALPINE_BRANCH_stable}|main|icu-data-en|76.1-r1" \
    "${MDV_ALPINE_BRANCH_stable}|main|openssl|3.5.7-r0" \
    "${MDV_ALPINE_BRANCH_stable}|main|zlib|1.3.2-r0" \
    "${MDV_ALPINE_BRANCH_stable}|main|lz4-libs|1.10.0-r0" \
    "${MDV_ALPINE_BRANCH_stable}|main|zstd-libs|1.5.7-r0" \
    "${MDV_ALPINE_BRANCH_stable}|main|libxml2|2.13.9-r1" \
    "${MDV_ALPINE_BRANCH_stable}|main|openldap|2.6.8-r0" \
    "${MDV_ALPINE_BRANCH_stable}|main|tzdata|2026c-r0"
  finalize_musl_component postgresql "$POSTGRESQL_VERSION" "$stage" musl-official-apk \
    "Delivery: Alpine ${MDV_ALPINE_BRANCH_stable} postgresql17-17.10-r0 (+ client/common/icu/openssl/xml/ldap runtime closure)"
}

# redis from official Alpine edge musl apk.
build_redis_musl() {
  local stage="$STAGE_ROOT/redis"
  rm -rf "$stage"
  mkdir -p "$stage"
  stage_from_alpine_apks "$stage" \
    "${MDV_ALPINE_REDIS_BRANCH}|community|${MDV_ALPINE_REDIS_PKG}|${MDV_ALPINE_REDIS_VER}" \
    "${MDV_ALPINE_REDIS_BRANCH}|main|openssl|3.5.7-r0"
  finalize_musl_component redis "$REDIS_VERSION" "$stage" musl-official-apk \
    "Delivery: Alpine ${MDV_ALPINE_REDIS_BRANCH} ${MDV_ALPINE_REDIS_PKG}-${MDV_ALPINE_REDIS_VER}"
}

# zeromq from official Alpine musl apk + libsodium.
build_zeromq_musl() {
  local stage="$STAGE_ROOT/zeromq"
  rm -rf "$stage"
  mkdir -p "$stage"
  stage_from_alpine_apks "$stage" \
    "${MDV_ALPINE_BRANCH_stable}|main|${MDV_ALPINE_ZEROMQ_PKG}|${MDV_ALPINE_ZEROMQ_VER}" \
    "${MDV_ALPINE_BRANCH_stable}|main|libsodium|1.0.20-r1"
  finalize_musl_component zeromq "$ZEROMQ_VERSION" "$stage" musl-official-apk \
    "Delivery: Alpine ${MDV_ALPINE_BRANCH_stable} ${MDV_ALPINE_ZEROMQ_PKG}-${MDV_ALPINE_ZEROMQ_VER} (+ libsodium)"
}

# ffmpeg from official Alpine edge musl apk + libav library split packages.
build_ffmpeg_musl() {
  local stage="$STAGE_ROOT/ffmpeg"
  rm -rf "$stage"
  mkdir -p "$stage/bin"
  stage_from_alpine_apks "$stage" \
    "${MDV_ALPINE_FFMPEG_BRANCH}|community|${MDV_ALPINE_FFMPEG_PKG}|${MDV_ALPINE_FFMPEG_VER}" \
    "${MDV_ALPINE_FFMPEG_BRANCH}|community|ffmpeg-libavcodec|8.1.2-r0" \
    "${MDV_ALPINE_FFMPEG_BRANCH}|community|ffmpeg-libavdevice|8.1.2-r0" \
    "${MDV_ALPINE_FFMPEG_BRANCH}|community|ffmpeg-libavfilter|8.1.2-r0" \
    "${MDV_ALPINE_FFMPEG_BRANCH}|community|ffmpeg-libavformat|8.1.2-r0" \
    "${MDV_ALPINE_FFMPEG_BRANCH}|community|ffmpeg-libavutil|8.1.2-r0" \
    "${MDV_ALPINE_FFMPEG_BRANCH}|community|ffmpeg-libswresample|8.1.2-r0" \
    "${MDV_ALPINE_FFMPEG_BRANCH}|community|ffmpeg-libswscale|8.1.2-r0" \
    "${MDV_ALPINE_FFMPEG_BRANCH}|main|zlib|1.3.2-r0"
  mkdir -p "$stage/bin"
  [[ -x "$stage/usr/bin/ffmpeg" ]] && cp -a "$stage/usr/bin/ffmpeg" "$stage/usr/bin/ffprobe" "$stage/bin/"
  find "$stage/usr" -depth -delete 2>/dev/null || true
  finalize_musl_component ffmpeg "$FFMPEG_VERSION" "$stage" musl-official-apk \
    "Delivery: Alpine ${MDV_ALPINE_FFMPEG_BRANCH} ffmpeg-8.1.2-r0 (+ libav* runtime libs)"
}

# tusd official static Go binary (musl-compatible, no libc shipped).
build_tusd_musl() {
  local stage="$STAGE_ROOT/tusd"
  local source="$SOURCE_ROOT/tusd_v$TUSD_VERSION.tar.gz"
  mkdir -p "$stage/bin"
  download_file "https://github.com/tus/tusd/releases/download/v$TUSD_VERSION/tusd_linux_arm64.tar.gz" "$source"
  tar -xzf "$source" -C "$stage/bin" --strip-components=1 tusd_linux_arm64/tusd
  apply_contract tusd "$TUSD_VERSION" "$stage"
  patch_manifest_platform "$stage" musl
  assert_no_forbidden_host_libs "$stage"
  write_metadata tusd "$TUSD_VERSION" "$stage" "$source"
  {
    echo 'Runtime linkage: musl-static-bin'
    echo 'Build baseline: official static Go release (CGO_ENABLED=0; runs on musl hosts)'
    echo 'Delivery: tusd official linux/arm64 tarball'
  } >>"$stage/BUILDINFO"
  record_linkage_manifest tusd "$TUSD_VERSION" musl-static-bin \
    "Official static Go binary; no musl/glibc shipped"
  package_runtime tusd "$TUSD_VERSION" "$stage"
}

# OpenTelemetry Collector official static Go binaries.
build_opentelemetry_musl() {
  local stage="$STAGE_ROOT/opentelemetry"
  local core="$SOURCE_ROOT/otelcol_${OTEL_VERSION}_linux_arm64.tar.gz"
  local contrib="$SOURCE_ROOT/otelcol-contrib_${OTEL_VERSION}_linux_arm64.tar.gz"
  mkdir -p "$stage/bin"
  download_file "https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v$OTEL_VERSION/otelcol_${OTEL_VERSION}_linux_arm64.tar.gz" "$core"
  download_file "https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v$OTEL_VERSION/otelcol-contrib_${OTEL_VERSION}_linux_arm64.tar.gz" "$contrib"
  tar -xzf "$core" -C "$stage/bin" otelcol
  tar -xzf "$contrib" -C "$stage/bin" otelcol-contrib
  apply_contract opentelemetry "$OTEL_VERSION" "$stage"
  patch_manifest_platform "$stage" musl
  assert_no_forbidden_host_libs "$stage"
  write_metadata opentelemetry "$OTEL_VERSION" "$stage" "$core" "$contrib"
  {
    echo 'Runtime linkage: musl-static-bin'
    echo 'Build baseline: official static Go release (CGO_ENABLED=0; runs on musl hosts)'
    echo 'Delivery: otelcol + otelcol-contrib official linux/arm64 tarballs'
  } >>"$stage/BUILDINFO"
  record_linkage_manifest opentelemetry "$OTEL_VERSION" musl-static-bin \
    "Official static Go binaries; no musl/glibc shipped"
  package_runtime opentelemetry "$OTEL_VERSION" "$stage"
}

# OpenObserve official musl release (replaces glibc-only L1 defer path).
build_openobserve_musl() {
  local stage="$STAGE_ROOT/openobserve"
  local source="$SOURCE_ROOT/openobserve-v$OPENOBSERVE_VERSION-linux-arm64-musl.tar.gz"
  mkdir -p "$stage/bin"
  download_file \
    "https://downloads.openobserve.ai/releases/openobserve/v$OPENOBSERVE_VERSION/openobserve-v$OPENOBSERVE_VERSION-linux-arm64-musl.tar.gz" \
    "$source"
  tar -xzf "$source" -C "$stage/bin"
  strip_musl_and_loader "$stage"
  assert_no_musl_or_loader "$stage"
  apply_contract openobserve "$OPENOBSERVE_VERSION" "$stage"
  patch_manifest_platform "$stage" musl
  write_metadata openobserve "$OPENOBSERVE_VERSION" "$stage" "$source"
  {
    echo 'Runtime linkage: musl-official-bin'
    echo 'Build baseline: official OpenObserve linux-arm64-musl release'
    echo 'Delivery: downloads.openobserve.ai musl tarball (no glibc dependency)'
  } >>"$stage/BUILDINFO"
  record_linkage_manifest openobserve "$OPENOBSERVE_VERSION" musl-official-bin \
    "Official openobserve-*-linux-arm64-musl release"
  package_runtime openobserve "$OPENOBSERVE_VERSION" "$stage"
}

# Entry wrappers: prefer musl strategies configured in aarch64-linkage.env.
build_nginx() {
  if component_uses_musl nginx; then build_nginx_musl; else build_nginx_glibc_source; fi
}
build_postgresql() {
  if component_uses_musl postgresql; then build_postgresql_musl; else build_postgresql_glibc_source; fi
}
build_redis() {
  if component_uses_musl redis; then build_redis_musl; else build_redis_glibc_source; fi
}
build_zeromq() {
  if component_uses_musl zeromq; then build_zeromq_musl; else build_zeromq_glibc_source; fi
}
build_ffmpeg() {
  if component_uses_musl ffmpeg; then build_ffmpeg_musl; else build_ffmpeg_glibc_source; fi
}
build_tusd() {
  if component_uses_musl tusd; then build_tusd_musl; else build_tusd_glibc_source; fi
}
build_opentelemetry() {
  if component_uses_musl opentelemetry; then build_opentelemetry_musl; else build_opentelemetry_glibc_source; fi
}
build_openobserve() {
  if component_uses_musl openobserve; then build_openobserve_musl; else build_openobserve_glibc_source; fi
}
