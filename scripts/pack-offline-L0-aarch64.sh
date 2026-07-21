#!/usr/bin/env bash
# Assembles an offline-L0-aarch64 media tree from built Runtime archives.
#
# Layout:
#   offline-L0-aarch64/
#   ├── mdv-installer                 # optional, via MDV_INSTALLER_BIN
#   ├── mdv.config.yaml
#   └── runtime/
#       ├── common-libs/...
#       ├── nginx/...
#       └── ...
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ARCH_ROOT="${MDV_AARCH64_RUNTIME_ROOT:-$REPO_ROOT/runtime/aarch64}"
OUT_ROOT="${MDV_OFFLINE_OUT:-$REPO_ROOT/runtime/offline-L0-aarch64}"
INSTALLER_BIN="${MDV_INSTALLER_BIN:-}"
INCLUDE_OPTIONAL="${MDV_OFFLINE_INCLUDE_OPTIONAL:-1}"
# Portable default: copy the media tree to this path on the target host before install.
OFFLINE_BASE_URL="${MDV_OFFLINE_BASE_URL:-file:///opt/mdv-offline-L0-aarch64/runtime}"

# L0 required components (contract §5).
L0_REQUIRED=(common-libs nginx postgresql redis zeromq tusd)
# Optional same-batch components.
L0_OPTIONAL=(opentelemetry ffmpeg poppler)

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

sha256_file() {
  sha256sum "$1" | awk '{print $1}'
}

# Resolves the newest version directory for one component under ARCH_ROOT.
latest_version_dir() {
  local name="$1"
  local dir
  dir="$(find "$ARCH_ROOT/$name" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort -V | tail -1 || true)"
  [[ -n "$dir" ]] || return 1
  printf '%s' "$dir"
}

# Copies one component archive (+ sha256) into the offline runtime tree.
copy_component() {
  local name="$1"
  local version_dir archive dest_dir dest
  version_dir="$(latest_version_dir "$name")" || die "missing component $name under $ARCH_ROOT"
  archive="$(find "$version_dir" -maxdepth 1 -type f -name "${name}-*-linux-aarch64.tar.gz" -print -quit)"
  if [[ "$name" == "opentelemetry" ]]; then
    archive="$(find "$version_dir" -maxdepth 1 -type f -name 'opentelemetry-collector-*-linux-aarch64.tar.gz' -print -quit)"
  fi
  [[ -f "$archive" ]] || die "missing archive for $name in $version_dir"
  dest_dir="$OUT_ROOT/runtime/$name"
  mkdir -p "$dest_dir"
  dest="$dest_dir/$(basename "$archive")"
  cp -a "$archive" "$dest"
  if [[ -f "$archive.sha256" ]]; then
    cp -a "$archive.sha256" "$dest.sha256"
  else
    printf '%s  %s\n' "$(sha256_file "$dest")" "$(basename "$dest")" >"$dest.sha256"
  fi
  printf 'packed %s\n' "$dest"
  # Emit path relative to runtime/ for YAML.
  printf '%s/%s\n' "$name" "$(basename "$dest")"
}

# Writes mdv.config.yaml with a portable file:// baseURL (override via MDV_OFFLINE_BASE_URL).
write_config() {
  cat >"$OUT_ROOT/mdv.config.yaml" <<EOF
name: modiverse
version: "1.0.0"
baseURL: "$OFFLINE_BASE_URL"
software:
EOF
  local name version_dir version artifact path_rel
  local -a names=("${L0_REQUIRED[@]}")
  if [[ "$INCLUDE_OPTIONAL" == "1" ]]; then
    names+=("${L0_OPTIONAL[@]}")
  fi
  for name in "${names[@]}"; do
    version_dir="$(latest_version_dir "$name")" || die "missing $name"
    version="$(basename "$version_dir")"
    if [[ "$name" == "opentelemetry" ]]; then
      artifact="opentelemetry-collector-${version}-linux-{arch}.tar.gz"
      path_rel="opentelemetry/${artifact}"
    else
      artifact="${name}-${version}-linux-{arch}.tar.gz"
      path_rel="${name}/${artifact}"
    fi
    printf '  %s:\n    version: "%s"\n    path: "%s"\n' "$name" "$version" "$path_rel" >>"$OUT_ROOT/mdv.config.yaml"
    case "$name" in
      nginx) printf '    port: 80\n' >>"$OUT_ROOT/mdv.config.yaml" ;;
      postgresql) printf '    port: 5432\n' >>"$OUT_ROOT/mdv.config.yaml" ;;
      redis) printf '    port: 6379\n' >>"$OUT_ROOT/mdv.config.yaml" ;;
      tusd) printf '    port: 1080\n' >>"$OUT_ROOT/mdv.config.yaml" ;;
      opentelemetry) printf '    port: 4317\n' >>"$OUT_ROOT/mdv.config.yaml" ;;
    esac
  done
  printf 'wrote %s (baseURL=%s)\n' "$OUT_ROOT/mdv.config.yaml" "$OFFLINE_BASE_URL"
}

main() {
  [[ -d "$ARCH_ROOT" ]] || die "missing Runtime root: $ARCH_ROOT"
  rm -rf "$OUT_ROOT"
  mkdir -p "$OUT_ROOT/runtime"

  local name
  for name in "${L0_REQUIRED[@]}"; do
    copy_component "$name" >/dev/null
  done
  if [[ "$INCLUDE_OPTIONAL" == "1" ]]; then
    for name in "${L0_OPTIONAL[@]}"; do
      if latest_version_dir "$name" >/dev/null 2>&1; then
        copy_component "$name" >/dev/null
      else
        printf 'skip optional missing: %s\n' "$name"
      fi
    done
  fi

  write_config

  if [[ -n "$INSTALLER_BIN" ]]; then
    [[ -f "$INSTALLER_BIN" ]] || die "MDV_INSTALLER_BIN not found: $INSTALLER_BIN"
    cp -a "$INSTALLER_BIN" "$OUT_ROOT/mdv-installer"
    chmod 0755 "$OUT_ROOT/mdv-installer"
    printf 'copied installer: %s\n' "$OUT_ROOT/mdv-installer"
  else
    printf 'note: set MDV_INSTALLER_BIN=/path/to/mdv-installer to include the binary\n'
  fi

  cat >"$OUT_ROOT/README.txt" <<EOF
offline-L0-aarch64
==================

1. Copy this entire directory to the Debian 12 aarch64 host as:
     /opt/mdv-offline-L0-aarch64
   (or set MDV_OFFLINE_BASE_URL when packing, and match that path)

2. Install into an empty install root (example):

     sudo install -d -m 0755 /opt/mdv-p1-acceptance-aarch64-offline
     sudo cp mdv-installer /opt/mdv-p1-acceptance-aarch64-offline/
     sudo cp mdv.config.yaml /opt/mdv-p1-acceptance-aarch64-offline/
     cd /opt/mdv-p1-acceptance-aarch64-offline
     sudo ./mdv-installer install

   Default baseURL in mdv.config.yaml:
     $OFFLINE_BASE_URL

3. Intranet alternative: upload runtime/ to Nexus and change baseURL to HTTPS/HTTP.

OpenObserve / LibreOffice are intentionally omitted (L1/L2).
EOF

  printf 'offline L0 media: %s\n' "$OUT_ROOT"
}

main "$@"
