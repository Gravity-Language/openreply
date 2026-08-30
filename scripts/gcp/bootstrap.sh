#!/usr/bin/env bash
set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run this script as root." >&2
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y --no-install-recommends \
  ca-certificates curl gnupg gzip jq lsb-release openssl

install -m 0755 -d /etc/apt/keyrings

if [[ ! -f /etc/apt/keyrings/docker.gpg ]]; then
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
fi

ARCH="$(dpkg --print-architecture)"
CODENAME="$(. /etc/os-release && echo "$VERSION_CODENAME")"
printf '%s\n' \
  "deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${CODENAME} stable" \
  > /etc/apt/sources.list.d/docker.list

if [[ ! -f /usr/share/keyrings/cloud.google.gpg ]]; then
  curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg \
    | gpg --dearmor -o /usr/share/keyrings/cloud.google.gpg
  chmod a+r /usr/share/keyrings/cloud.google.gpg
fi

printf '%s\n' \
  "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" \
  > /etc/apt/sources.list.d/google-cloud-sdk.list

apt-get update
apt-get install -y --no-install-recommends \
  containerd.io docker-buildx-plugin docker-ce docker-ce-cli \
  docker-compose-plugin google-cloud-cli

systemctl enable --now docker
install -d -m 0755 /opt/openreply /opt/openreply/scripts/gcp
install -d -m 0700 /etc/openreply

echo "VM bootstrap complete."
