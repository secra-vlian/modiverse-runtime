#!/usr/bin/env bash
# Verifies aarch64 Runtime archives against the glibc ≤2.17 / x86_64 packaging contract.

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

verify_archive() {
  local archive="$1"
  local name
  local tmp
  local buildinfo
  local so_list
  local has_libc=0
  local has_loader=0
  local elf
  local glibc_need
  local allow_glibc_closure=0

  name="$(basename "$archive")"
  case "$name" in
    openobserve-*|libreoffice-*) allow_glibc_closure=1 ;;
  esac

  tmp="$(mktemp -d)"
  tar -xzf "$archive" -C "$tmp"

  buildinfo=""
  [[ -f "$tmp/BUILDINFO" ]] && buildinfo="$(cat "$tmp/BUILDINFO")"

  if [[ "$allow_glibc_closure" -eq 0 ]]; then
    if ! grep -q 'manylinux2014\|glibc 2\.17' <<<"$buildinfo"; then
      fail "$name BUILDINFO missing manylinux2014 / glibc 2.17 baseline"
    else
      pass "$name BUILDINFO baseline"
    fi
  else
    pass "$name BUILDINFO (loader-closure package)"
  fi

  so_list="$(find "$tmp" -type f \( -name '*.so' -o -name '*.so.*' \) | sed "s|^$tmp/||" | sort || true)"

  if grep -q 'libc\.so\.6' <<<"$so_list"; then has_libc=1; fi
  if grep -q 'ld-linux-aarch64\.so\.1' <<<"$so_list"; then has_loader=1; fi

  if ((has_libc != has_loader)); then
    fail "$name incomplete glibc closure (libc=$has_libc loader=$has_loader)"
  elif ((has_libc == 1 && allow_glibc_closure == 0)); then
    fail "$name must not ship glibc/loader"
  elif ((has_libc == 1)); then
    pass "$name paired glibc closure"
  fi

  case "$name" in
    nginx-*|redis-*)
      if [[ -n "$so_list" ]]; then
        fail "$name must not contain shared libraries, found: $so_list"
      else
        pass "$name has no .so files"
      fi
      ;;
    postgresql-*)
      if grep -E 'lib(ssl|crypto|z|lz4|zstd|crypt)\.so' <<<"$so_list" >/dev/null; then
        fail "$name contains forbidden host libraries"
      else
        pass "$name has no host ssl/zlib/lz4/zstd"
      fi
      ;;
    zeromq-*)
      if grep -E 'lib(ssl|crypto|z|lz4|zstd|crypt|sodium)\.so' <<<"$so_list" >/dev/null; then
        fail "$name contains forbidden host libraries"
      else
        pass "$name ships only libzmq (no host ssl/sodium)"
      fi
      ;;
  esac

  while IFS= read -r -d '' elf; do
    [[ -f "$elf" ]] || continue
    file "$elf" | grep -q ELF || continue
    # Loader-closure packages intentionally run against bundled glibc.
    if ((allow_glibc_closure == 1)); then
      continue
    fi
    glibc_need="$(max_glibc_symbol "$elf")"
    [[ -n "$glibc_need" ]] || continue
    glibc_need="${glibc_need#GLIBC_}"
    if ! version_le "$glibc_need" "2.17"; then
      fail "$name $(basename "$elf") requires GLIBC_$glibc_need (> 2.17)"
    fi
  done < <(find "$tmp" -type f -print0)

  rm -rf "$tmp"
}

echo "Verifying Runtime archives under $ARCH_ROOT"
while IFS= read -r -d '' archive; do
  echo "---- $(basename "$archive") ----"
  verify_archive "$archive"
done < <(find "$ARCH_ROOT" -type f -name '*-linux-aarch64.tar.gz' -print0 | sort -z)

if ((FAILED != 0)); then
  echo "Verification failed." >&2
  exit 1
fi
echo "All aarch64 Runtime contract checks passed."
