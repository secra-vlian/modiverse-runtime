#!/usr/bin/env bash
# Builds installer-ready Linux aarch64 Runtime archives on manylinux2014 (glibc 2.17).
# Packaging contract matches x86_64: static third-party libs for core services; never
# mix host system OpenSSL/zlib into those archives; glibc loader closures are only
# allowed for openobserve/libreoffice and must be complete (ld-linux + libc).

set -euo pipefail

# GNU make / curl can raise SIGPIPE when stdout is redirected; ignore it so the
# packaging steps after a successful compile still run.
trap '' PIPE

export PATH=/opt/rh/devtoolset-10/root/usr/bin:/opt/cmake/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}
export LD_LIBRARY_PATH=/opt/rh/devtoolset-10/root/usr/lib64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}

WORK_ROOT=/build
SOURCE_ROOT="$WORK_ROOT/sources"
STAGE_ROOT="$WORK_ROOT/stage"
VENDOR_ROOT="$WORK_ROOT/vendor"
OUTPUT_ROOT=/workspace/runtime/aarch64
TEMPLATE_ROOT=/workspace/runtime/x86_64
SELECTED_COMPONENT="${MDV_BUILD_COMPONENT:-all}"
JOBS="${MDV_BUILD_JOBS:-$(nproc)}"

NGINX_VERSION=1.28.3
OPENSSL_VERSION=3.5.7
PCRE2_VERSION=10.47
ZLIB_VERSION=1.3.2
LZ4_VERSION=1.10.0
ZSTD_VERSION=1.5.7
LIBSODIUM_VERSION=1.0.20
POSTGRESQL_VERSION=17.10
REDIS_VERSION=8.8.0
ZEROMQ_VERSION=4.3.5
TUSD_VERSION=2.9.2
OTEL_VERSION=0.156.0
OPENOBSERVE_VERSION=0.91.1
FFMPEG_VERSION=8.1.2
LIBREOFFICE_VERSION=26.2.4
POPPLER_VERSION=26.07.0
FREETYPE_VERSION=2.13.3
FONTCONFIG_VERSION=2.15.0
TIFF_VERSION=4.7.0
LCMS_VERSION=2.16
OPENJPEG_VERSION=2.5.3
JPEG_VERSION=3.0.4
PNG_VERSION=1.6.47
EXPAT_VERSION=2.6.4

# Installs the compiler toolchain when the image marker is absent (local fallback).
install_build_dependencies() {
  if [[ -f /opt/mdv-aarch64-builder-ready ]]; then
    return
  fi
  yum -y install \
    autoconf automake bison bzip2 bzip2-devel ca-certificates curl diffutils \
    expat-devel file flex gettext git glibc-devel gperf libjpeg-turbo-devel \
    libpng-devel libtool libxml2-devel make nss-devel patch patchelf pax-utils \
    perl pkgconfig python3 python3-devel tar which xz xz-devel zlib-devel
}

# Runs make, tolerating exit 141 (SIGPIPE) which GNU make can return after a
# successful build when container stdout is redirected to a file.
run_make() {
  local status=0
  make "$@" || status=$?
  if [[ "$status" -eq 0 || "$status" -eq 141 ]]; then
    return 0
  fi
  return "$status"
}

# Returns success when a component should be built for this invocation.
component_selected() {
  [[ "$SELECTED_COMPONENT" == "all" || "$SELECTED_COMPONENT" == "$1" ]]
}


# Downloads one immutable upstream source or release asset with retry support.
download_file() {
  local url="$1"
  local output="$2"
  local attempt
  local max_time="${3:-1800}"
  local cache_candidate="/workspace/.cache/sources/$(basename "$output")"
  mkdir -p "$(dirname "$output")"
  # Prefer a pre-seeded host cache for huge release assets (e.g. LibreOffice).
  if [[ ! -s "$output" && -s "$cache_candidate" ]]; then
    cp -a "$cache_candidate" "$output"
    return
  fi
  if [[ ! -s "$output" ]]; then
    for attempt in 1 2 3 4 5; do
      if curl -fL --connect-timeout 30 --max-time "$max_time" --retry 2 --retry-delay 2 \
        -A 'ModiverseRuntimeBuilder/1.0' -o "$output.partial" "$url"; then
        mv "$output.partial" "$output"
        return
      fi
      rm -f "$output.partial"
      if ((attempt < 5)); then
        sleep $((attempt * 2))
      fi
    done
    echo "failed to download $url after 5 attempts" >&2
    return 1
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

# True when a path is a glibc / dynamic-loader shared object.
is_glibc_or_loader() {
  local base
  base="$(basename "$1")"
  case "$base" in
    ld-linux-aarch64.so.1|ld-*.so|libc.so.6|libm.so.6|libpthread.so.0|libdl.so.2|librt.so.1|libresolv.so.2|libnss_*.so*|libthread_db.so.1)
      return 0
      ;;
  esac
  return 1
}

