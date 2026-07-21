#!/usr/bin/env bash
# Alpine apk helpers for musl Runtime packaging inside the manylinux builder container.

set -euo pipefail

ALPINE_MIRROR="${MDV_ALPINE_MIRROR:-https://dl-cdn.alpinelinux.org/alpine}"
ALPINE_FETCH_ROOT="${MDV_ALPINE_FETCH_ROOT:-/build/sources/alpine}"

# Returns the configured linkage strategy for one Runtime component.
component_linkage() {
  local name="$1"
  local var="MDV_LINKAGE_${name//-/_}"
  if [[ -n "${!var:-}" ]]; then
    printf '%s' "${!var}"
    return
  fi
  printf '%s' 'glibc-source'
}

# True when the component is delivered via any musl strategy (not glibc-source).
component_uses_musl() {
  local linkage
  linkage="$(component_linkage "$1")"
  [[ "$linkage" != 'glibc-source' ]]
}

# Downloads one Alpine .apk if not already cached.
fetch_alpine_apk() {
  local branch="$1"
  local repo="$2"
  local pkg="$3"
  local ver="$4"
  local dest_dir="$5"
  local output="$dest_dir/${pkg}-${ver}.apk"
  mkdir -p "$dest_dir"
  if [[ -s "$output" ]]; then
    printf '%s\n' "$output"
    return
  fi
  local url="$ALPINE_MIRROR/$branch/$repo/aarch64/${pkg}-${ver}.apk"
  download_file "$url" "$output"
  printf '%s\n' "$output"
}

# Extracts one .apk payload into a directory (ignores .PKGINFO / .SIGN.*).
extract_alpine_apk() {
  local apk="$1"
  local dest="$2"
  mkdir -p "$dest"
  tar -xzf "$apk" -C "$dest" 2>/dev/null || tar -xf "$apk" -C "$dest"
}

# Flattens extracted apk usr/{bin,sbin,lib,share} trees into a Runtime stage root.
flatten_alpine_payload() {
  local payload="$1"
  local stage="$2"
  local sub
  for sub in bin sbin lib share; do
    if [[ -d "$payload/usr/$sub" ]]; then
      mkdir -p "$stage/$sub"
      cp -a "$payload/usr/$sub/." "$stage/$sub/"
    fi
  done
  if [[ -d "$payload/etc" ]]; then
    mkdir -p "$stage/etc"
    cp -a "$payload/etc/." "$stage/etc/"
  fi
}

# True when a basename is musl libc or the dynamic loader (must not ship in archives).
is_musl_or_loader() {
  local base
  base="$(basename "$1")"
  case "$base" in
    ld-musl-aarch64.so.1|ld-musl-*.so.1|libc.musl-*.so.1|libc.musl-aarch64.so.1)
      return 0
      ;;
  esac
  return 1
}

# Removes musl loader / libc copies from a staged tree (host musl provides these).
strip_musl_and_loader() {
  local stage="$1"
  find "$stage" \( -type f -o -type l \) \( \
    -name 'ld-musl-*.so*' -o -name 'libc.musl-*.so*' \
  \) -delete 2>/dev/null || true
}

# Fails when musl core libraries remain in the stage.
assert_no_musl_or_loader() {
  local stage="$1"
  local path
  while IFS= read -r -d '' path; do
    if is_musl_or_loader "$path"; then
      echo "musl/loader must not ship in Runtime stage: $path" >&2
      return 1
    fi
  done < <(find "$stage" \( -type f -o -type l \) \( -name 'ld-musl*' -o -name 'libc.musl*' \) -print0 2>/dev/null)
}

# Writes BUILDINFO lines for musl-delivered components.
write_linkage_buildinfo() {
  local stage="$1"
  local linkage="$2"
  local detail="$3"
  {
    echo "Runtime linkage: $linkage"
    echo "$detail"
  } >>"$stage/BUILDINFO"
}

# Patches manifest platform fields for musl or glibc-fallback delivery.
patch_manifest_platform() {
  local stage="$1"
  local libc="$2"
  local platform_id="linux-aarch64-$libc"
  [[ -f "$stage/manifest.yaml" ]] || return 0
  sed -i \
    -e "s/linux-aarch64-glibc/$platform_id/g" \
    -e "s/linux-x86_64-glibc/$platform_id/g" \
    -e 's/arch: x86_64/arch: aarch64/g' \
    -e "s/libc: glibc/libc: $libc/g" \
    "$stage/manifest.yaml"
}

