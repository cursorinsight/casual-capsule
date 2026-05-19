# Disabled hadolint checkers:
#  - DL3002: Last user should not be root.
#  - DL3008: Pin versions in `apt-get install`.
# hadolint global ignore=DL3002,DL3008

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
COPY --chmod=700 docker/setup-docker.sh /tmp
RUN --mount=type=cache,id=apt-global,sharing=locked,target=/var/cache/apt \
    /tmp/setup-docker.sh

# Add user (reuse existing group when GID already exists)
ARG CAPSULE_UID=1000
ARG CAPSULE_GID=100
RUN if ! getent group "${CAPSULE_GID}" >/dev/null 2>&1; then \
      groupadd -g "${CAPSULE_GID}" capsule; \
    fi && \
    useradd -l -m -u "${CAPSULE_UID}" \
      -g "${CAPSULE_GID}" -s /bin/bash user

WORKDIR /home/workspace

# Install mise
ARG MISE_VERSION=""
ENV MISE_INSTALL_PATH="/usr/local/bin/mise"
RUN curl -fsSL https://mise.run | sh

# Install system AI agents and tools with mise
ARG MISE_SYSTEM_TOOLS="bat codex copilot eza fd gh jq ripgrep usage uv"
RUN --mount=type=secret,id=github_api_token,env=GITHUB_API_TOKEN,required=false \
    mise install --system ${MISE_SYSTEM_TOOLS} && \
    mise use --path /etc/mise/config.toml --pin ${MISE_SYSTEM_TOOLS}

# Activate mise in interactive shells
COPY --chmod=644 docker/mise.sh /etc/profile.d/

# Copy entrypoint (owned by root for security)
COPY --chmod=755 docker/entrypoint.sh /usr/local/bin/

# Switch user
USER user

# GitHub token login
RUN --mount=type=secret,id=github_api_token,uid=${CAPSULE_UID},required=false \
    if [ -s /run/secrets/github_api_token ]; then \
        mise x -- gh auth login --with-token </run/secrets/github_api_token; \
    fi

# Install python and uv tools
ARG PYTHON_VERSION=3.14
RUN mise x -- uv python install --default ${PYTHON_VERSION} && \
    mise x -- uv tool install ruff && \
    mise x -- uv tool install ty

# Add mise shims to path
ENV PATH="/home/user/.local/share/mise/shims:/home/user/.local/bin:$PATH"

# Entrypoint runs as root, adjusts UID/GID, drops privileges
USER root
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["/bin/bash", "-il"]
