#!/bin/bash
# Modiverse Nginx Runtime — performance / security / fast-load / portable
set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

ROOT=/opt/modiverse
BUILD="$ROOT/build"
LOG="$BUILD/build-nginx.log"
NPROC=$(nproc)
NGINX_VER=1.28.3
OPENSSL_VER=3.6.3
PCRE2_VER=10.44
ZLIB_VER=1.3.1

mkdir -p "$BUILD"
exec > >(tee -a "$LOG") 2>&1

echo "=== Modiverse Nginx Runtime build @ $(date -Is) on $(hostname) ==="

dnf install -y gcc gcc-c++ make perl-core perl patch which binutils 2>&1 | tail -20

mkdir -p "$ROOT"/{runtime,bin,apps,config/nginx,data,logs/nginx,services,backup,tmp,packages/{nginx,tools}}
mkdir -p "$ROOT/runtime"/{nginx/packages,openssl,pcre2,zlib}

if [[ ! -x "$ROOT/runtime/nginx/$NGINX_VER/sbin/nginx" ]]; then
  # keep this script; wipe other build artifacts
  find "$BUILD" -mindepth 1 -maxdepth 1 ! -name 'build-nginx-runtime.sh' ! -name 'build-nginx.log' -exec rm -rf {} +
fi

cd "$BUILD"

# Extract: install trees + pristine -src for nginx static embed
tar xzf /opt/soft/nginx/nginx-${NGINX_VER}.tar.gz
tar xzf /opt/lib/zlib-${ZLIB_VER}.tar.gz
rm -rf "zlib-${ZLIB_VER}-src"
cp -a "zlib-${ZLIB_VER}" "zlib-${ZLIB_VER}-src"
tar xzf /opt/lib/pcre2-${PCRE2_VER}.tar.gz
rm -rf "pcre2-${PCRE2_VER}-src"
cp -a "pcre2-${PCRE2_VER}" "pcre2-${PCRE2_VER}-src"
tar xzf /opt/lib/openssl-${OPENSSL_VER}.tar.gz
rm -rf "openssl-${OPENSSL_VER}-src"
cp -a "openssl-${OPENSSL_VER}" "openssl-${OPENSSL_VER}-src"

SEC_CFLAGS="-O2 -fPIC -fstack-protector-strong -D_FORTIFY_SOURCE=2"

# --- zlib ---
echo "=== build zlib ${ZLIB_VER} ==="
cd "$BUILD/zlib-${ZLIB_VER}"
make distclean 2>/dev/null || true
CFLAGS="$SEC_CFLAGS" ./configure --prefix="$ROOT/runtime/zlib/${ZLIB_VER}"
make -j"$NPROC"
make install
ln -sfn "${ZLIB_VER}" "$ROOT/runtime/zlib/current"

# --- pcre2 ---
echo "=== build pcre2 ${PCRE2_VER} ==="
cd "$BUILD/pcre2-${PCRE2_VER}"
make distclean 2>/dev/null || true
./configure --prefix="$ROOT/runtime/pcre2/${PCRE2_VER}" \
  --enable-shared --enable-static --enable-jit --enable-unicode-properties \
  CFLAGS="$SEC_CFLAGS"
make -j"$NPROC"
make install
ln -sfn "${PCRE2_VER}" "$ROOT/runtime/pcre2/current"

# --- openssl (shared install for other runtimes) ---
echo "=== build openssl ${OPENSSL_VER} ==="
cd "$BUILD/openssl-${OPENSSL_VER}"
make distclean 2>/dev/null || true
OPENSSL_NGINX_OPT='no-weak-ssl-ciphers enable-ec_nistp_64_gcc_128'
set +e
./config --prefix="$ROOT/runtime/openssl/${OPENSSL_VER}" \
  --openssldir="$ROOT/runtime/openssl/${OPENSSL_VER}/ssl" \
  shared zlib no-weak-ssl-ciphers enable-ec_nistp_64_gcc_128 \
  -O2 -fPIC -fstack-protector-strong -Wl,-z,relro,-z,now \
  --with-zlib-include="$ROOT/runtime/zlib/${ZLIB_VER}/include" \
  --with-zlib-lib="$ROOT/runtime/zlib/${ZLIB_VER}/lib"
