# syntax=docker/dockerfile:1.10
# Disabled hadolint checkers:
#  - DL3002: Last user should not be root.
#  - DL3008: Pin versions in `apt-get install`.
#  - DL3066: Non-numeric user-id may not be resolvable by host system.
# hadolint global ignore=DL3002,DL3008,DL3066

ARG DEBIAN_VERSION=trixie

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
# A nested rootless engine maps its containers into sub-ids of the account it
# runs as, so those ids must exist inside the Capsule's own user namespace and
# must not collide with the account's own id -- an overlapping map is refused
# by the kernel with EINVAL. The range is therefore placed above both ids.
RUN sub_start=3000; \
    if [ "${CAPSULE_UID}" -ge "${sub_start}" ] || \
       [ "${CAPSULE_GID}" -ge "${sub_start}" ]; then \
      sub_start=$((CAPSULE_UID > CAPSULE_GID ? CAPSULE_UID : CAPSULE_GID)); \
      sub_start=$((sub_start + 1)); \
    fi; \
    sub_count=$((63000 - sub_start)); \
    printf 'user:%s:%s\n' "${sub_start}" "${sub_count}" > /etc/subuid; \
    printf 'user:%s:%s\n' "${sub_start}" "${sub_count}" > /etc/subgid; \
    install -d -o "${CAPSULE_UID}" -g "${CAPSULE_GID}" \
      /var/lib/capsule/inner

WORKDIR /home/workspace

# Install mise
ARG MISE_VERSION=""
ENV MISE_INSTALL_PATH="/usr/local/bin/mise"
RUN curl -fsSL https://mise.run | sh

# Install system AI agents and tools with mise
ARG MISE_SYSTEM_TOOLS="antigravity-cli bat codex claude eza fd \
        gh jq node ripgrep usage uv rtk"
# Read the token from the secret file rather than an injected variable. The
# file form is what podman's build understands, and BuildKit serves it the
# same way, so one Dockerfile builds on either backend and the token still
# reaches no layer.
RUN --mount=type=secret,id=github_api_token,required=true \
    GITHUB_API_TOKEN="$(cat /run/secrets/github_api_token)" && \
    export GITHUB_API_TOKEN && \
    mise install --system ${MISE_SYSTEM_TOOLS} && \
    mise use --path /etc/mise/config.toml --pin ${MISE_SYSTEM_TOOLS}

# Keep Codex unrestricted inside the Capsule regardless of whether mise's
# direct install path or its system symlink resolves the command.
COPY --chmod=755 docker/codex.sh /usr/local/libexec/capsule/codex
RUN codex_path="$(mise which codex 2>/dev/null)"; \
    if [ -n "$codex_path" ] && [ -x "$codex_path" ]; then \
      mv "$codex_path" "${codex_path}-real"; \
      install -m 755 /usr/local/libexec/capsule/codex "$codex_path"; \
      ln -sf "$codex_path" /usr/local/bin/codex; \
      ln -sf "${codex_path}-real" /usr/local/bin/codex-real; \
    fi

# Activate mise in interactive shells
COPY --chmod=644 docker/mise.sh /etc/profile.d/

# Copy entrypoint (owned by root for security)
COPY --chmod=755 docker/entrypoint.sh /usr/local/bin/

# The Capsule's `docker` is the engine router, ahead of the real client on
# PATH; the same script under its own name manages which engine is active.
COPY --chmod=755 docker/capsule-docker.sh /usr/local/bin/capsule-docker
RUN ln -s /usr/local/bin/capsule-docker /usr/local/bin/docker

# Switch user
USER user

# Install python and uv tools
ARG PYTHON_VERSION=3.14
RUN mise x -- uv python install --default ${PYTHON_VERSION} && \
    mise x -- uv tool install ruff && \
    mise x -- uv tool install ty

# Add mise shims to path
ENV PATH="/usr/local/share/mise/shims:$PATH"

# Entrypoint runs as root, adjusts UID/GID, drops privileges
USER root
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["/bin/bash", "-il"]
