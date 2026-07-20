#!/usr/bin/env bash
# Builds installer-ready Linux aarch64 Runtime archives inside Debian 13 arm64.

set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

WORK_ROOT=/build
SOURCE_ROOT="$WORK_ROOT/sources"
STAGE_ROOT="$WORK_ROOT/stage"
OUTPUT_ROOT=/workspace/runtime/aarch64
TEMPLATE_ROOT=/workspace/runtime/x86_64
SELECTED_COMPONENT="${MDV_BUILD_COMPONENT:-all}"
JOBS="$(nproc)"

NGINX_VERSION=1.28.3
OPENSSL_VERSION=3.5.7
PCRE2_VERSION=10.47
ZLIB_VERSION=1.3.2
POSTGRESQL_VERSION=17.10
REDIS_VERSION=8.8.0
ZEROMQ_VERSION=4.3.5
TUSD_VERSION=2.9.2
OTEL_VERSION=0.156.0
OPENOBSERVE_VERSION=0.91.1
FFMPEG_VERSION=8.1.2
LIBREOFFICE_VERSION=26.2.4
POPPLER_VERSION=26.07.0

# Installs the compiler toolchain and development libraries shared by source builds.
install_build_dependencies() {
  if [[ -f /opt/mdv-aarch64-builder-ready ]]; then
    return
  fi
  apt-get update
  apt-get install -y --no-install-recommends \
    ca-certificates curl file patchelf pax-utils python3 tar xz-utils
  if [[ "$SELECTED_COMPONENT" != "all" ]] && [[ "$SELECTED_COMPONENT" =~ ^(tusd|opentelemetry|openobserve)$ ]]; then
    return
  fi
  apt-get install -y --no-install-recommends \
    autoconf automake bison build-essential cmake flex \
    gettext git libaom-dev libass-dev libboost-dev libbz2-dev libcurl4-openssl-dev \
    libdav1d-dev libdeflate-dev libfontconfig1-dev libfreetype-dev libharfbuzz-dev \
    libcups2 libdbus-1-3 libice6 libjpeg-dev liblcms2-dev liblz4-dev libnss3-dev \
    libopenjp2-7-dev libopus-dev libsm6 libx11-6 libx11-xcb1 libxcb1 libxext6 libxinerama1 \
    libxrender1 \
    libpng-dev libsodium-dev libssl-dev libtiff-dev libtool libvorbis-dev \
    libvpx-dev libwebp-dev libx264-dev libx265-dev libxml2-dev libzstd-dev \
    meson nasm ninja-build perl pkg-config python3-dev python3-setuptools \
    python3-wheel yasm zlib1g-dev zstd
}

# Returns success when a component should be built for this invocation.
component_selected() {
  [[ "$SELECTED_COMPONENT" == "all" || "$SELECTED_COMPONENT" == "$1" ]]
}

# Downloads one immutable upstream source or release asset with retry support.
download_file() {
  local url="$1"
  local output="$2"
  mkdir -p "$(dirname "$output")"
  if [[ ! -s "$output" ]]; then
    curl -fL --retry 4 --retry-delay 2 -A 'ModiverseRuntimeBuilder/1.0' -o "$output.partial" "$url"
    mv "$output.partial" "$output"
  fi
}

# Calculates a portable SHA-256 digest for one file.
sha256_file() {
  sha256sum "$1" | awk '{print $1}'
}

# Locates the matching x86_64 archive used solely as the installer contract template.
template_archive() {
  local name="$1"
  local version="$2"
  find "$TEMPLATE_ROOT/$name/$version" -maxdepth 1 -name '*.tar.gz' -type f -print -quit
}

# Copies architecture-neutral lifecycle files from the matching x86_64 Runtime.
apply_contract() {
  local name="$1"
  local version="$2"
  local stage="$3"
  local template
  local member
  template="$(template_archive "$name" "$version")"
  [[ -f "$template" ]]

  for member in manifest.yaml README.md README.txt config-templates licenses; do
    if tar -tzf "$template" "./$member" >/dev/null 2>&1; then
      tar -xzf "$template" -C "$stage" "./$member"
    fi
  done
  tar -xzf "$template" -C "$stage" "./bin/mdv-$name"
  sed -i 's/linux-x86_64-glibc/linux-aarch64-glibc/g; s/arch: x86_64/arch: aarch64/g; s/linux-x86_64/linux-aarch64/g' \
    "$stage/manifest.yaml" "$stage"/README.* 2>/dev/null || true
}