CFG_RC=$?
set -e
if [[ $CFG_RC -ne 0 ]]; then
  echo "WARN: openssl config without enable-ec_nistp_64_gcc_128"
  OPENSSL_NGINX_OPT='no-weak-ssl-ciphers'
  ./config --prefix="$ROOT/runtime/openssl/${OPENSSL_VER}" \
    --openssldir="$ROOT/runtime/openssl/${OPENSSL_VER}/ssl" \
    shared zlib no-weak-ssl-ciphers \
    -O2 -fPIC -fstack-protector-strong -Wl,-z,relro,-z,now \
    --with-zlib-include="$ROOT/runtime/zlib/${ZLIB_VER}/include" \
    --with-zlib-lib="$ROOT/runtime/zlib/${ZLIB_VER}/lib"
fi
make -j"$NPROC"
make install_sw
# RPATH for openssl CLI (lib may be lib or lib64)
OPENSSL_LIBDIR="$ROOT/runtime/openssl/${OPENSSL_VER}/lib64"
[[ -d "$OPENSSL_LIBDIR" ]] || OPENSSL_LIBDIR="$ROOT/runtime/openssl/${OPENSSL_VER}/lib"
if command -v patchelf >/dev/null 2>&1 && [[ -x "$ROOT/runtime/openssl/${OPENSSL_VER}/bin/openssl" ]]; then
  patchelf --set-rpath "${OPENSSL_LIBDIR}:$ROOT/runtime/zlib/${ZLIB_VER}/lib" \
    "$ROOT/runtime/openssl/${OPENSSL_VER}/bin/openssl" || true
fi
ln -sfn "${OPENSSL_VER}" "$ROOT/runtime/openssl/current"

# --- nginx ---
echo "=== build nginx ${NGINX_VER} ==="
CC_OPT='-O2 -fPIE -fstack-protector-strong -D_FORTIFY_SOURCE=2 -Wformat -Werror=format-security -fno-strict-aliasing'
LD_OPT='-Wl,-z,relro -Wl,-z,now -Wl,-z,noexecstack -pie -Wl,--as-needed'
NGINX_PREFIX="$ROOT/runtime/nginx/${NGINX_VER}"

configure_nginx() {
  local openssl_opt="$1"
  cd "$BUILD/nginx-${NGINX_VER}"
  make clean 2>/dev/null || true
  ./configure \
    --prefix="$NGINX_PREFIX" \
    --sbin-path="$NGINX_PREFIX/sbin/nginx" \
    --modules-path="$NGINX_PREFIX/modules" \
    --conf-path="$NGINX_PREFIX/conf/nginx.conf" \
    --error-log-path="$NGINX_PREFIX/logs/error.log" \
    --http-log-path="$NGINX_PREFIX/logs/access.log" \
    --pid-path="$NGINX_PREFIX/logs/nginx.pid" \
    --lock-path="$NGINX_PREFIX/logs/nginx.lock" \
    --http-client-body-temp-path="$NGINX_PREFIX/tmp/client_body" \
    --http-proxy-temp-path="$NGINX_PREFIX/tmp/proxy" \
    --http-fastcgi-temp-path="$NGINX_PREFIX/tmp/fastcgi" \
    --http-uwsgi-temp-path="$NGINX_PREFIX/tmp/uwsgi" \
    --http-scgi-temp-path="$NGINX_PREFIX/tmp/scgi" \
    --user=nobody --group=nobody \
    --with-threads \
    --with-file-aio \
    --with-http_ssl_module \
    --with-http_v2_module \
    --with-http_realip_module \
    --with-http_stub_status_module \
    --with-http_gzip_static_module \
    --with-http_gunzip_module \
    --with-http_auth_request_module \
    --with-http_secure_link_module \
    --with-http_slice_module \
    --with-stream \
    --with-stream_ssl_module \
    --with-stream_realip_module \
    --with-stream_ssl_preread_module \
    --without-mail_pop3_module \
    --without-mail_imap_module \
    --without-mail_smtp_module \
    --with-pcre="$BUILD/pcre2-${PCRE2_VER}-src" \
    --with-pcre-jit \
    --with-openssl="$BUILD/openssl-${OPENSSL_VER}-src" \
    --with-openssl-opt="$openssl_opt" \
    --with-zlib="$BUILD/zlib-${ZLIB_VER}-src" \
    --with-cc-opt="$CC_OPT" \
    --with-ld-opt="$LD_OPT"
}

