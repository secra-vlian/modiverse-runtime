# Orchestrates native Linux aarch64 Runtime builds through Docker Desktop.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILDER_BASE_IMAGE="${MDV_AARCH64_BUILDER_BASE_IMAGE:-quay.io/pypa/manylinux2014_aarch64}"
BUILDER_IMAGE="${MDV_AARCH64_BUILDER_IMAGE:-modiverse-runtime-aarch64-builder:manylinux2014}"
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

# Rewrites host-loopback proxy URLs so containers can reach the host proxy.
docker_proxy_value() {
  local value="$1"
  # Inside the container, 127.0.0.1 is not the Mac host; Docker Desktop exposes it as host.docker.internal.
  value="${value//127.0.0.1/host.docker.internal}"
  value="${value//localhost/host.docker.internal}"
  printf '%s' "$value"
}

# Collects proxy build-args / env pairs for docker build and docker run.
collect_proxy_args() {
  local mode="$1"
  local proxy_name
  local value
  local -a args=()
  for proxy_name in HTTP_PROXY HTTPS_PROXY ALL_PROXY http_proxy https_proxy all_proxy NO_PROXY no_proxy; do
    if [[ -n "${!proxy_name:-}" ]]; then
      value="$(docker_proxy_value "${!proxy_name}")"
      if [[ "$mode" == build ]]; then
        args+=(--build-arg "$proxy_name=$value")
      else
        args+=(-e "$proxy_name=$value")
      fi
    fi
  done
  if ((${#args[@]})); then
    printf '%s\n' "${args[@]}"
  fi
}

# Refreshes the reusable compiler image, with Docker layer caching enabled.
ensure_builder_image() {
  local -a proxy_args=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && proxy_args+=("$line")
  done < <(collect_proxy_args build)
  docker build --platform linux/arm64 \
    --build-arg "BASE_IMAGE=$BUILDER_BASE_IMAGE" \
    ${proxy_args[@]+"${proxy_args[@]}"} \
    -t "$BUILDER_IMAGE" \
    -f "$REPO_ROOT/scripts/runtime-build/Dockerfile.aarch64" \
    "$REPO_ROOT"
}

# Runs the isolated build implementation with the repository mounted as output storage.
run_builder() {
  local -a proxy_args=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && proxy_args+=("$line")
  done < <(collect_proxy_args run)
  docker run --rm --platform linux/arm64 \
    --add-host=host.docker.internal:host-gateway \
    -e "MDV_BUILD_COMPONENT=$COMPONENT" \
    -e "MDV_HOST_UID=$(id -u)" \
    -e "MDV_HOST_GID=$(id -g)" \
    -e "MDV_BUILD_JOBS=${MDV_BUILD_JOBS:-}" \
    ${proxy_args[@]+"${proxy_args[@]}"} \
    -v "$REPO_ROOT:/workspace" \
    -w /workspace \
    "$BUILDER_IMAGE" \
    bash scripts/runtime-build/build-aarch64.sh
}

validate_component
verify_docker_architecture
ensure_builder_image
run_builder
