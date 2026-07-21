#!/usr/bin/env bash
# Verifies aarch64 Runtime archives against the hybrid packaging contract:
# - musl / static: must not ship libc.musl / ld-musl; skip GLIBC_* gate
# - glibc-fallback: manylinux2014 / glibc 2.17 baseline + GLIBC_* ≤ 2.17
# - all: must not ship glibc libc.so.6 / ld-linux*

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ARCH_ROOT="${1:-$REPO_ROOT/runtime/aarch64}"
FAILED=0

# Returns the highest GLIBC_* version symbol required by an ELF file, or empty.
max_glibc_symbol() {
  local elf="$1"
  if ! command -v readelf >/dev/null 2>&1; then
    return 0
  fi
  readelf -V "$elf" 2>/dev/null \
    | grep -oE 'GLIBC_[0-9]+\.[0-9]+(\.[0-9]+)?' \
    | sort -t. -k1,1 -k2,2n -k3,3n \
    | tail -1 \
    || true
}

# Compares dotted versions; success when $1 <= $2.
version_le() {
  printf '%s\n%s\n' "$1" "$2" | sort -t. -k1,1n -k2,2n -k3,3n | head -1 | grep -qx "$1"
}

fail() {
  echo "FAIL: $*" >&2
  FAILED=1
}

pass() {
  echo "OK: $*"
}

# Reads Runtime linkage from BUILDINFO (defaults to glibc-fallback for legacy archives).
archive_linkage() {
  local buildinfo="$1"
  if grep -q 'Runtime linkage: musl' <<<"$buildinfo"; then
    printf '%s' 'musl'
    return
  fi
  if grep -q 'Runtime linkage: glibc-fallback' <<<"$buildinfo"; then
    printf '%s' 'glibc-fallback'
    return
  fi
  printf '%s' 'glibc-legacy'
}

verify_archive() {
  local archive="$1"
  local name
  local tmp
  local buildinfo
  local so_list
  local elf
  local glibc_need
  local linkage

  name="$(basename "$archive")"

  tmp="$(mktemp -d)"
  tar -xzf "$archive" -C "$tmp"

  buildinfo=""
  [[ -f "$tmp/BUILDINFO" ]] && buildinfo="$(cat "$tmp/BUILDINFO")"
  linkage="$(archive_linkage "$buildinfo")"

  case "$linkage" in
    musl)
      if ! grep -qi 'musl' <<<"$buildinfo"; then
        fail "$name BUILDINFO missing musl baseline"
      else
        pass "$name BUILDINFO musl baseline"
      fi
      ;;
    glibc-fallback|glibc-legacy)
      if ! grep -q 'manylinux2014\|glibc 2\.17' <<<"$buildinfo"; then
        fail "$name BUILDINFO missing manylinux2014 / glibc 2.17 baseline"
      else
        pass "$name BUILDINFO glibc baseline"
      fi
      ;;
  esac

  so_list="$(find "$tmp" \( -type f -o -type l \) \( -name '*.so' -o -name '*.so.*' -o -name 'ld-linux*' -o -name 'ld-musl*' -o -name 'libc.musl*' \) \
    | sed "s|^$tmp/||" | sort || true)"

  if grep -E 'libc\.so\.6|ld-linux' <<<"$so_list" >/dev/null; then
    fail "$name must not ship glibc/loader, found: $(grep -E 'libc\.so\.6|ld-linux' <<<"$so_list" | tr '\n' ' ')"
  else
    pass "$name has no glibc libc/ld-linux"
  fi

  if grep -E 'libc\.musl|ld-musl' <<<"$so_list" >/dev/null; then
    fail "$name must not ship musl/loader, found: $(grep -E 'libc\.musl|ld-musl' <<<"$so_list" | tr '\n' ' ')"
  else
    pass "$name has no musl libc/ld-musl"
  fi

  case "$name" in
    common-libs-*)
      if [[ "$linkage" != musl ]]; then
        if ! grep -q 'libcrypt\.so' <<<"$so_list"; then
          fail "$name must contain libcrypt.so.*"
        else
          pass "$name contains libcrypt"
        fi
      fi
      ;;
    nginx-*|redis-*)
      if [[ "$linkage" == musl ]]; then
        pass "$name musl delivery may include bundled .so runtime closure"
      elif [[ -n "$so_list" ]]; then
        fail "$name must not contain shared libraries, found: $so_list"
      else
        pass "$name has no .so files"
      fi
      ;;
    postgresql-*)
      if [[ "$linkage" == musl ]]; then
        pass "$name musl delivery may include bundled .so runtime closure"
      elif grep -E 'lib(ssl|crypto|z|lz4|zstd|crypt)\.so' <<<"$so_list" >/dev/null; then
        fail "$name contains forbidden host libraries"
      else
        pass "$name has no host ssl/zlib/lz4/zstd"
      fi
      ;;
    zeromq-*)
      if [[ "$linkage" == musl ]]; then
        pass "$name musl delivery may include bundled .so runtime closure"
      elif grep -E 'lib(ssl|crypto|z|lz4|zstd|crypt|sodium)\.so' <<<"$so_list" >/dev/null; then
        fail "$name contains forbidden host libraries"
      else
        pass "$name ships only libzmq (no host ssl/sodium)"
      fi
      ;;
  esac

  if [[ "$linkage" == musl ]]; then
    pass "$name skips GLIBC symbol gate (musl/static delivery)"
  else
    while IFS= read -r -d '' elf; do
      [[ -f "$elf" ]] || continue
      file "$elf" | grep -q ELF || continue
      glibc_need="$(max_glibc_symbol "$elf")"
      [[ -n "$glibc_need" ]] || continue
      glibc_need="${glibc_need#GLIBC_}"
      if ! version_le "$glibc_need" "2.17"; then
        fail "$name $(basename "$elf") requires GLIBC_$glibc_need (> 2.17)"
      fi
    done < <(find "$tmp" -type f -print0)
  fi

  rm -rf "$tmp"
}

echo "Verifying Runtime archives under $ARCH_ROOT"
# Skip deferred / hidden quarantine trees (L1/L2 non-publish experiments).
while IFS= read -r -d '' archive; do
  echo "---- $(basename "$archive") ----"
  verify_archive "$archive"
done < <(find "$ARCH_ROOT" \
  \( -path '*/.*' -o -path '*/deferred*' -o -path '*/.deferred*' \) -prune -o \
  -type f -name '*-linux-aarch64.tar.gz' -print0 | sort -z)

if ((FAILED != 0)); then
  echo "Verification failed." >&2
  exit 1
fi
echo "All aarch64 Runtime contract checks passed."