configure_nginx "$OPENSSL_NGINX_OPT"
set +e
make -j"$NPROC"
MAKE_RC=$?
set -e
if [[ $MAKE_RC -ne 0 ]] && [[ "$OPENSSL_NGINX_OPT" == *enable-ec_nistp* ]]; then
  echo "WARN: nginx make failed; rebuild openssl-src without ec_nistp"
  rm -rf "$BUILD/openssl-${OPENSSL_VER}-src"
  tar xzf /opt/lib/openssl-${OPENSSL_VER}.tar.gz -C "$BUILD"
  mv "$BUILD/openssl-${OPENSSL_VER}" "$BUILD/openssl-${OPENSSL_VER}-src"
  OPENSSL_NGINX_OPT='no-weak-ssl-ciphers'
  configure_nginx "$OPENSSL_NGINX_OPT"
  make -j"$NPROC"
fi
make install

mkdir -p "$NGINX_PREFIX"/{sbin,bin,conf,modules,lib,logs,tmp/{client_body,proxy,fastcgi,uwsgi,scgi}}
ln -sfn "${NGINX_VER}" "$ROOT/runtime/nginx/current"
ln -sfn ../sbin/nginx "$NGINX_PREFIX/bin/nginx"
cp -a "$NGINX_PREFIX/sbin/nginx" "$NGINX_PREFIX/sbin/nginx.unstripped"
strip --strip-unneeded "$NGINX_PREFIX/sbin/nginx"

# packages cache
cp -a "/opt/soft/nginx/nginx-${NGINX_VER}.tar.gz" "$ROOT/runtime/nginx/packages/"
cp -a "/opt/soft/nginx/nginx-${NGINX_VER}.tar.gz" "$ROOT/packages/nginx/"
for f in /opt/lib/openssl-*.tar.gz /opt/lib/pcre2-*.tar.gz /opt/lib/zlib-*.tar.gz; do
  bn=$(basename "$f")
  [[ "$bn" == ._* ]] && continue
  cp -a "$f" "$ROOT/packages/tools/"
done

echo "runtime-nginx-${NGINX_VER}" > "$ROOT/VERSION"
cat > "$ROOT/README.md" << 'EOF'
# Modiverse Runtime（Nginx）

从 `/opt/soft`（nginx）与 `/opt/lib`（openssl / pcre2 / zlib）源码构建的可移植运行时。

## 优化目标

1. **性能**：`-O2`、PCRE JIT、threads、file AIO、HTTP/2
2. **安全**：PIE、stack-protector-strong、`_FORTIFY_SOURCE=2`、RELRO+NOW、`no-weak-ssl-ciphers`；禁用未使用的 mail 模块
3. **快速加载**：openssl/pcre2/zlib 经 `--with-*` 静态编入 nginx；release 二进制 `strip`；`--as-needed`
4. **可移植**：禁止 `-march=native`，便于在其它 x86_64 服务器运行

## 运行检查

```bash
/opt/modiverse/runtime/nginx/current/sbin/nginx -t
/opt/modiverse/runtime/nginx/current/sbin/nginx -V
```

运维配置建议：`/opt/modiverse/config/nginx/`；运行时默认配置：`runtime/nginx/<ver>/conf/`。
EOF

if [[ -f "$NGINX_PREFIX/conf/nginx.conf" ]]; then
  {
    echo "# 运维侧：/opt/modiverse/config/nginx/"
    echo "# 运行时默认：/opt/modiverse/runtime/nginx/current/conf/"
    echo "#"
    cat "$NGINX_PREFIX/conf/nginx.conf"
  } > "$ROOT/config/nginx/nginx.conf"
fi

NGINX_BIN="$NGINX_PREFIX/sbin/nginx"
{
  echo "date=$(date -Is)"
  echo "hostname=$(hostname)"
  echo "nginx=${NGINX_VER} openssl=${OPENSSL_VER} pcre2=${PCRE2_VER} zlib=${ZLIB_VER}"
  echo "CC_OPT=$CC_OPT"
  echo "LD_OPT=$LD_OPT"
  echo "OPENSSL_NGINX_OPT=$OPENSSL_NGINX_OPT"
  echo "--- nginx -V ---"
  "$NGINX_BIN" -V 2>&1
  echo "--- ldd ---"
  ldd "$NGINX_BIN" || true
  echo "--- file ---"
  file "$NGINX_BIN"
  echo "--- readelf ---"
  readelf -d "$NGINX_BIN" | grep -E 'FLAGS|BIND|NOW|NEEDED' || true
  echo "--- nginx -t ---"
  "$NGINX_BIN" -t 2>&1 || true
} | tee "$NGINX_PREFIX/BUILDINFO.txt"

echo "=== BUILD OK ==="
ls -la "$ROOT/runtime/nginx/current/sbin/"
ls -la "$ROOT/runtime/"
