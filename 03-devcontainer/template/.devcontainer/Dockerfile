# Dev container image for Claude Code with an egress firewall.
# Based on anthropics/claude-code .devcontainer/Dockerfile (commit 0ed9469), hardened:
#   - supported Node.js LTS (24) on Debian 13 instead of end-of-life Node 20
#   - Claude Code version pinned; no auto-updates
#   - no third-party install scripts piped to sh (zsh theme, git-delta dropped)
#   - firewall allowlist baked into the image
#
# Pin the base image by digest once you've pulled it:
#   FROM node:24-trixie@sha256:<digest>
FROM node:24-trixie@sha256:5c6e2e57d7dd6652ce6f087ba0328312059d7c77f93baa8751865dbf103f1acb

ARG TZ=Europe/Berlin
ENV TZ="$TZ"

ARG CLAUDE_CODE_VERSION

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl git less procps sudo fzf man-db unzip gnupg2 nano jq \
      openssh-client iptables ipset iproute2 dnsutils aggregate nginx libnginx-mod-stream \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# npm global packages in a folder the node user owns
RUN mkdir -p /usr/local/share/npm-global && chown -R node:node /usr/local/share

# Persistent bash history and Claude Code config (both are volumes, see devcontainer.json)
RUN mkdir -p /commandhistory /workspace /home/node/.claude \
    && touch /commandhistory/.bash_history \
    && chown -R node:node /commandhistory /workspace /home/node/.claude

ENV DEVCONTAINER=true
WORKDIR /workspace

USER node
ENV NPM_CONFIG_PREFIX=/usr/local/share/npm-global
ENV PATH=$PATH:/usr/local/share/npm-global/bin
ENV EDITOR=nano VISUAL=nano
ENV NPM_CONFIG_UPDATE_NOTIFIER=false
RUN echo 'export PROMPT_COMMAND="history -a"; export HISTFILE=/commandhistory/.bash_history' >> /home/node/.bashrc

# Claude Code, pinned. Fail the build if no version was given.
RUN test -n "$CLAUDE_CODE_VERSION" || { echo "Set CLAUDE_CODE_VERSION in devcontainer.json"; exit 1; } \
    && npm install -g "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" \
    && claude --version

# Firewall: script and allowlist owned by root; node may run only this script as root
USER root
COPY init-firewall.sh /usr/local/bin/init-firewall.sh
COPY allowed-domains.txt /usr/local/etc/allowed-domains.txt
RUN chmod 0755 /usr/local/bin/init-firewall.sh \
    && chmod 0644 /usr/local/etc/allowed-domains.txt \
    && echo "node ALL=(root) NOPASSWD: /usr/local/bin/init-firewall.sh" > /etc/sudoers.d/node-firewall \
    && chmod 0440 /etc/sudoers.d/node-firewall
USER node