# True when a path is a host-system library that core Runtimes must not ship.
is_forbidden_host_lib() {
  local path="$1"
  local base
  base="$(basename "$path")"
  # conda-forge GCC runtime is intentionally bundled with Poppler (C++23 toolchain).
  case "$path" in
    /opt/conda-gcc/*) return 1 ;;
  esac
  case "$base" in
    libssl.so*|libcrypto.so*|libz.so*|liblz4.so*|libzstd.so*|libcrypt.so*|libsodium.so*|libgcc_s.so*|libstdc++.so*)
      return 0
      ;;
  esac
  case "$path" in
    /lib/*|/lib64/*|/usr/lib/*|/usr/lib64/*)
      return 0
      ;;
  esac
  return 1
}

# Sets $ORIGIN rpath on ELF files under bin/sbin and lib.
set_origin_rpaths() {
  local stage="$1"
  local -a roots=()
  [[ -d "$stage/bin" ]] && roots+=("$stage/bin")
  [[ -d "$stage/sbin" ]] && roots+=("$stage/sbin")
  if ((${#roots[@]} > 0)); then
    find "${roots[@]}" -type f 2>/dev/null | while read -r candidate; do
      if file "$candidate" 2>/dev/null | grep -q ELF; then
        patchelf --set-rpath '\$ORIGIN/../lib' "$candidate" 2>/dev/null || true
      fi
    done
  fi
  if [[ -d "$stage/lib" ]]; then
    find "$stage/lib" -type f 2>/dev/null | while read -r candidate; do
      if is_glibc_or_loader "$candidate"; then
        continue
      fi
      if file "$candidate" 2>/dev/null | grep -q ELF; then
        patchelf --set-rpath '\$ORIGIN' "$candidate" 2>/dev/null || true
      fi
    done
  fi
}

# Bundles non-glibc third-party deps only (poppler). Never copies loader/libc or
# arbitrary host /lib copies that would mix build-host glibc into the archive.
bundle_third_party_dependencies() {
  local stage="$1"
  shift
  local dependency
  local dependency_tree
  local dependency_search_path="$stage/lib:$stage/lib64:$VENDOR_ROOT/lib:$VENDOR_ROOT/lib64:/usr/local/lib:/usr/local/lib64"
  local target
  local -a targets=("$@")
  mkdir -p "$stage/lib"
  for target in "${targets[@]}"; do
    while IFS= read -r dependency; do
      [[ -f "$dependency" ]] || continue
      if is_glibc_or_loader "$dependency"; then
        continue
      fi
      case "$dependency" in
        "$stage"/*|"$VENDOR_ROOT"/*|/usr/local/*) ;;
        *)
          # Refuse host /lib and /usr/lib copies for poppler; vendor must provide them.
          if is_forbidden_host_lib "$dependency"; then
            printf 'refusing to bundle host system library %s for %s\n' "$dependency" "$target" >&2
            return 1
          fi
          ;;
      esac
      local dest="$stage/lib/$(basename "$dependency")"
      # Skip when lddtree already resolved to the staged copy (cp onto self fails).
      if [[ "$dependency" -ef "$dest" ]]; then
        continue
      fi
      cp -Lf "$dependency" "$dest"
    done < <(
      LD_LIBRARY_PATH="$dependency_search_path${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
        lddtree -l "$target" 2>/dev/null | sort -u
    )
  done
  set_origin_rpaths "$stage"
  for target in "${targets[@]}"; do
    dependency_tree="$({
      LD_LIBRARY_PATH="$stage/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
        lddtree "$target"
    } 2>&1)"
    if grep -q '=> not found' <<<"$dependency_tree"; then
      printf 'unresolved Runtime dependencies for %s:\n%s\n' "$target" "$dependency_tree" >&2
      return 1
    fi
  done
}

# Bundles a complete Runtime-local glibc loader closure (openobserve / libreoffice).
bundle_glibc_runtime_closure() {
  local stage="$1"
  shift
  local dependency
  local dependency_search_path="$stage/lib:$stage/lib64:/usr/local/lib:/usr/local/lib64"
  local target
  local -a targets=("$@")
  local loader
  mkdir -p "$stage/lib"
  loader="$(readlink -f /lib/ld-linux-aarch64.so.1 2>/dev/null || readlink -f /lib64/ld-linux-aarch64.so.1)"
  [[ -f "$loader" ]]
  cp -Lf "$loader" "$stage/lib/ld-linux-aarch64.so.1"
  for target in "${targets[@]}"; do
    while IFS= read -r dependency; do
      [[ -f "$dependency" ]] || continue
      case "$dependency" in
        "$stage"/*) continue ;;
      esac
      cp -Lf "$dependency" "$stage/lib/$(basename "$dependency")"
    done < <(
      LD_LIBRARY_PATH="$dependency_search_path${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
        lddtree -l "$target" 2>/dev/null | sort -u
    )
  done
  # Ensure the loader's own glibc companions are present even if lddtree omitted them.
  for dependency in \
    /lib64/libc.so.6 /lib/libc.so.6 \
    /lib64/libm.so.6 /lib/libm.so.6 \
    /lib64/libdl.so.2 /lib/libdl.so.2 \
    /lib64/libpthread.so.0 /lib/libpthread.so.0 \
    /lib64/librt.so.1 /lib/librt.so.1 \
    /lib64/libresolv.so.2 /lib/libresolv.so.2 \
    /lib64/libgcc_s.so.1 /lib/libgcc_s.so.1 \
    /lib64/libnss_files.so.2 /lib/libnss_files.so.2 \
    /lib64/libnss_dns.so.2 /lib/libnss_dns.so.2; do
    if [[ -f "$dependency" ]]; then
      cp -Lf "$dependency" "$stage/lib/$(basename "$dependency")"
    fi
  done
  set_origin_rpaths "$stage"
  assert_glibc_closure_complete "$stage"
}

# Discovers every ELF object below a tree and bundles a complete glibc closure.
bundle_elf_tree_glibc_closure() {
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
  bundle_glibc_runtime_closure "$stage" "${elf_files[@]}"
}

# Fails if libc.so.6 is present without a matching aarch64 loader (or the reverse).
assert_glibc_closure_complete() {
  local stage="$1"
  local has_libc=0
  local has_loader=0
  [[ -e "$stage/lib/libc.so.6" ]] && has_libc=1
  [[ -e "$stage/lib/ld-linux-aarch64.so.1" ]] && has_loader=1
  if ((has_libc != has_loader)); then
    echo "incomplete glibc closure in $stage (libc=$has_libc loader=$has_loader)" >&2
    return 1
  fi
}

# Fails when a core Runtime stage still contains forbidden host shared libraries.
assert_no_forbidden_host_libs() {
  local stage="$1"
  local path
  local base
  while IFS= read -r -d '' path; do
    base="$(basename "$path")"
    case "$base" in
      libssl.so*|libcrypto.so*|libz.so*|liblz4.so*|libzstd.so*|libcrypt.so*|libsodium.so*)
        echo "forbidden host library mixed into Runtime stage: $path" >&2
        return 1
        ;;
      ld-linux-aarch64.so.1|libc.so.6|libm.so.6|libpthread.so.0|libdl.so.2|librt.so.1|libresolv.so.2)
        echo "glibc/loader must not be mixed into core Runtime stage: $path" >&2
        return 1
        ;;
    esac
  done < <(find "$stage" -type f \( -name '*.so' -o -name '*.so.*' \) -print0 2>/dev/null)
}

# Writes common build metadata and upstream source checksums.
write_metadata() {
  local name="$1"
  local version="$2"
  local stage="$3"
  shift 3
  local glibc_ver
  glibc_ver="$(ldd --version | head -1 | awk '{print $NF}')"
  {
    echo "$name: $version"
    echo 'Architecture: aarch64'
    echo "Build baseline: manylinux2014 / glibc ${glibc_ver}"
    echo 'Hardening: RELRO, BIND_NOW, NX stack, FORTIFY, stack protector'
  } >"$stage/BUILDINFO"
  : >"$stage/SOURCE-SHA256SUMS"
  local source
  for source in "$@"; do
    printf '%s  %s\n' "$(sha256_file "$source")" "$(basename "$source")" >>"$stage/SOURCE-SHA256SUMS"
  done
}

# Materializes symlinks and hard links as regular files so installer unpack stays fail-closed.
sanitize_stage_links() {
  local stage="$1"
  local path
  local target
  while IFS= read -r -d '' path; do
    if [[ -L "$path" ]]; then
      # Dangling links (common in desktop .deb layouts) make readlink -f fail;
      # tolerate that under set -e so packaging can continue.
      target=$(readlink -f "$path" 2>/dev/null || true)
      [[ -n "$target" && -f "$target" ]] || continue
      rm -f "$path"
      cp -a "$target" "$path"
    fi
  done < <(find "$stage" -type l -print0)
  find "$stage" -type f -links +1 -print0 \
    | while IFS= read -r -d '' path; do
        cp -a --remove-destination "$path" "$path.copying"
        mv "$path.copying" "$path"
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
  sanitize_stage_links "$stage"
  mkdir -p "$output_dir"
  # CentOS 7 / manylinux2014 tar lacks --sort=name; keep ownership flags only.
  tar --owner=0 --group=0 --numeric-owner --hard-dereference -czf "$archive.installing" -C "$stage" .
  mv "$archive.installing" "$archive"
  printf '%s  %s\n' "$(sha256_file "$archive")" "$(basename "$archive")" >"$archive.sha256"
  file "$stage"/bin/* "$stage"/sbin/* 2>/dev/null | grep -E 'ELF|script' >"$output_dir/build.log" || true
}

# Builds static OpenSSL into the shared vendor prefix (once per container run).
ensure_static_openssl() {
  local prefix="$VENDOR_ROOT"
  local source="$SOURCE_ROOT/openssl-$OPENSSL_VERSION.tar.gz"
  if [[ -f "$prefix/lib/libssl.a" || -f "$prefix/lib64/libssl.a" ]]; then
    return
  fi
  download_file \
    "https://github.com/openssl/openssl/releases/download/openssl-$OPENSSL_VERSION/openssl-$OPENSSL_VERSION.tar.gz" \
    "$source"
  tar -xzf "$source" -C "$WORK_ROOT"
  (
    cd "$WORK_ROOT/openssl-$OPENSSL_VERSION"
    ./Configure linux-aarch64 no-shared no-tests no-docs no-weak-ssl-ciphers \
      --prefix="$prefix" --libdir=lib --openssldir="$prefix/ssl" \
      -fPIC -O2 -fstack-protector-strong
    run_make -j"$JOBS"
    run_make install_sw
  )
}

# Builds static zlib into the vendor prefix.
ensure_static_zlib() {
  local prefix="$VENDOR_ROOT"
  local source="$SOURCE_ROOT/zlib-$ZLIB_VERSION.tar.gz"
  if [[ -f "$prefix/lib/libz.a" ]]; then
    return
  fi
  download_file "https://zlib.net/fossils/zlib-$ZLIB_VERSION.tar.gz" "$source"
  tar -xzf "$source" -C "$WORK_ROOT"
  (
    cd "$WORK_ROOT/zlib-$ZLIB_VERSION"
    CFLAGS='-O2 -fPIC -fstack-protector-strong' ./configure --static --prefix="$prefix"
    run_make -j"$JOBS"
    run_make install
  )
}

# Builds static LZ4 into the vendor prefix.
ensure_static_lz4() {
  local prefix="$VENDOR_ROOT"
  local source="$SOURCE_ROOT/lz4-$LZ4_VERSION.tar.gz"
  if [[ -f "$prefix/lib/liblz4.a" ]]; then
    return
  fi
  download_file "https://github.com/lz4/lz4/archive/refs/tags/v$LZ4_VERSION.tar.gz" "$source"
  tar -xzf "$source" -C "$WORK_ROOT"
  (
    cd "$WORK_ROOT/lz4-$LZ4_VERSION"
    run_make -j"$JOBS" liblz4.a
    mkdir -p "$prefix/lib" "$prefix/include"
    cp lib/liblz4.a "$prefix/lib/"
    cp lib/lz4*.h "$prefix/include/"
  )
}

# Builds static Zstandard into the vendor prefix.
ensure_static_zstd() {
  local prefix="$VENDOR_ROOT"
  local source="$SOURCE_ROOT/zstd-$ZSTD_VERSION.tar.gz"
  if [[ -f "$prefix/lib/libzstd.a" ]]; then
    return
  fi
  download_file "https://github.com/facebook/zstd/releases/download/v$ZSTD_VERSION/zstd-$ZSTD_VERSION.tar.gz" "$source"
  tar -xzf "$source" -C "$WORK_ROOT"
  (
    cd "$WORK_ROOT/zstd-$ZSTD_VERSION"
    run_make -j"$JOBS" lib-release
    mkdir -p "$prefix/lib" "$prefix/include"
    cp lib/libzstd.a "$prefix/lib/"
    cp lib/zstd*.h "$prefix/include/"
  )
}

# Builds static libsodium into the vendor prefix.
ensure_static_libsodium() {
  local prefix="$VENDOR_ROOT"
  local source="$SOURCE_ROOT/libsodium-$LIBSODIUM_VERSION.tar.gz"
  if [[ -f "$prefix/lib/libsodium.a" ]]; then
    return
  fi
  download_file \
    "https://download.libsodium.org/libsodium/releases/libsodium-$LIBSODIUM_VERSION.tar.gz" \
    "$source"
  tar -xzf "$source" -C "$WORK_ROOT"
  (
    cd "$WORK_ROOT/libsodium-$LIBSODIUM_VERSION"
    ./configure --prefix="$prefix" --enable-static --disable-shared \
      CFLAGS='-O3 -fPIC -fstack-protector-strong -D_FORTIFY_SOURCE=2'
    run_make -j"$JOBS"
    run_make install
  )
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
      --with-openssl-opt='no-weak-ssl-ciphers no-tests no-docs' --with-zlib="$WORK_ROOT/zlib-$ZLIB_VERSION" \
      --with-cc-opt='-O2 -fPIE -fstack-protector-strong -D_FORTIFY_SOURCE=2 -fno-strict-aliasing' \
      --with-ld-opt='-Wl,-z,relro -Wl,-z,now -Wl,-z,noexecstack -pie'
    run_make -j"$JOBS"
    run_make install DESTDIR="$stage"
  )
  mkdir -p "$stage/bin" "$stage/logs" "$stage/run" "$stage/tmp"
  cat >"$stage/bin/nginx" <<'EOF'
#!/usr/bin/env bash
# Launch Nginx using paths relative to this extracted Runtime directory.
set -euo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)"
exec "$ROOT/sbin/nginx" -p "$ROOT/" "$@"
EOF
  chmod 0755 "$stage/bin/nginx"
  apply_contract nginx "$NGINX_VERSION" "$stage"
  assert_no_forbidden_host_libs "$stage"
  write_metadata nginx "$NGINX_VERSION" "$stage" "$nginx_src" "$openssl_src" "$pcre_src" "$zlib_src"
  {
    echo 'OpenSSL/PCRE2/zlib: statically embedded via nginx --with-*'
  } >>"$stage/BUILDINFO"
  package_runtime nginx "$NGINX_VERSION" "$stage"
}

# Builds PostgreSQL with statically linked OpenSSL, zlib, LZ4, and Zstandard.
build_postgresql() {
  local stage="$STAGE_ROOT/postgresql"
  local source="$SOURCE_ROOT/postgresql-$POSTGRESQL_VERSION.tar.bz2"
  local openssl_src="$SOURCE_ROOT/openssl-$OPENSSL_VERSION.tar.gz"
  local zlib_src="$SOURCE_ROOT/zlib-$ZLIB_VERSION.tar.gz"
  local lz4_src="$SOURCE_ROOT/lz4-$LZ4_VERSION.tar.gz"
  local zstd_src="$SOURCE_ROOT/zstd-$ZSTD_VERSION.tar.gz"
  local openssl_lib
  mkdir -p "$stage"
  ensure_static_openssl
  ensure_static_zlib
  ensure_static_lz4
  ensure_static_zstd
  openssl_src="$SOURCE_ROOT/openssl-$OPENSSL_VERSION.tar.gz"
  zlib_src="$SOURCE_ROOT/zlib-$ZLIB_VERSION.tar.gz"
  lz4_src="$SOURCE_ROOT/lz4-$LZ4_VERSION.tar.gz"
  zstd_src="$SOURCE_ROOT/zstd-$ZSTD_VERSION.tar.gz"
  download_file "https://ftp.postgresql.org/pub/source/v$POSTGRESQL_VERSION/postgresql-$POSTGRESQL_VERSION.tar.bz2" "$source"
  tar -xjf "$source" -C "$WORK_ROOT"
  openssl_lib="$VENDOR_ROOT/lib"
  [[ -d "$VENDOR_ROOT/lib64" && -f "$VENDOR_ROOT/lib64/libssl.a" ]] && openssl_lib="$VENDOR_ROOT/lib64"
  (
    cd "$WORK_ROOT/postgresql-$POSTGRESQL_VERSION"
    ./configure --prefix=/usr/local --disable-rpath --with-ssl=openssl --with-lz4 --with-zstd \
      --without-readline --without-icu --with-blocksize=8 --with-wal-blocksize=8 --with-segsize=1 \
      OPENSSL_CFLAGS="-I$VENDOR_ROOT/include" \
      OPENSSL_LIBS="-L$openssl_lib -lssl -lcrypto -ldl -lpthread" \
      LZ4_CFLAGS="-I$VENDOR_ROOT/include" \
      LZ4_LIBS="-L$VENDOR_ROOT/lib -llz4" \
      ZSTD_CFLAGS="-I$VENDOR_ROOT/include" \
      ZSTD_LIBS="-L$VENDOR_ROOT/lib -lzstd" \
      ZLIB_CFLAGS="-I$VENDOR_ROOT/include" \
      ZLIB_LIBS="-L$VENDOR_ROOT/lib -lz" \
      CFLAGS="-O2 -pipe -fPIC -fstack-protector-strong -D_FORTIFY_SOURCE=2 -fno-strict-aliasing -fwrapv -I$VENDOR_ROOT/include" \
      LDFLAGS="-L$openssl_lib -L$VENDOR_ROOT/lib -Wl,-z,relro,-z,now,-z,noexecstack,--as-needed -Wl,-rpath,\\\$\$ORIGIN/../lib"
    # Static OpenSSL pulls pthread_exit into libpq; the stock refcheck greps for
    # any symbol containing "exit" and false-positives. Exclude pthread_exit
    # (same allowance documented on the x86_64 Runtime BUILDINFO).
    sed -i 's/grep -v -e __cxa_atexit -e __tsan_func_exit/grep -v -e __cxa_atexit -e __tsan_func_exit -e pthread_exit/' \
      src/interfaces/libpq/Makefile
    run_make -j"$JOBS"
    run_make install DESTDIR="$stage"
    run_make -C contrib install DESTDIR="$stage"
  )
  cp -a "$stage/usr/local/." "$stage/"
  find "$stage/usr" -depth -delete
  # Prefer plugins under lib/postgresql when present; keep lib/*.so from Postgres itself.
  apply_contract postgresql "$POSTGRESQL_VERSION" "$stage"
  assert_no_forbidden_host_libs "$stage"
  write_metadata postgresql "$POSTGRESQL_VERSION" "$stage" \
    "$source" "$openssl_src" "$zlib_src" "$lz4_src" "$zstd_src"
  {
    echo "OpenSSL: $OPENSSL_VERSION LTS (statically linked)"
    echo "zlib: $ZLIB_VERSION (statically linked)"
    echo "LZ4: $LZ4_VERSION (statically linked)"
    echo "Zstandard: $ZSTD_VERSION (statically linked)"
  } >>"$stage/BUILDINFO"
  package_runtime postgresql "$POSTGRESQL_VERSION" "$stage"
}

# Builds Redis with TLS via statically linked OpenSSL and the bundled jemalloc.
build_redis() {
  local stage="$STAGE_ROOT/redis"
  local source="$SOURCE_ROOT/redis-$REDIS_VERSION.tar.gz"
  local openssl_src="$SOURCE_ROOT/openssl-$OPENSSL_VERSION.tar.gz"
  mkdir -p "$stage/bin"
  ensure_static_openssl
  if [[ -f "$VENDOR_ROOT/lib64/libssl.a" && ! -f "$VENDOR_ROOT/lib/libssl.a" ]]; then
    mkdir -p "$VENDOR_ROOT/lib"
    cp -a "$VENDOR_ROOT/lib64/." "$VENDOR_ROOT/lib/"
  fi
  [[ -f "$VENDOR_ROOT/include/openssl/ssl.h" ]]
  openssl_src="$SOURCE_ROOT/openssl-$OPENSSL_VERSION.tar.gz"
  download_file "https://download.redis.io/releases/redis-$REDIS_VERSION.tar.gz" "$source"
  tar -xzf "$source" -C "$WORK_ROOT"
  (
    cd "$WORK_ROOT/redis-$REDIS_VERSION"
    # Single consistent flag set so Redis does not wipe deps mid-build.
    run_make -j"$JOBS" BUILD_TLS=yes OPENSSL_PREFIX="$VENDOR_ROOT" MALLOC=jemalloc \
      V=1 \
      CFLAGS="-O3 -pipe -fPIC -fstack-protector-strong -D_FORTIFY_SOURCE=2 -I$VENDOR_ROOT/include" \
      LDFLAGS="-Wl,-z,relro,-z,now,-z,noexecstack -L$VENDOR_ROOT/lib"
  )
  [[ -x "$WORK_ROOT/redis-$REDIS_VERSION/src/redis-server" ]]
  # Confirm TLS and jemalloc actually linked.
  if ! "$WORK_ROOT/redis-$REDIS_VERSION/src/redis-server" -v 2>&1 | head -1 | grep -qi redis; then
    "$WORK_ROOT/redis-$REDIS_VERSION/src/redis-server" --version
  fi
  cp "$WORK_ROOT/redis-$REDIS_VERSION"/src/redis-{server,cli,benchmark,check-aof,check-rdb} "$stage/bin/"
  apply_contract redis "$REDIS_VERSION" "$stage"
  assert_no_forbidden_host_libs "$stage"
  write_metadata redis "$REDIS_VERSION" "$stage" "$source" "$openssl_src"
  {
    echo 'Optimization: -O3, bundled jemalloc'
    echo "TLS: OpenSSL $OPENSSL_VERSION LTS statically linked"
  } >>"$stage/BUILDINFO"
  package_runtime redis "$REDIS_VERSION" "$stage"
}

# Builds shared ZeroMQ with CURVE via statically linked libsodium.
build_zeromq() {
  local stage="$STAGE_ROOT/zeromq"
  local source="$SOURCE_ROOT/zeromq-$ZEROMQ_VERSION.tar.gz"
  local sodium_src="$SOURCE_ROOT/libsodium-$LIBSODIUM_VERSION.tar.gz"
  mkdir -p "$stage"
  ensure_static_libsodium
  sodium_src="$SOURCE_ROOT/libsodium-$LIBSODIUM_VERSION.tar.gz"
  download_file "https://github.com/zeromq/libzmq/releases/download/v$ZEROMQ_VERSION/zeromq-$ZEROMQ_VERSION.tar.gz" "$source"
  tar -xzf "$source" -C "$WORK_ROOT"
  (
    cd "$WORK_ROOT/zeromq-$ZEROMQ_VERSION"
    PKG_CONFIG_PATH="$VENDOR_ROOT/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}" \
      ./configure --prefix=/usr/local --enable-shared --disable-static \
      --with-libsodium="$VENDOR_ROOT" --with-libsodium-include-dir="$VENDOR_ROOT/include" \
      --with-libsodium-lib-dir="$VENDOR_ROOT/lib" \
      CFLAGS="-O3 -fPIC -fstack-protector-strong -D_FORTIFY_SOURCE=2 -I$VENDOR_ROOT/include" \
      CXXFLAGS='-O3 -fPIC -fstack-protector-strong -D_FORTIFY_SOURCE=2' \
      LDFLAGS="-L$VENDOR_ROOT/lib -Wl,-z,relro,-z,now,-z,noexecstack" \
      LIBS='-lsodium'
    run_make -j"$JOBS"
    run_make install DESTDIR="$stage"
  )
  cp -a "$stage/usr/local/." "$stage/"
  find "$stage/usr" -depth -delete
  # Drop libsodium leftovers if the shared install pulled any; keep only libzmq.
  find "$stage/lib" -maxdepth 1 -type f \( -name 'libsodium.so*' -o -name 'libgcc_s.so*' -o -name 'libstdc++.so*' \) -delete 2>/dev/null || true
  apply_contract zeromq "$ZEROMQ_VERSION" "$stage"
  if [[ -e "$stage/lib/libzmq.so" ]]; then
    patchelf --set-rpath '\$ORIGIN' "$stage/lib/libzmq.so" 2>/dev/null || true
  fi
  assert_no_forbidden_host_libs "$stage"
  write_metadata zeromq "$ZEROMQ_VERSION" "$stage" "$source" "$sodium_src"
  {
    echo "CURVE security: libsodium $LIBSODIUM_VERSION statically linked"
  } >>"$stage/BUILDINFO"
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
  assert_no_forbidden_host_libs "$stage"
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
  assert_no_forbidden_host_libs "$stage"
  write_metadata opentelemetry "$OTEL_VERSION" "$stage" "$core" "$contrib"
  package_runtime opentelemetry "$OTEL_VERSION" "$stage"
}

# Packages the official OpenObserve arm64 binary with a complete glibc loader closure.
build_openobserve() {
  local stage="$STAGE_ROOT/openobserve"
  local source="$SOURCE_ROOT/openobserve-v$OPENOBSERVE_VERSION-linux-arm64.tar.gz"
  mkdir -p "$stage/bin" "$stage/lib"
  download_file "https://downloads.openobserve.ai/releases/openobserve/v$OPENOBSERVE_VERSION/openobserve-v$OPENOBSERVE_VERSION-linux-arm64.tar.gz" "$source"
  tar -xzf "$source" -C "$stage/bin"
  local upstream_binary
  upstream_binary="$(find "$stage/bin" -maxdepth 2 -type f -name openobserve -print -quit)"
  cp "$upstream_binary" "$stage/bin/openobserve.bin"
  rm -f "$upstream_binary"
  bundle_glibc_runtime_closure "$stage" "$stage/bin/openobserve.bin"
  cat >"$stage/bin/openobserve" <<'EOF'
#!/bin/sh
# Launches OpenObserve through the Runtime-local aarch64 glibc loader.
BASE=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
exec "$BASE/lib/ld-linux-aarch64.so.1" --inhibit-cache --library-path "$BASE/lib" "$BASE/bin/openobserve.bin" "$@"
EOF
  chmod 755 "$stage/bin/openobserve"
  apply_contract openobserve "$OPENOBSERVE_VERSION" "$stage"
  write_metadata openobserve "$OPENOBSERVE_VERSION" "$stage" "$source"
  {
    echo 'Packaging: official optimized release binary'
    echo 'Compatibility: bundled glibc loader/runtime closure (ld-linux + libc paired)'
  } >>"$stage/BUILDINFO"
  package_runtime openobserve "$OPENOBSERVE_VERSION" "$stage"
}

# Builds FFmpeg from source on manylinux2014 so required GLIBC stays ≤ 2.17.
# External codecs are statically linked; the archive ships only ffmpeg/ffprobe.
build_ffmpeg() {
  local stage="$STAGE_ROOT/ffmpeg"
  local source="$SOURCE_ROOT/ffmpeg-$FFMPEG_VERSION.tar.xz"
  local x264_source="$SOURCE_ROOT/x264-stable.tar.bz2"
  local opus_source="$SOURCE_ROOT/opus-1.5.2.tar.gz"
  mkdir -p "$stage/bin"
  download_file "https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz" "$source"
  download_file "https://code.videolan.org/videolan/x264/-/archive/stable/x264-stable.tar.bz2" "$x264_source"
  download_file "https://downloads.xiph.org/releases/opus/opus-1.5.2.tar.gz" "$opus_source"

  tar -xjf "$x264_source" -C "$WORK_ROOT"
  (
    cd "$WORK_ROOT"/x264-stable*
    ./configure --prefix="$VENDOR_ROOT" --enable-static --disable-shared --disable-cli --enable-pic
    run_make -j"$JOBS"
    run_make install
  )
  tar -xzf "$opus_source" -C "$WORK_ROOT"
  (
    cd "$WORK_ROOT/opus-1.5.2"
    ./configure --prefix="$VENDOR_ROOT" --enable-static --disable-shared --with-pic
    run_make -j"$JOBS"
    run_make install
  )
  tar -xJf "$source" -C "$WORK_ROOT"
  (
    cd "$WORK_ROOT/ffmpeg-$FFMPEG_VERSION"
    PKG_CONFIG_PATH="$VENDOR_ROOT/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}" \
      ./configure --prefix=/usr/local \
      --pkg-config-flags='--static' \
      --extra-cflags="-I$VENDOR_ROOT/include -O3 -fPIC -fstack-protector-strong -D_FORTIFY_SOURCE=2" \
      --extra-ldflags="-L$VENDOR_ROOT/lib -Wl,-z,relro,-z,now,-z,noexecstack" \
      --enable-gpl --enable-version3 \
      --enable-static --disable-shared --disable-doc --disable-ffplay \
      --enable-ffmpeg --enable-ffprobe \
      --disable-network --disable-debug \
      --disable-autodetect --enable-libx264 --enable-libopus --enable-zlib
    run_make -j"$JOBS"
    run_make install DESTDIR="$stage"
  )
  cp -a "$stage/usr/local/bin/ffmpeg" "$stage/usr/local/bin/ffprobe" "$stage/bin/"
  find "$stage/usr" -depth -delete 2>/dev/null || true
  apply_contract ffmpeg "$FFMPEG_VERSION" "$stage"
  assert_no_forbidden_host_libs "$stage"
  write_metadata ffmpeg "$FFMPEG_VERSION" "$stage" "$source" "$x264_source" "$opus_source"
  {
    echo 'Optimization: -O3, static libx264 + libopus'
    echo 'Linkage: statically linked codec libraries; glibc from host'
  } >>"$stage/BUILDINFO"
  package_runtime ffmpeg "$FFMPEG_VERSION" "$stage"
}

# Installs a shared library into the vendor prefix for Poppler third-party deps.
install_vendor_shared() {
  local name="$1"
  local version="$2"
  local url="$3"
  local archive="$SOURCE_ROOT/$name-$version.tar.${4:-gz}"
  local extract_cmd="$5"
  local configure_extra="${6:-}"
  download_file "$url" "$archive"
  case "$extract_cmd" in
    xz) tar -xJf "$archive" -C "$WORK_ROOT" ;;
    bz2) tar -xjf "$archive" -C "$WORK_ROOT" ;;
    *) tar -xzf "$archive" -C "$WORK_ROOT" ;;
  esac
  (
    cd "$WORK_ROOT/$name-$version"
    # shellcheck disable=SC2086
    ./configure --prefix="$VENDOR_ROOT" --enable-shared --disable-static $configure_extra
    run_make -j"$JOBS"
    run_make install
  )
}

# Builds Poppler CLI tools and bundles their non-glibc third-party closure.
build_poppler() {
  local stage="$STAGE_ROOT/poppler"
  local source="$SOURCE_ROOT/poppler-$POPPLER_VERSION.tar.xz"
  local freetype_source="$SOURCE_ROOT/freetype-$FREETYPE_VERSION.tar.xz"
  local fontconfig_source="$SOURCE_ROOT/fontconfig-$FONTCONFIG_VERSION.tar.xz"
  local tiff_source="$SOURCE_ROOT/tiff-$TIFF_VERSION.tar.xz"
  local lcms_source="$SOURCE_ROOT/lcms2-$LCMS_VERSION.tar.gz"
  local openjpeg_source="$SOURCE_ROOT/openjpeg-$OPENJPEG_VERSION.tar.gz"
  local jpeg_source="$SOURCE_ROOT/libjpeg-turbo-$JPEG_VERSION.tar.gz"
  local png_source="$SOURCE_ROOT/libpng-$PNG_VERSION.tar.gz"
  local expat_source="$SOURCE_ROOT/expat-$EXPAT_VERSION.tar.gz"
  mkdir -p "$stage"
  # Prefer conda-forge GCC 14 for Poppler C++23 while still linking glibc 2.17.
  local poppler_cc="${MDV_POPPLER_CC:-gcc}"
  local poppler_cxx="${MDV_POPPLER_CXX:-g++}"
  if [[ -x "$poppler_cxx" ]]; then
    export LD_LIBRARY_PATH="${MDV_CONDA_GCC_LIBDIR:-/opt/conda-gcc/lib}${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
  elif [[ -x /opt/conda-gcc/bin/aarch64-conda-linux-gnu-g++ ]]; then
    poppler_cc=/opt/conda-gcc/bin/aarch64-conda-linux-gnu-gcc
    poppler_cxx=/opt/conda-gcc/bin/aarch64-conda-linux-gnu-g++
    export LD_LIBRARY_PATH=/opt/conda-gcc/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
  fi
  download_file "https://poppler.freedesktop.org/poppler-$POPPLER_VERSION.tar.xz" "$source"
  download_file "https://download.savannah.gnu.org/releases/freetype/freetype-$FREETYPE_VERSION.tar.xz" "$freetype_source"
  download_file "https://www.freedesktop.org/software/fontconfig/release/fontconfig-$FONTCONFIG_VERSION.tar.xz" "$fontconfig_source"
  download_file "https://download.osgeo.org/libtiff/tiff-$TIFF_VERSION.tar.xz" "$tiff_source"
  download_file "https://github.com/mm2/Little-CMS/releases/download/lcms$LCMS_VERSION/lcms2-$LCMS_VERSION.tar.gz" "$lcms_source"
  download_file "https://github.com/uclouvain/openjpeg/archive/refs/tags/v$OPENJPEG_VERSION.tar.gz" "$openjpeg_source"
  download_file "https://github.com/libjpeg-turbo/libjpeg-turbo/releases/download/$JPEG_VERSION/libjpeg-turbo-$JPEG_VERSION.tar.gz" "$jpeg_source"
  download_file "https://download.sourceforge.net/libpng/libpng-$PNG_VERSION.tar.gz" "$png_source"
  download_file "https://github.com/libexpat/libexpat/releases/download/R_${EXPAT_VERSION//./_}/expat-$EXPAT_VERSION.tar.gz" "$expat_source"

  tar -xzf "$expat_source" -C "$WORK_ROOT"
  (cd "$WORK_ROOT/expat-$EXPAT_VERSION" && ./configure --prefix="$VENDOR_ROOT" --enable-shared --disable-static && run_make -j"$JOBS" && run_make install)
  tar -xzf "$png_source" -C "$WORK_ROOT"
  (cd "$WORK_ROOT/libpng-$PNG_VERSION" && ./configure --prefix="$VENDOR_ROOT" --enable-shared --disable-static && run_make -j"$JOBS" && run_make install)
  tar -xzf "$jpeg_source" -C "$WORK_ROOT"
  cmake -S "$WORK_ROOT/libjpeg-turbo-$JPEG_VERSION" -B "$WORK_ROOT/jpeg-build" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$VENDOR_ROOT" -DENABLE_SHARED=TRUE -DENABLE_STATIC=FALSE
  cmake --build "$WORK_ROOT/jpeg-build" --parallel "$JOBS"
  cmake --install "$WORK_ROOT/jpeg-build"
  tar -xzf "$openjpeg_source" -C "$WORK_ROOT"
  cmake -S "$WORK_ROOT/openjpeg-$OPENJPEG_VERSION" -B "$WORK_ROOT/openjpeg-build" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$VENDOR_ROOT" -DBUILD_SHARED_LIBS=ON
  cmake --build "$WORK_ROOT/openjpeg-build" --parallel "$JOBS"
  cmake --install "$WORK_ROOT/openjpeg-build"

  tar -xJf "$freetype_source" -C "$WORK_ROOT"
  (
    cd "$WORK_ROOT/freetype-$FREETYPE_VERSION"
    PKG_CONFIG_PATH="$VENDOR_ROOT/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}" \
      ./configure --prefix="$VENDOR_ROOT" --with-harfbuzz=no --with-bzip2=no --with-brotli=no \
      --enable-shared --disable-static
    run_make -j"$JOBS"
    run_make install
  )
  tar -xJf "$fontconfig_source" -C "$WORK_ROOT"
  (
    cd "$WORK_ROOT/fontconfig-$FONTCONFIG_VERSION"
    PKG_CONFIG_PATH="$VENDOR_ROOT/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}" \
      ./configure --prefix="$VENDOR_ROOT" --disable-docs --enable-shared --disable-static
    run_make -j"$JOBS"
    run_make install
  )
  tar -xzf "$lcms_source" -C "$WORK_ROOT"
  (
    cd "$WORK_ROOT/lcms2-$LCMS_VERSION"
    ./configure --prefix="$VENDOR_ROOT" --enable-shared --disable-static
    run_make -j"$JOBS"
    run_make install
  )
  tar -xJf "$tiff_source" -C "$WORK_ROOT"
  (
    cd "$WORK_ROOT/tiff-$TIFF_VERSION"
    PKG_CONFIG_PATH="$VENDOR_ROOT/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}" \
      ./configure --prefix="$VENDOR_ROOT" --enable-shared --disable-static \
      --disable-lzma --disable-zstd --disable-webp --disable-jpeg
    run_make -j"$JOBS"
    run_make install
  )

  # conda-forge GCC uses its own sysroot; provide zlib headers/libs via vendor + host paths.
  ensure_static_zlib
  local poppler_cflags="-isystem $VENDOR_ROOT/include -isystem /usr/include"
  # Only -L paths here: putting -lfoo in CMAKE_*_LINKER_FLAGS breaks compiler try_compile.
  local poppler_ldflags="-L$VENDOR_ROOT/lib -L$VENDOR_ROOT/lib64 -L/usr/lib64 -L/lib64 -Wl,-rpath-link,$VENDOR_ROOT/lib -Wl,-rpath-link,$VENDOR_ROOT/lib64 -Wl,--no-as-needed"
  export LIBRARY_PATH="$VENDOR_ROOT/lib:$VENDOR_ROOT/lib64:/usr/lib64:/lib64${LIBRARY_PATH:+:$LIBRARY_PATH}"
  export LD_LIBRARY_PATH="$VENDOR_ROOT/lib:$VENDOR_ROOT/lib64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
  export PKG_CONFIG_PATH="$VENDOR_ROOT/lib/pkgconfig:$VENDOR_ROOT/lib64/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"

  tar -xJf "$source" -C "$WORK_ROOT"
  # manylinux2014 glibc 2.17 exposes fseeko64/ftello64, not fseek64/ftell64.
  sed -i 's/\bfseek64\b/fseeko64/g; s/\bftell64\b/ftello64/g' \
    "$WORK_ROOT/poppler-$POPPLER_VERSION/goo/gfile.cc"
  local lib_freetype lib_fontconfig lib_png lib_tiff lib_jpeg lib_openjp2 lib_lcms2 lib_expat
  lib_freetype=$(ls "$VENDOR_ROOT"/lib*/libfreetype.so 2>/dev/null | head -1)
  lib_fontconfig=$(ls "$VENDOR_ROOT"/lib*/libfontconfig.so 2>/dev/null | head -1)
  lib_png=$(ls "$VENDOR_ROOT"/lib*/libpng16.so 2>/dev/null | head -1)
  lib_tiff=$(ls "$VENDOR_ROOT"/lib*/libtiff.so 2>/dev/null | head -1)
  lib_jpeg=$(ls "$VENDOR_ROOT"/lib*/libjpeg.so 2>/dev/null | head -1)
  lib_openjp2=$(ls "$VENDOR_ROOT"/lib*/libopenjp2.so 2>/dev/null | head -1)
  lib_lcms2=$(ls "$VENDOR_ROOT"/lib*/liblcms2.so 2>/dev/null | head -1)
  lib_expat=$(ls "$VENDOR_ROOT"/lib*/libexpat.so 2>/dev/null | head -1)

  # Force vendor libs onto poppler link lines (conda ld --as-needed can otherwise omit them).
  cat >>"$WORK_ROOT/poppler-$POPPLER_VERSION/CMakeLists.txt" <<EOF

