# Docker Claude Code with Azure AI Foundry
# Base: Ubuntu 24.04 LTS
FROM ubuntu:24.04

# Prevent interactive prompts during installation
ENV DEBIAN_FRONTEND=noninteractive

# Install system prerequisites
RUN apt-get update && apt-get install -y \
    curl \
    wget \
    git \
    ca-certificates \
    gnupg \
    lsb-release \
    software-properties-common \
    apt-transport-https \
    unzip \
    && rm -rf /var/lib/apt/lists/*

# Install Azure CLI
RUN curl -sL https://aka.ms/InstallAzureCLIDeb | bash

# Install Python 3.12 (default) and 3.10 (deadsnakes) together
RUN add-apt-repository ppa:deadsnakes/ppa \
    && apt-get update \
    && apt-get install -y \
        python3 \
        python3-pip \
        python3-venv \
        python3.10 \
        python3.10-venv \
        python3.10-distutils \
    && rm -rf /var/lib/apt/lists/*

# Install uv (fast Python package installer)
# Using --break-system-packages is safe in containers
RUN pip3 install --break-system-packages --no-cache-dir uv

# Install Node.js 24 LTS, ripgrep, and tmux
RUN curl -fsSL https://deb.nodesource.com/setup_24.x | bash - \
    && apt-get install -y nodejs ripgrep tmux \
    && rm -rf /var/lib/apt/lists/*

# Symlink node to the macOS Homebrew path expected by host settings.json plugins
RUN mkdir -p /opt/homebrew/opt/node@24/bin \
    && ln -sf "$(which node)" /opt/homebrew/opt/node@24/bin/node

# Create container sentinel so Claude Code skips its built-in auto-updater
RUN touch /.dockerenv

# Create non-root user 'agent' with sudo access
# UID matches the host user to ensure proper file permissions on mounted volumes
ARG HOST_UID=501
RUN useradd -m -s /bin/bash -u $HOST_UID agent && \
    usermod -aG sudo agent && \
    echo "agent ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

# Install Claude Code CLI as the agent user
USER agent
WORKDIR /home/agent
# Bust cache for Claude Code installation to get latest version
ARG CLAUDE_CODE_VERSION=latest
RUN curl -fsSL https://claude.ai/install.sh | bash

# Create wrapper script for claude-auto so it works in all shell contexts
RUN mkdir -p /home/agent/.local/bin && \
    printf '#!/bin/bash\nexec claude --dangerously-skip-permissions "$@"\n' > /home/agent/.local/bin/claude-auto && \
    chmod 755 /home/agent/.local/bin/claude-auto

# Configure shell: PATH and terminal colors
RUN echo 'export PATH="$HOME/.local/bin:$PATH"' >> /home/agent/.bashrc && \
    echo 'export TERM=xterm-256color' >> /home/agent/.bashrc && \
    echo 'export CLICOLOR=1' >> /home/agent/.bashrc && \
    echo 'export GREP_COLOR="1;33"' >> /home/agent/.bashrc && \
    echo 'test -r ~/.dircolors && eval "$(dircolors -b ~/.dircolors)" || eval "$(dircolors -b)"' >> /home/agent/.bashrc && \
    echo 'alias ls="ls --color=auto"' >> /home/agent/.bashrc && \
    echo 'alias grep="grep --color=auto"' >> /home/agent/.bashrc && \
    echo 'alias diff="diff --color=auto"' >> /home/agent/.bashrc && \
    echo 'PS1="\[\033[01;32m\]\u@\h\[\033[00m\]:\[\033[01;34m\]\w\[\033[00m\]\$ "' >> /home/agent/.bashrc

# Switch back to root for remaining setup
USER root

# Set PATH environment variable so claude works in both interactive and non-interactive shells
ENV PATH="/home/agent/.local/bin:${PATH}"

# Set terminal type for better color support
ENV TERM=xterm-256color

# Create directory for default settings template
RUN mkdir -p /opt/claude-defaults

# Copy settings.json template to a safe location
# (The actual /home/agent/.claude will be mounted from host)
COPY settings.json /opt/claude-defaults/settings.json

# Copy custom dircolors for better terminal colors
COPY dircolors /home/agent/.dircolors
RUN chown agent:agent /home/agent/.dircolors

# Copy entrypoint script
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod 755 /usr/local/bin/entrypoint.sh

# Set working directory to where workspace will be mounted
WORKDIR /workspace

# Change ownership of workspace to agent user
RUN chown -R agent:agent /workspace

# Switch to non-root user
USER agent

ENTRYPOINT ["/bin/bash", "/usr/local/bin/entrypoint.sh"]

# Default command: interactive bash shell
CMD ["/bin/bash"]
