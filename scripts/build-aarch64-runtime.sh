#!/usr/bin/env bash
# Orchestrates native Linux aarch64 Runtime builds through Docker Desktop.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILDER_IMAGE="${MDV_AARCH64_BUILDER_IMAGE:-modiverse-runtime-aarch64-builder:local}"
BUILDER_BASE_IMAGE="${MDV_AARCH64_BUILDER_BASE_IMAGE:-debian:13}"
COMPONENT="${1:-all}"

# Rejects unknown component names before starting an expensive container build.
validate_component() {
  case "$COMPONENT" in
    all|nginx|postgresql|redis|zeromq|tusd|opentelemetry|openobserve|ffmpeg|poppler|libreoffice) ;;
    *)
      echo "Unknown Runtime component: $COMPONENT" >&2
      exit 2
      ;;
  esac
}

# Verifies that the selected Docker engine can execute native aarch64 containers.
verify_docker_architecture() {
  local server_arch
  server_arch="$(docker info --format '{{.Architecture}}')"
  if [[ "$server_arch" != "aarch64" && "$server_arch" != "arm64" ]]; then
    echo "Docker server must be aarch64/arm64, got: $server_arch" >&2
    exit 1
  fi
}

# Refreshes the reusable compiler image, with Docker layer caching enabled.
ensure_builder_image() {
  local proxy_name
  local -a proxy_args=()
  for proxy_name in HTTP_PROXY HTTPS_PROXY NO_PROXY http_proxy https_proxy no_proxy; do
    if [[ -n "${!proxy_name:-}" ]]; then
      proxy_args+=(--build-arg "$proxy_name=${!proxy_name}")
    fi
  done
  docker build --platform linux/arm64 \
    --build-arg "BASE_IMAGE=$BUILDER_BASE_IMAGE" \
    "${proxy_args[@]}" \
    -t "$BUILDER_IMAGE" \
    -f "$REPO_ROOT/scripts/runtime-build/Dockerfile.aarch64" \
    "$REPO_ROOT"
}

# Runs the isolated build implementation with the repository mounted as output storage.
run_builder() {
  local proxy_name
  local -a proxy_args=()
  for proxy_name in HTTP_PROXY HTTPS_PROXY NO_PROXY http_proxy https_proxy no_proxy; do
    if [[ -n "${!proxy_name:-}" ]]; then
      proxy_args+=(-e "$proxy_name")
    fi
  done
  docker run --rm --platform linux/arm64 \
    -e "MDV_BUILD_COMPONENT=$COMPONENT" \
    -e "MDV_HOST_UID=$(id -u)" \
    -e "MDV_HOST_GID=$(id -g)" \
    "${proxy_args[@]}" \
    -v "$REPO_ROOT:/workspace" \
    -w /workspace \
    "$BUILDER_IMAGE" \
    bash scripts/runtime-build/build-aarch64.sh
}

validate_component
verify_docker_architecture
ensure_builder_image
run_builder