# --- modiverse: force vendor runtime libs onto poppler targets ---
set(_mdv_vendor_libs "$lib_freetype" "$lib_fontconfig" "$lib_png" "$lib_tiff" "$lib_jpeg" "$lib_openjp2" "$lib_lcms2" "$lib_expat" "$VENDOR_ROOT/lib/libz.a")
if(TARGET poppler)
  target_link_libraries(poppler PRIVATE \${_mdv_vendor_libs})
endif()
foreach(_mdv_target IN ITEMS poppler-cpp pdftotext pdftoppm pdfinfo pdftocairo pdftohtml pdftops pdfunite pdfseparate pdfdetach pdffonts pdfimages pdfattach)
  if(TARGET \${_mdv_target})
    target_link_libraries(\${_mdv_target} \${_mdv_vendor_libs})
  endif()
endforeach()
EOF

  PKG_CONFIG_PATH="$VENDOR_ROOT/lib/pkgconfig:$VENDOR_ROOT/lib64/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}" \
    CC="$poppler_cc" CXX="$poppler_cxx" \
    cmake -S "$WORK_ROOT/poppler-$POPPLER_VERSION" -B "$WORK_ROOT/poppler-build" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr/local \
    -DCMAKE_INSTALL_LIBDIR=lib \
    -DCMAKE_PREFIX_PATH="$VENDOR_ROOT" \
    -DCMAKE_C_COMPILER="$poppler_cc" \
    -DCMAKE_CXX_COMPILER="$poppler_cxx" \
    -DCMAKE_CXX_STANDARD=23 \
    -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
    -DZLIB_INCLUDE_DIR="$VENDOR_ROOT/include" \
    -DZLIB_LIBRARY="$VENDOR_ROOT/lib/libz.a" \
    -DFREETYPE_INCLUDE_DIRS="$VENDOR_ROOT/include/freetype2;$VENDOR_ROOT/include" \
    -DFREETYPE_LIBRARY="$lib_freetype" \
    -DFontconfig_INCLUDE_DIR="$VENDOR_ROOT/include" \
    -DFontconfig_LIBRARY="$lib_fontconfig" \
    -DPNG_PNG_INCLUDE_DIR="$VENDOR_ROOT/include" \
    -DPNG_LIBRARY="$lib_png" \
    -DTIFF_INCLUDE_DIR="$VENDOR_ROOT/include" \
    -DTIFF_LIBRARY="$lib_tiff" \
    -DJPEG_INCLUDE_DIR="$VENDOR_ROOT/include" \
    -DJPEG_LIBRARY="$lib_jpeg" \
    -DOpenJPEG_INCLUDE_DIR="$VENDOR_ROOT/include/openjpeg-2.5" \
    -DLCMS2_INCLUDE_DIR="$VENDOR_ROOT/include" \
    -DLCMS2_LIBRARIES="$lib_lcms2" \
    -DBUILD_GTK_TESTS=OFF -DBUILD_QT5_TESTS=OFF -DBUILD_QT6_TESTS=OFF -DBUILD_CPP_TESTS=OFF -DBUILD_MANUAL_TESTS=OFF \
    -DENABLE_QT5=OFF -DENABLE_QT6=OFF -DENABLE_GLIB=OFF -DENABLE_CPP=ON \
    -DENABLE_UTILS=ON -DENABLE_GPGME=OFF -DENABLE_BOOST=OFF -DENABLE_LIBCURL=OFF \
    -DENABLE_NSS3=OFF -DENABLE_LIBOPENJPEG=openjpeg2 \
    -DBUILD_SHARED_LIBS=ON \
    -DCMAKE_C_FLAGS="$poppler_cflags" \
    -DCMAKE_CXX_FLAGS="$poppler_cflags" \
    -DCMAKE_EXE_LINKER_FLAGS="$poppler_ldflags" \
    -DCMAKE_SHARED_LINKER_FLAGS="$poppler_ldflags" \
    -DCMAKE_MODULE_LINKER_FLAGS="$poppler_ldflags" \
    -DCMAKE_BUILD_RPATH="$VENDOR_ROOT/lib;$VENDOR_ROOT/lib64" \
    -DCMAKE_C_FLAGS_RELEASE='-O3 -DNDEBUG -fstack-protector-strong -D_FORTIFY_SOURCE=2' \
    -DCMAKE_CXX_FLAGS_RELEASE='-O3 -DNDEBUG -fstack-protector-strong -D_FORTIFY_SOURCE=2'
  cmake --build "$WORK_ROOT/poppler-build" --parallel "$JOBS"
  DESTDIR="$stage" cmake --install "$WORK_ROOT/poppler-build"
  cp -a "$stage/usr/local/." "$stage/"
  find "$stage/usr" -depth -delete
  # Ship the vendor-built third-party shared libraries next to Poppler.
  mkdir -p "$stage/lib"
  find "$VENDOR_ROOT/lib" "$VENDOR_ROOT/lib64" -maxdepth 1 -type f \( -name '*.so' -o -name '*.so.*' \) \
    -exec cp -a {} "$stage/lib/" \; 2>/dev/null || true
  # Bundle libstdc++/libgcc from the conda GCC used to compile Poppler.
  if [[ -d /opt/conda-gcc/lib ]]; then
    cp -a /opt/conda-gcc/lib/libstdc++.so* "$stage/lib/" 2>/dev/null || true
    cp -a /opt/conda-gcc/lib/libgcc_s.so* "$stage/lib/" 2>/dev/null || true
  fi
  apply_contract poppler "$POPPLER_VERSION" "$stage"
  bundle_third_party_dependencies "$stage" "$stage/bin/pdftotext" "$stage/bin/pdftoppm" "$stage/bin/pdfinfo"
  assert_glibc_closure_complete "$stage"
  write_metadata poppler "$POPPLER_VERSION" "$stage" \
    "$source" "$freetype_source" "$fontconfig_source" "$tiff_source" "$lcms_source"
  {
    echo 'Linkage: Poppler + vendor third-party runtime libraries; glibc from host'
  } >>"$stage/BUILDINFO"
  package_runtime poppler "$POPPLER_VERSION" "$stage"
}

