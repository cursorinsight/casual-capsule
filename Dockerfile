#------------------------------------------------------------------------------
# Runtime
#------------------------------------------------------------------------------
FROM jdxcode/mise:2026.2 AS runtime
WORKDIR /app
RUN apt-get update && \
    apt-get install -y --no-install-recommends git vim sudo && \
    rm -rf /var/lib/apt/lists/*

# Add user
RUN useradd -g 100 -m -u 8888 user

# Set up ownership in home
RUN mkdir -p /home/user/.codex /home/user/.config \
    /home/user/.local/share/gh && chown user: -Rh /home/user

# Initialize mise root for 'user'
RUN mkdir -p /mise && chown -Rh user: /mise

# Automatically activate mise
RUN echo 'eval "$(mise activate bash)"' >> /etc/profile

# Switch user
USER user

# Install nodejs
RUN mise use -g node@24
RUN mise install

# Install golang
RUN mise use -g golang@latest

# Install Codex
RUN npm install -g npm@11.4.0
RUN npm -g install @openai/codex open-codex openai

# Install Copilot and vim extension
RUN npm -g install @github/copilot
RUN mkdir -p /home/user/.vim/pack/github/start && \
    git clone https://github.com/github/copilot.vim \
        /home/user/.vim/pack/github/start/copilot.vim

# Remove mise's original entrypoint
ENTRYPOINT []

# Finalize installation/configuration
RUN mkdir -p ~/.codex && echo '{ "model": "o4-mini" }' > ~/.codex/config.json

# By default start CLI
CMD [ "/bin/bash" ]
#CMD [ "codex" ]
#CMD [ "copilot" ]