# Writes a marker file beside the archive when no official musl exists.
write_glibc_fallback_marker() {
  local output_dir="$1"
  local name="$2"
  local version="$3"
  local reason="$4"
  mkdir -p "$output_dir"
  cat >"$output_dir/UNSUPPORTED-MUSL" <<EOF
component: $name
version: $version
runtime_linkage: glibc-fallback
reason: $reason
delivery: built from official upstream source on manylinux2014 (glibc 2.17 baseline)
EOF
}

# Appends one component record for LINKAGE-MANIFEST.yaml generation at build end.
record_linkage_manifest() {
  local name="$1"
  local version="$2"
  local linkage="$3"
  local note="$4"
  local tsv="${MDV_LINKAGE_TSV:-$OUTPUT_ROOT/.linkage-manifest.tsv}"
  mkdir -p "$(dirname "$tsv")"
  printf '%s\t%s\t%s\t%s\n' "$name" "$version" "$linkage" "$note" >>"$tsv"
}

# Writes runtime/aarch64/LINKAGE-MANIFEST.yaml from collected TSV rows.
write_linkage_manifest_file() {
  local tsv="${MDV_LINKAGE_TSV:-$OUTPUT_ROOT/.linkage-manifest.tsv}"
  local manifest="$OUTPUT_ROOT/LINKAGE-MANIFEST.yaml"
  [[ -f "$tsv" ]] || return 0
  {
    echo 'schemaVersion: 1'
    echo 'platform: linux-aarch64-hybrid'
    echo 'generatedBy: scripts/runtime-build/build-aarch64.sh'
    echo 'components:'
    while IFS=$'\t' read -r name version linkage note; do
      [[ -n "$name" ]] || continue
      echo "  - name: $name"
      echo "    version: $version"
      echo "    linkage: $linkage"
      echo "    note: \"$note\""
    done <"$tsv"
  } >"$manifest"
  rm -f "$tsv"
}

# Downloads and merges a set of Alpine apk payloads into one Runtime stage.
stage_from_alpine_apks() {
  local stage="$1"
  shift
  local spec payload_root="$ALPINE_FETCH_ROOT/staging-$$"
  local branch repo pkg ver apk extracted
  mkdir -p "$stage" "$payload_root"
  rm -rf "$payload_root"
  mkdir -p "$payload_root"
  for spec in "$@"; do
    IFS='|' read -r branch repo pkg ver <<<"$spec"
    apk="$(fetch_alpine_apk "$branch" "$repo" "$pkg" "$ver" "$ALPINE_FETCH_ROOT")"
    extracted="$payload_root/${pkg}-${ver}"
    rm -rf "$extracted"
    mkdir -p "$extracted"
    extract_alpine_apk "$apk" "$extracted"
    flatten_alpine_payload "$extracted" "$stage"
  done
  rm -rf "$payload_root"
}

# Finalizes a musl Runtime stage: contract, metadata, packaging.
finalize_musl_component() {
  local name="$1"
  local version="$2"
  local stage="$3"
  local linkage="$4"
  local detail="$5"
  shift 5
  strip_musl_and_loader "$stage"
  assert_no_musl_or_loader "$stage"
  apply_contract "$name" "$version" "$stage"
  patch_manifest_platform "$stage" musl
  set_component_runpaths "$stage"
  write_metadata "$name" "$version" "$stage" "$@"
  write_linkage_buildinfo "$stage" "$linkage" "$detail"
  local output_dir="$OUTPUT_ROOT/$name/$version"
  record_linkage_manifest "$name" "$version" "$linkage" "$detail"
  package_runtime "$name" "$version" "$stage"
}

# Finalizes a glibc-fallback Runtime stage with UNSUPPORTED-MUSL marker.
finalize_glibc_fallback_component() {
  local name="$1"
  local version="$2"
  local stage="$3"
  local reason="$4"
  shift 4
  apply_contract "$name" "$version" "$stage"
  patch_manifest_platform "$stage" glibc
  write_metadata "$name" "$version" "$stage" "$@"
  {
    echo 'Runtime linkage: glibc-fallback'
    echo 'Build baseline: manylinux2014 / glibc (no official musl for pinned version)'
    echo "Musl status: UNSUPPORTED-MUSL — $reason"
  } >>"$stage/BUILDINFO"
  local output_dir="$OUTPUT_ROOT/$name/$version"
  write_glibc_fallback_marker "$output_dir" "$name" "$version" "$reason"
  record_linkage_manifest "$name" "$version" glibc-fallback "$reason"
  package_runtime "$name" "$version" "$stage"
}