# Copies the transitive ELF dependency closure into a Runtime-local lib directory.
bundle_dependencies() {
  local stage="$1"
  shift
  local dependency
  local target
  mkdir -p "$stage/lib"
  for target in "$@"; do
    while IFS= read -r dependency; do
      [[ -f "$dependency" ]] || continue
      case "$dependency" in
        */ld-linux-aarch64.so.1) continue ;;
        "$stage"/*) continue ;;
      esac
      cp -Lf "$dependency" "$stage/lib/$(basename "$dependency")"
    done < <(lddtree -l "$target" 2>/dev/null | sort -u)
  done

  find "$stage/bin" "$stage/sbin" -type f -exec sh -c '
    for candidate do
      if file "$candidate" | grep -q ELF; then
        patchelf --set-rpath "\$ORIGIN/../lib" "$candidate" 2>/dev/null || true
      fi
    done
  ' sh {} + 2>/dev/null || true
  find "$stage/lib" -type f -exec sh -c '
    for candidate do
      case "$candidate" in
        */ld-linux-aarch64.so.1) continue ;;
      esac
      if file "$candidate" | grep -q ELF; then
        patchelf --set-rpath "\$ORIGIN" "$candidate" 2>/dev/null || true
      fi
    done
  ' sh {} +
}

# Discovers every ELF object below a tree and bundles their combined dependencies.
bundle_elf_tree_dependencies() {
  local stage="$1"
  local tree="$2"
  local candidate
  local -a elf_files=()
  while IFS= read -r -d '' candidate; do
    if file "$candidate" | grep -q ELF; then
      elf_files+=("$candidate")
    fi
  done < <(find "$tree" -type f -print0)
  ((${#elf_files[@]} > 0))
  bundle_dependencies "$stage" "${elf_files[@]}"
}

# Writes common build metadata and upstream source checksums.
write_metadata() {
  local name="$1"
  local version="$2"
  local stage="$3"
  shift 3
  {
    echo "$name: $version"
    echo 'Architecture: aarch64'
    echo "Build baseline: $(. /etc/os-release && printf '%s %s' "$NAME" "$VERSION_ID") / glibc $(ldd --version | head -1 | awk '{print $NF}')"
    echo 'Hardening: RELRO, BIND_NOW, NX stack, FORTIFY, stack protector'
  } >"$stage/BUILDINFO"
  : >"$stage/SOURCE-SHA256SUMS"
  local source
  for source in "$@"; do
    printf '%s  %s\n' "$(sha256_file "$source")" "$(basename "$source")" >>"$stage/SOURCE-SHA256SUMS"
  done
}

# Creates the release archive, checksum file, and captured build log.
package_runtime() {
  local name="$1"
  local version="$2"
  local stage="$3"
  local output_dir="$OUTPUT_ROOT/$name/$version"
  local archive="$output_dir/$name-$version-linux-aarch64.tar.gz"
  if [[ "$name" == "opentelemetry" ]]; then
    archive="$output_dir/opentelemetry-collector-$version-linux-aarch64.tar.gz"
  fi
  mkdir -p "$output_dir"
  tar --sort=name --owner=0 --group=0 --numeric-owner -czf "$archive.installing" -C "$stage" .
  mv "$archive.installing" "$archive"
  printf '%s  %s\n' "$(sha256_file "$archive")" "$(basename "$archive")" >"$archive.sha256"
  file "$stage"/bin/* "$stage"/sbin/* 2>/dev/null | grep -E 'ELF|script' >"$output_dir/build.log" || true
}

# Builds Nginx with OpenSSL, PCRE2, and zlib statically embedded.
build_nginx() {
  local stage="$STAGE_ROOT/nginx"
  local nginx_src="$SOURCE_ROOT/nginx-$NGINX_VERSION.tar.gz"
  local openssl_src="$SOURCE_ROOT/openssl-$OPENSSL_VERSION.tar.gz"
  local pcre_src="$SOURCE_ROOT/pcre2-$PCRE2_VERSION.tar.gz"
  local zlib_src="$SOURCE_ROOT/zlib-$ZLIB_VERSION.tar.gz"
  mkdir -p "$stage"
  download_file "https://nginx.org/download/nginx-$NGINX_VERSION.tar.gz" "$nginx_src"
  download_file "https://github.com/openssl/openssl/releases/download/openssl-$OPENSSL_VERSION/openssl-$OPENSSL_VERSION.tar.gz" "$openssl_src"
  download_file "https://github.com/PCRE2Project/pcre2/releases/download/pcre2-$PCRE2_VERSION/pcre2-$PCRE2_VERSION.tar.gz" "$pcre_src"
  download_file "https://zlib.net/fossils/zlib-$ZLIB_VERSION.tar.gz" "$zlib_src"
  tar -xzf "$nginx_src" -C "$WORK_ROOT"
  tar -xzf "$openssl_src" -C "$WORK_ROOT"
  tar -xzf "$pcre_src" -C "$WORK_ROOT"
  tar -xzf "$zlib_src" -C "$WORK_ROOT"
  (
    cd "$WORK_ROOT/nginx-$NGINX_VERSION"
    ./configure --prefix=/ --sbin-path=/sbin/nginx --modules-path=/modules \
      --conf-path=/conf/nginx.conf --error-log-path=/logs/error.log \
      --http-log-path=/logs/access.log --pid-path=/run/nginx.pid \
      --lock-path=/run/nginx.lock --user=nobody --group=nogroup --with-threads \
      --with-file-aio --with-http_ssl_module --with-http_v2_module \
      --with-http_realip_module --with-http_stub_status_module \
      --with-http_gzip_static_module --with-http_gunzip_module \
      --with-http_auth_request_module --with-http_secure_link_module \
      --with-http_slice_module --with-stream --with-stream_ssl_module \
      --with-stream_realip_module --with-stream_ssl_preread_module \
      --without-mail_pop3_module --without-mail_imap_module --without-mail_smtp_module \
      --with-pcre="$WORK_ROOT/pcre2-$PCRE2_VERSION" --with-pcre-jit \
      --with-openssl="$WORK_ROOT/openssl-$OPENSSL_VERSION" \
      --with-openssl-opt='no-weak-ssl-ciphers' --with-zlib="$WORK_ROOT/zlib-$ZLIB_VERSION" \
      --with-cc-opt='-O2 -fPIE -fstack-protector-strong -D_FORTIFY_SOURCE=2 -fno-strict-aliasing' \
      --with-ld-opt='-Wl,-z,relro -Wl,-z,now -Wl,-z,noexecstack -pie'
    make -j"$JOBS"
    make install DESTDIR="$stage"
  )
  mkdir -p "$stage/bin" "$stage/logs" "$stage/run" "$stage/tmp"
  ln -s ../sbin/nginx "$stage/bin/nginx"
  apply_contract nginx "$NGINX_VERSION" "$stage"
  bundle_dependencies "$stage" "$stage/sbin/nginx"
  write_metadata nginx "$NGINX_VERSION" "$stage" "$nginx_src" "$openssl_src" "$pcre_src" "$zlib_src"
  package_runtime nginx "$NGINX_VERSION" "$stage"
}

# Builds PostgreSQL with SSL, LZ4, and Zstandard support.
build_postgresql() {
  local stage="$STAGE_ROOT/postgresql"
  local source="$SOURCE_ROOT/postgresql-$POSTGRESQL_VERSION.tar.bz2"
  mkdir -p "$stage"
  download_file "https://ftp.postgresql.org/pub/source/v$POSTGRESQL_VERSION/postgresql-$POSTGRESQL_VERSION.tar.bz2" "$source"
  tar -xjf "$source" -C "$WORK_ROOT"
  (
    cd "$WORK_ROOT/postgresql-$POSTGRESQL_VERSION"
    ./configure --prefix=/usr/local --disable-rpath --with-ssl=openssl --with-lz4 --with-zstd \
      --without-readline --without-icu --with-blocksize=8 --with-wal-blocksize=8 --with-segsize=1 \
      CFLAGS='-O2 -pipe -fPIC -fstack-protector-strong -D_FORTIFY_SOURCE=2 -fno-strict-aliasing -fwrapv' \
      LDFLAGS='-Wl,-z,relro,-z,now,-z,noexecstack,--as-needed'
    make -j"$JOBS"
    make install DESTDIR="$stage"
    make -C contrib install DESTDIR="$stage"
  )
  cp -a "$stage/usr/local/." "$stage/"
  find "$stage/usr" -depth -delete
  apply_contract postgresql "$POSTGRESQL_VERSION" "$stage"
  bundle_dependencies "$stage" "$stage/bin/postgres" "$stage/bin/psql"
  write_metadata postgresql "$POSTGRESQL_VERSION" "$stage" "$source"
  package_runtime postgresql "$POSTGRESQL_VERSION" "$stage"
}

# Builds Redis with TLS and the bundled jemalloc allocator.
build_redis() {
  local stage="$STAGE_ROOT/redis"
  local source="$SOURCE_ROOT/redis-$REDIS_VERSION.tar.gz"
  mkdir -p "$stage/bin"
  download_file "https://download.redis.io/releases/redis-$REDIS_VERSION.tar.gz" "$source"
  tar -xzf "$source" -C "$WORK_ROOT"
  make -C "$WORK_ROOT/redis-$REDIS_VERSION" -j"$JOBS" BUILD_TLS=yes \
    CFLAGS='-O3 -pipe -fPIC -fstack-protector-strong -D_FORTIFY_SOURCE=2' \
    LDFLAGS='-Wl,-z,relro,-z,now,-z,noexecstack'
  cp "$WORK_ROOT/redis-$REDIS_VERSION"/src/redis-{server,cli,benchmark,check-aof,check-rdb} "$stage/bin/"
  apply_contract redis "$REDIS_VERSION" "$stage"
  bundle_dependencies "$stage" "$stage/bin/redis-server" "$stage/bin/redis-cli"
  write_metadata redis "$REDIS_VERSION" "$stage" "$source"
  package_runtime redis "$REDIS_VERSION" "$stage"
}

# Builds shared ZeroMQ with CURVE support from libsodium.
build_zeromq() {
  local stage="$STAGE_ROOT/zeromq"
  local source="$SOURCE_ROOT/zeromq-$ZEROMQ_VERSION.tar.gz"
  mkdir -p "$stage"
  download_file "https://github.com/zeromq/libzmq/releases/download/v$ZEROMQ_VERSION/zeromq-$ZEROMQ_VERSION.tar.gz" "$source"
  tar -xzf "$source" -C "$WORK_ROOT"
  (
    cd "$WORK_ROOT/zeromq-$ZEROMQ_VERSION"
    ./configure --prefix=/usr/local --enable-shared --disable-static --with-libsodium \
      CFLAGS='-O3 -fPIC -fstack-protector-strong -D_FORTIFY_SOURCE=2' \
      CXXFLAGS='-O3 -fPIC -fstack-protector-strong -D_FORTIFY_SOURCE=2' \
      LDFLAGS='-Wl,-z,relro,-z,now,-z,noexecstack'
    make -j"$JOBS"
    make install DESTDIR="$stage"
  )
  cp -a "$stage/usr/local/." "$stage/"
  find "$stage/usr" -depth -delete
  apply_contract zeromq "$ZEROMQ_VERSION" "$stage"
  bundle_dependencies "$stage" "$stage/lib/libzmq.so"
  write_metadata zeromq "$ZEROMQ_VERSION" "$stage" "$source"
  package_runtime zeromq "$ZEROMQ_VERSION" "$stage"
}

# Packages the official statically linked tusd arm64 release.
build_tusd() {
  local stage="$STAGE_ROOT/tusd"
  local source="$SOURCE_ROOT/tusd_v$TUSD_VERSION.tar.gz"
  mkdir -p "$stage/bin"
  download_file "https://github.com/tus/tusd/releases/download/v$TUSD_VERSION/tusd_linux_arm64.tar.gz" "$source"
  tar -xzf "$source" -C "$stage/bin" --strip-components=1 tusd_linux_arm64/tusd
  apply_contract tusd "$TUSD_VERSION" "$stage"
  write_metadata tusd "$TUSD_VERSION" "$stage" "$source"
  package_runtime tusd "$TUSD_VERSION" "$stage"
}

# Packages official core and contrib OpenTelemetry Collector arm64 releases.
build_opentelemetry() {
  local stage="$STAGE_ROOT/opentelemetry"
  local core="$SOURCE_ROOT/otelcol_${OTEL_VERSION}_linux_arm64.tar.gz"
  local contrib="$SOURCE_ROOT/otelcol-contrib_${OTEL_VERSION}_linux_arm64.tar.gz"
  mkdir -p "$stage/bin"
  download_file "https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v$OTEL_VERSION/otelcol_${OTEL_VERSION}_linux_arm64.tar.gz" "$core"
  download_file "https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v$OTEL_VERSION/otelcol-contrib_${OTEL_VERSION}_linux_arm64.tar.gz" "$contrib"
  tar -xzf "$core" -C "$stage/bin" otelcol
  tar -xzf "$contrib" -C "$stage/bin" otelcol-contrib
  apply_contract opentelemetry "$OTEL_VERSION" "$stage"
  write_metadata opentelemetry "$OTEL_VERSION" "$stage" "$core" "$contrib"
  package_runtime opentelemetry "$OTEL_VERSION" "$stage"
}

# Packages the official OpenObserve arm64 binary with a bundled glibc loader closure.
build_openobserve() {
  local stage="$STAGE_ROOT/openobserve"
  local source="$SOURCE_ROOT/openobserve-v$OPENOBSERVE_VERSION-linux-arm64.tar.gz"
  mkdir -p "$stage/bin" "$stage/lib"
  download_file "https://downloads.openobserve.ai/releases/openobserve/v$OPENOBSERVE_VERSION/openobserve-v$OPENOBSERVE_VERSION-linux-arm64.tar.gz" "$source"
  tar -xzf "$source" -C "$stage/bin"
  local upstream_binary
  upstream_binary="$(find "$stage/bin" -maxdepth 2 -type f -name openobserve -print -quit)"
  cp "$upstream_binary" "$stage/bin/openobserve.bin"
  bundle_dependencies "$stage" "$stage/bin/openobserve.bin"
  cp -L /lib/ld-linux-aarch64.so.1 "$stage/lib/ld-linux-aarch64.so.1"
  cat >"$stage/bin/openobserve" <<'EOF'
#!/bin/sh
# Launches OpenObserve through the Runtime-local aarch64 glibc loader.
BASE=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
exec "$BASE/lib/ld-linux-aarch64.so.1" --inhibit-cache --library-path "$BASE/lib" "$BASE/bin/openobserve.bin" "$@"
EOF
  chmod 755 "$stage/bin/openobserve"
  apply_contract openobserve "$OPENOBSERVE_VERSION" "$stage"
  write_metadata openobserve "$OPENOBSERVE_VERSION" "$stage" "$source"
  package_runtime openobserve "$OPENOBSERVE_VERSION" "$stage"
}

# Builds FFmpeg with the same major codec families enabled as the x86_64 Runtime.
build_ffmpeg() {
  local stage="$STAGE_ROOT/ffmpeg"
  local source="$SOURCE_ROOT/ffmpeg-$FFMPEG_VERSION.tar.xz"
  mkdir -p "$stage"
  download_file "https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz" "$source"
  tar -xJf "$source" -C "$WORK_ROOT"
  (
    cd "$WORK_ROOT/ffmpeg-$FFMPEG_VERSION"
    ./configure --prefix=/usr/local --disable-debug --enable-gpl --enable-version3 \
      --enable-libx264 --enable-libx265 --enable-libvpx --enable-libopus --enable-libvorbis \
      --enable-libwebp --enable-libaom --enable-libdav1d --enable-libass \
      --enable-libfreetype --enable-libfontconfig --enable-libharfbuzz --enable-openssl \
      --extra-cflags='-O3 -fPIC -fstack-protector-strong -D_FORTIFY_SOURCE=2' \
      --extra-ldflags='-Wl,-z,relro,-z,now,-z,noexecstack'
    make -j"$JOBS"
    make install DESTDIR="$stage"
  )
  cp -a "$stage/usr/local/." "$stage/"
  find "$stage/usr" -depth -delete
  apply_contract ffmpeg "$FFMPEG_VERSION" "$stage"
  bundle_dependencies "$stage" "$stage/bin/ffmpeg" "$stage/bin/ffprobe"
  write_metadata ffmpeg "$FFMPEG_VERSION" "$stage" "$source"
  package_runtime ffmpeg "$FFMPEG_VERSION" "$stage"
}

# Builds Poppler CLI tools and bundles their third-party shared-library closure.
build_poppler() {
  local stage="$STAGE_ROOT/poppler"
  local source="$SOURCE_ROOT/poppler-$POPPLER_VERSION.tar.xz"
  mkdir -p "$stage"
  download_file "https://poppler.freedesktop.org/poppler-$POPPLER_VERSION.tar.xz" "$source"
  tar -xJf "$source" -C "$WORK_ROOT"
  cmake -S "$WORK_ROOT/poppler-$POPPLER_VERSION" -B "$WORK_ROOT/poppler-build" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr/local \
    -DBUILD_GTK_TESTS=OFF -DBUILD_QT5_TESTS=OFF -DBUILD_QT6_TESTS=OFF \
    -DENABLE_QT5=OFF -DENABLE_QT6=OFF -DENABLE_GLIB=OFF -DENABLE_CPP=ON \
    -DENABLE_UTILS=ON -DENABLE_GPGME=OFF -DBUILD_SHARED_LIBS=ON \
    -DCMAKE_C_FLAGS_RELEASE='-O3 -DNDEBUG -fstack-protector-strong -D_FORTIFY_SOURCE=2' \
    -DCMAKE_CXX_FLAGS_RELEASE='-O3 -DNDEBUG -fstack-protector-strong -D_FORTIFY_SOURCE=2'
  cmake --build "$WORK_ROOT/poppler-build" --parallel "$JOBS"
  DESTDIR="$stage" cmake --install "$WORK_ROOT/poppler-build"
  cp -a "$stage/usr/local/." "$stage/"
  find "$stage/usr" -depth -delete
  apply_contract poppler "$POPPLER_VERSION" "$stage"
  bundle_dependencies "$stage" "$stage/bin/pdftotext" "$stage/bin/pdftoppm" "$stage/bin/pdfinfo"
  write_metadata poppler "$POPPLER_VERSION" "$stage" "$source"
  package_runtime poppler "$POPPLER_VERSION" "$stage"
}

# Packages the official LibreOffice aarch64 release with its complete runtime dependency closure.
build_libreoffice() {
  local stage="$STAGE_ROOT/libreoffice"
  local source="$SOURCE_ROOT/LibreOffice_${LIBREOFFICE_VERSION}_Linux_aarch64_deb.tar.gz"
  local extracted="$WORK_ROOT/libreoffice-debs"
  mkdir -p "$stage" "$extracted"
  download_file "https://download.documentfoundation.org/libreoffice/stable/$LIBREOFFICE_VERSION/deb/aarch64/LibreOffice_${LIBREOFFICE_VERSION}_Linux_aarch64_deb.tar.gz" "$source"
  tar -xzf "$source" -C "$extracted"
  local package
  while IFS= read -r -d '' package; do
    dpkg-deb -x "$package" "$stage"
  done < <(find "$extracted" -name '*.deb' -type f -print0)
  local office_root
  office_root="$(find "$stage/opt" -maxdepth 1 -type d -name 'libreoffice*' -print -quit)"
  cp -a "$office_root/." "$stage/"
  find "$stage/opt" -depth -delete
  mkdir -p "$stage/bin" "$stage/lib"
  cp -L /lib/ld-linux-aarch64.so.1 "$stage/lib/ld-linux-aarch64.so.1"
  bundle_elf_tree_dependencies "$stage" "$stage/program"
  cat >"$stage/bin/libreoffice" <<EOF
#!/bin/sh
# Launches LibreOffice headlessly through the Runtime-local aarch64 glibc loader.
BASE=\$(CDPATH= cd -- "\$(dirname -- "\$0")/.." && pwd)
export GCONV_PATH="\$BASE/lib/gconv"
exec "\$BASE/lib/ld-linux-aarch64.so.1" --inhibit-cache --library-path "\$BASE/program:\$BASE/lib" "\$BASE/program/soffice.bin" "\$@"
EOF
  cp "$stage/bin/libreoffice" "$stage/bin/soffice"
  chmod 755 "$stage/bin/libreoffice" "$stage/bin/soffice"
  apply_contract libreoffice "$LIBREOFFICE_VERSION" "$stage"
  write_metadata libreoffice "$LIBREOFFICE_VERSION" "$stage" "$source"
  package_runtime libreoffice "$LIBREOFFICE_VERSION" "$stage"
}

# Dispatches requested component builds in dependency-cost order.
main() {
  [[ "$(uname -m)" == "aarch64" ]]
  mkdir -p "$SOURCE_ROOT" "$STAGE_ROOT" "$OUTPUT_ROOT"
  install_build_dependencies
  component_selected tusd && build_tusd
  component_selected opentelemetry && build_opentelemetry
  component_selected openobserve && build_openobserve
  component_selected nginx && build_nginx
  component_selected zeromq && build_zeromq
  component_selected redis && build_redis
  component_selected postgresql && build_postgresql
  component_selected ffmpeg && build_ffmpeg
  component_selected poppler && build_poppler
  component_selected libreoffice && build_libreoffice
  chown -R "${MDV_HOST_UID:-0}:${MDV_HOST_GID:-0}" "$OUTPUT_ROOT"
}

main "$@"