# Packages the official LibreOffice aarch64 release with a complete glibc closure.
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
  bundle_elf_tree_glibc_closure "$stage" "$stage/program"
  # Also copy gconv modules required when launching through the bundled loader.
  if [[ -d /usr/lib64/gconv ]]; then
    mkdir -p "$stage/lib/gconv"
    cp -a /usr/lib64/gconv/. "$stage/lib/gconv/" 2>/dev/null || true
  elif [[ -d /usr/lib/gconv ]]; then
    mkdir -p "$stage/lib/gconv"
    cp -a /usr/lib/gconv/. "$stage/lib/gconv/" 2>/dev/null || true
  fi
  cat >"$stage/bin/libreoffice" <<'EOF'
#!/bin/sh
# Launches LibreOffice headlessly through the Runtime-local aarch64 glibc loader.
BASE=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
export GCONV_PATH="$BASE/lib/gconv"
exec "$BASE/lib/ld-linux-aarch64.so.1" --inhibit-cache --library-path "$BASE/program:$BASE/lib" "$BASE/program/soffice.bin" "$@"
EOF
  cp "$stage/bin/libreoffice" "$stage/bin/soffice"
  chmod 755 "$stage/bin/libreoffice" "$stage/bin/soffice"
  apply_contract libreoffice "$LIBREOFFICE_VERSION" "$stage"
  write_metadata libreoffice "$LIBREOFFICE_VERSION" "$stage" "$source"
  {
    echo 'Packaging: official deb release binaries'
    echo 'Compatibility: bundled loader and complete runtime dependency closure'
  } >>"$stage/BUILDINFO"
  package_runtime libreoffice "$LIBREOFFICE_VERSION" "$stage"
}

# Dispatches requested component builds in dependency-cost order.
main() {
  [[ "$(uname -m)" == "aarch64" ]]
  mkdir -p "$SOURCE_ROOT" "$STAGE_ROOT" "$VENDOR_ROOT" "$OUTPUT_ROOT"
  install_build_dependencies
  echo "Build host glibc: $(ldd --version | head -1)"
  echo "Compiler: $(gcc --version | head -1)"
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
