# syntax=docker/dockerfile:1.10
# Disabled hadolint checkers:
#  - DL3002: Last user should not be root.
#  - DL3008: Pin versions in `apt-get install`.
#  - DL3066: Non-numeric user-id may not be resolvable by host system.
# hadolint global ignore=DL3002,DL3008,DL3066

ARG DEBIAN_VERSION=trixie
ARG MISE_VERSION=latest

FROM ghcr.io/jdx/mise:${MISE_VERSION} AS mise

#------------------------------------------------------------------------------
# Runtime
#------------------------------------------------------------------------------
FROM debian:${DEBIAN_VERSION}-slim AS runtime

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# https://docs.docker.com/build/cache/
RUN --mount=type=cache,id=apt-global,sharing=locked,target=/var/cache/apt \
    apt-get update && \
    apt-get -y --no-install-recommends install \
    bash-completion build-essential busybox ca-certificates curl file git \
    gnupg less openssh-client procps shellcheck sudo tree unzip vim zip && \
    rm -rf /var/lib/apt/lists/* && \
    busybox --install -s

# setup docker source and install packages
ARG CAPSULE_WITH_DOCKERD=0
COPY --chmod=700 docker/setup-docker.sh /tmp
RUN --mount=type=cache,id=apt-global,sharing=locked,target=/var/cache/apt \
    CAPSULE_WITH_DOCKERD="${CAPSULE_WITH_DOCKERD}" /tmp/setup-docker.sh

# Install the Capsule's own container engine.
#
# podman answers the Docker API from inside the Capsule with nothing running
# at rest, so an agent's `docker` and `docker compose` work against an engine
# private to this Capsule. Every package here was needed to make that engine
# actually serve a project:
#
#   passt           pasta is podman's default rootless network; without it
#                   no container starts at all
#   nftables        netavark configures a project's own network through nft
#   aardvark-dns    resolves service names between a project's containers
#   catatonit       the init a compose `init: true` service asks for
#   fuse-overlayfs  stacks image layers inside a container, where the kernel
#                   overlay driver cannot (see docker/storage.conf)
#   uidmap          newuidmap, for mapping the nested engine's containers
#   netavark        podman's network backend; a dependency today, named here
#                   so a demotion to Recommends cannot silently remove it
RUN --mount=type=cache,id=apt-global,sharing=locked,target=/var/cache/apt \
    apt-get update && \
    apt-get -y --no-install-recommends install \
    aardvark-dns catatonit fuse-overlayfs netavark nftables passt podman \
    uidmap && \
    rm -rf /var/lib/apt/lists/*
COPY --chmod=644 docker/containers.conf docker/registries.conf \
    docker/storage.conf /etc/containers/

# Add user (reuse existing group when GID already exists)
ARG CAPSULE_UID=1000
ARG CAPSULE_GID=100
RUN if ! getent group "${CAPSULE_GID}" >/dev/null 2>&1; then \
      groupadd -g "${CAPSULE_GID}" capsule; \
    fi && \
    useradd -l -m -u "${CAPSULE_UID}" \
      -g "${CAPSULE_GID}" -s /bin/bash user

# Give "user" a sub-id range for the Capsule's inner engine, and a mountpoint
# for the per-workspace storage volume.
#
# Keep 65536 subordinate IDs inside keep-id's 0..65536 namespace, excluding
# the account's own ID. Split ranges retain IDs such as Debian's 65534 while
# avoiding overlaps at every nesting level.
RUN for id_type in uid gid; do \
      case "$id_type" in \
        uid) account_id="${CAPSULE_UID}" ;; \
        gid) account_id="${CAPSULE_GID}" ;; \
      esac; \
      awk -v account_id="$account_id" 'BEGIN { \
        low_count = account_id < 65536 ? account_id : 65536; \
        if (low_count > 0) printf "user:0:%d\n", low_count; \
        high_start = account_id + 1; \
        if (high_start <= 65536) \
          printf "user:%d:%d\n", high_start, 65537 - high_start; \
      }' >"/etc/sub${id_type}"; \
    done && \
    install -d -o "${CAPSULE_UID}" -g "${CAPSULE_GID}" \
      /var/lib/capsule/inner

WORKDIR /home/workspace

# Install mise from image
COPY --from=mise /usr/local/bin/mise /usr/local/bin/mise

# Install system AI agents and tools with mise
ARG PYTHON_VERSION=3.14
ARG MISE_SYSTEM_TOOLS="antigravity-cli bat codex claude eza fd \
        gh jq node python@${PYTHON_VERSION} ripgrep rtk ruff ty usage uv"
# Read the token from the secret file rather than an injected variable. The
# file form is what podman's build understands, and BuildKit serves it the
# same way, so one Dockerfile builds on either backend and the token still
# reaches no layer.
RUN --mount=type=secret,id=github_api_token \
    if [ -s /run/secrets/github_api_token ]; then \
      GITHUB_API_TOKEN="$(cat /run/secrets/github_api_token)" && \
      export GITHUB_API_TOKEN; \
    fi && \
    mise install --system ${MISE_SYSTEM_TOOLS} && \
    mise use --path /etc/mise/config.toml --pin ${MISE_SYSTEM_TOOLS}

# Keep Codex unrestricted through mise's native command wrapper.
RUN printf '\n[wrappers.codex]\ncommand = "%s"\n%s\n' \
      "$(mise which codex)" \
      'args = ["--dangerously-bypass-approvals-and-sandbox"]' \
      >>/etc/mise/config.toml

# Add mise shims to path
ENV PATH="/usr/local/share/mise/shims:$PATH"

# Activate mise in interactive shells
COPY --chmod=644 docker/mise.sh /etc/profile.d/

# Copy entrypoint (owned by root for security)
COPY --chmod=755 docker/entrypoint.sh /usr/local/bin/

# The Capsule's `docker` is the engine router, ahead of the real client on
# PATH; the same script under its own name manages which engine is active.
COPY --chmod=755 docker/capsule-docker.sh /usr/local/bin/capsule-docker
RUN ln -s /usr/local/bin/capsule-docker /usr/local/bin/docker

# Entrypoint runs as root, adjusts UID/GID, drops privileges
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["/bin/bash", "-il"]
