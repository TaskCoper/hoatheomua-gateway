#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: bash manage.sh INSTANCE {bootstrap|config|pull|up|ps|logs|stop|start}" >&2
  echo "Instances: hoatheomua-be-dev, hoatheomua-gateway-dev, hoatheomua-gateway-prod," >&2
  echo "           taskcoper-dev, taskcoper-prod, taskcoper-htm-dev" >&2
}

[[ $# -eq 2 ]] || { usage; exit 2; }
instance=$1
action=$2
tunnel_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
compose_files=(-f "$tunnel_dir/compose.yaml")
networks=()

case "$instance" in
  hoatheomua-be-dev|taskcoper-htm-dev)
    networks=(hoatheomua-network-dev)
    ;;
  hoatheomua-gateway-dev|hoatheomua-gateway-prod)
    stage=${instance##*-}
    networks=("hoatheomua-network-$stage" "hoatheomua-gateway-network-$stage")
    export TUNNEL_GATEWAY_NETWORK=${networks[1]}
    compose_files+=(-f "$tunnel_dir/compose.gateway.yaml")
    ;;
  taskcoper-dev|taskcoper-prod)
    networks=("taskcoper-network-${instance##*-}")
    ;;
  *) usage; exit 2 ;;
esac

case "$action" in
  bootstrap)
    # Reuse existing networks without changing labels, IDs or attached containers.
    docker info >/dev/null
    for network in "${networks[@]}"; do
      if ! docker network inspect "$network" >/dev/null 2>&1; then
        docker network create --driver bridge "$network" >/dev/null ||
          docker network inspect "$network" >/dev/null
      fi
      echo "Network ready: $network"
    done
    exit 0
    ;;
  config|pull|up|ps|logs|stop|start) ;;
  *) usage; exit 2 ;;
esac

export TUNNEL_PROJECT="ingress-$instance"
export TUNNEL_APP_NETWORK=${networks[0]}
env_file="$tunnel_dir/env/$instance.env"
[[ -f "$env_file" ]] || { echo "Missing $env_file; copy env/instance.env.example first." >&2; exit 1; }
# Read secrets through Compose, never source the env file as executable shell code.
# The selected instance file must win over credentials exported for another instance.
unset CLOUDFLARED_IMAGE CLOUDFLARE_TUNNEL_TOKEN CLOUDFLARED_PROTOCOL
compose=(docker compose --env-file "$env_file" -p "$TUNNEL_PROJECT" "${compose_files[@]}")
image_ref=$("${compose[@]}" config --images)
if [[ ! "$image_ref" =~ ^cloudflare/cloudflared:(20[0-9]{2}\.[0-9]+\.[0-9]+)$ &&
      ! "$image_ref" =~ ^cloudflare/cloudflared@sha256:[a-f0-9]{64}$ ]]; then
  echo "CLOUDFLARED_IMAGE must use an exact release tag (YYYY.M.N) or sha256 digest." >&2
  exit 1
fi

case "$action" in
  config) "${compose[@]}" config --quiet ;;
  pull) "${compose[@]}" pull cloudflared ;;
  up)
    for network in "${networks[@]}"; do
      docker network inspect "$network" >/dev/null || {
        echo "Missing $network; run: bash manage.sh $instance bootstrap" >&2
        exit 1
      }
    done
    "${compose[@]}" up -d --no-build --wait --wait-timeout 120 cloudflared
    ;;
  ps) "${compose[@]}" ps ;;
  logs) "${compose[@]}" logs --tail 200 --timestamps cloudflared ;;
  stop) "${compose[@]}" stop cloudflared ;;
  start) "${compose[@]}" start cloudflared ;;
esac
