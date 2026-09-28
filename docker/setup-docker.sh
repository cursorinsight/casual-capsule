#!/usr/bin/bash
set -euo pipefail

install -m 0755 -d /etc/apt/keyrings

# shellcheck disable=SC1091
. /etc/os-release
DISTRO_ID="${ID}"
DISTRO_CODENAME="${VERSION_CODENAME:-${UBUNTU_CODENAME:-}}"

curl -fsSL "https://download.docker.com/linux/${DISTRO_ID}/gpg" |
    gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) " \
     "signed-by=/etc/apt/keyrings/docker.gpg] " \
     "https://download.docker.com/linux/${DISTRO_ID} " \
     "${DISTRO_CODENAME} stable" \
     > /etc/apt/sources.list.d/docker.list

apt-get update
# Install the Docker client stack, and the Docker Engine itself only when
# the image is built for it. The Engine is the heavier of the Capsule's two
# inner engines and only some projects need true Engine behaviour, so
# CAPSULE_WITH_DOCKERD decides whether it is present.
packages="docker-buildx-plugin docker-ce-cli docker-compose-plugin"
if [ "${CAPSULE_WITH_DOCKERD:-0}" = "1" ]; then
    packages="${packages} docker-ce docker-ce-rootless-extras"
fi

# shellcheck disable=SC2086
apt-get -y --no-install-recommends install ${packages}

rm -rf "$0" /var/lib/apt/lists/*
