#!/usr/bin/env bash
# DEPRECATED as a packaging path: common-libs, nginx dual RUNPATH, and LibreOffice
# relative-link / glibc stripping now live in scripts/runtime-build/build-aarch64.sh.
#
# This script only flattens existing runtime/aarch64 archives into the installer
# acceptance repository layout (name/name-version-linux-aarch64.tar.gz).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ARCH_ROOT="${MDV_AARCH64_RUNTIME_ROOT:-$REPO_ROOT/runtime/aarch64}"
FLAT_ROOT="${MDV_ACCEPTANCE_REPO_ROOT:-$REPO_ROOT/runtime/acceptance-repo/aarch64}"

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

sha256_file() {
  sha256sum "$1" | awk '{print $1}'
}

# Maps runtime/aarch64 component dir names to Nexus flat-repo directory names.
flat_repo_name() {
  case "$1" in
    opentelemetry) printf '%s' 'opentelemetry-collector' ;;
    *) printf '%s' "$1" ;;
  esac
}

# Stages the flat path layout expected by installer acceptance YAML.
stage_flat_repo() {
  local name archive dest_dir dest flat_name
  rm -rf "$FLAT_ROOT"
  mkdir -p "$FLAT_ROOT"
  while IFS= read -r -d '' archive; do
    name="$(basename "$(dirname "$(dirname "$archive")")")"
    flat_name="$(flat_repo_name "$name")"
    dest_dir="$FLAT_ROOT/$flat_name"
    mkdir -p "$dest_dir"
    dest="$dest_dir/$(basename "$archive")"
    cp -a "$archive" "$dest"
    if [[ -f "$archive.sha256" ]]; then
      cp -a "$archive.sha256" "$dest.sha256"
    else
      printf '%s  %s\n' "$(sha256_file "$dest")" "$(basename "$dest")" >"$dest.sha256"
    fi
    printf 'staged %s/%s\n' "$flat_name" "$(basename "$dest")"
  done < <(find "$ARCH_ROOT" -type f -name '*-linux-aarch64.tar.gz' -print0 | sort -z)
  printf 'flat acceptance repo: %s\n' "$FLAT_ROOT"
}

main() {
  [[ -d "$ARCH_ROOT" ]] || die "missing Runtime root: $ARCH_ROOT"
  if ! find "$ARCH_ROOT" -type f -name '*-linux-aarch64.tar.gz' | grep -q .; then
    die "no aarch64 Runtime archives under $ARCH_ROOT; run scripts/build-aarch64-runtime.sh first"
  fi
  if [[ ! -f "$ARCH_ROOT/common-libs/1.0.0/common-libs-1.0.0-linux-aarch64.tar.gz" ]]; then
    die "common-libs missing from main build output; rebuild with scripts/build-aarch64-runtime.sh common-libs"
  fi
  stage_flat_repo
  printf 'note: packaging patches are no longer applied here; verify with scripts/verify-aarch64-runtime.sh\n'
}

main "$@"
