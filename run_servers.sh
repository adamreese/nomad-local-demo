#!/usr/bin/env bash
set -euo pipefail

export VAULT_ADDR=http://localhost:8200
export VAULT_TOKEN=devroot

require() {
  if ! hash "$1" &>/dev/null; then
    echo "'$1' not found in PATH"
    exit 1
  fi
}

require nomad
require consul
require vault
require bindle

cleanup() {
  echo
  echo "Sutting down services"
  kill $(jobs -p)
  wait
}

trap cleanup EXIT

rm -rf ./data
mkdir -p log

# https://www.nomadproject.io/docs/faq#q-how-to-connect-to-my-host-network-when-using-docker-desktop-windows-and-macos

IP_ADDRESS=$(ipconfig getifaddr en0)

echo "Starting consul..."
consul agent -dev \
  -config-file consul/consul.hcl \
  -bootstrap-expect 1 \
  -client '0.0.0.0' \
  -bind "${IP_ADDRESS}" \
  &>log/consul.log &

echo "Starting vault..."
vault server -dev \
  -dev-root-token-id "$VAULT_TOKEN" \
  -config vault/vault.hcl \
  &>log/vault.log &

echo "Waiting for vault..."
while ! grep -q 'Unseal Key' <log/vault.log; do
  sleep 2
done

echo "Storing unseal token in ./data/vault/unseal"
if [ ! -f data/vault/unseal ]; then
  awk '/^Root Token:/ { print $NF }' <log/vault.log >data/vault/token
  awk '/^Unseal Key:/ { print $NF }' <log/vault.log >data/vault/unseal
fi

vault secrets enable kv
vault kv put kv/tote foo=bar

echo "Starting nomad..."
nomad agent -dev \
  -config nomad/nomad.hcl \
  -network-interface en0 \
  -data-dir "${PWD}/data/nomad" \
  -consul-address "${IP_ADDRESS}:8500" \
  -vault-address http://127.0.0.1:8200 \
  -vault-token "${VAULT_TOKEN}" \
   &>log/nomad.log &

echo "Waiting for nomad..."
while ! nomad server members 2>/dev/null | grep -q alive; do
  sleep 2
done

echo "Starting traefik job..."
nomad run job/traefik.nomad

echo "Starting bindle job..."
nomad run job/bindle.nomad

echo
echo "Dashboards"
echo "----------"
echo "Consul:  http://localhost:8500"
echo "Nomad:   http://localhost:4646"
echo "Vault:   http://localhost:8200"
echo "Traefik: http://localhost:8081"
echo
echo "Logs are stored in ./log"
echo
echo "Export these into your shell"
echo
echo "    export CONSUL_HTTP_ADDR=http://${IP_ADDRESS}:8500"
echo "    export NOMAD_ADDR=http://127.0.0.1:4646"
echo "    export VAULT_ADDR=${VAULT_ADDR}"
echo "    export VAULT_TOKEN=$(<data/vault/token)"
echo "    export VAULT_UNSEAL=$(<data/vault/unseal)"
echo "    export BINDLE_URL=http://bindle.local.fermyon.link:8088/v1"
echo
echo "Ctrl+C to exit."
echo

wait
