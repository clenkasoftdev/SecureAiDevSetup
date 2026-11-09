# Dev container: Claude Code + .NET 10 + Python (uv), behind the egress firewall.
# The phase 3 template with the .NET and Python + uv recipes applied
# (03-devcontainer/toolchains/dotnet.md and python-uv.md).
#
# Three images are pinned by digest: replace each <digest> (see phase 5, Step 1).

# [A] Toolchain build stages
FROM mcr.microsoft.com/dotnet/sdk:10.0@sha256:212fe4cb74627d5adf9817a4088906ae3edff1bd853bb27565d4b46731efe61e AS dotnet-sdk
FROM ghcr.io/astral-sh/uv:0.13.7@sha256:96f40d3904aad8d0bd010539001d36c8e2188b981e1334471a90c4a1d93bb490 AS uv

FROM node:24-trixie@sha256:5c6e2e57d7dd6652ce6f087ba0328312059d7c77f93baa8751865dbf103f1acb

ARG TZ=Europe/Berlin
ENV TZ="$TZ"

ARG CLAUDE_CODE_VERSION

# [B] libicu76 for .NET
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl git less procps sudo fzf man-db unzip gnupg2 nano jq \
      openssh-client iptables ipset iproute2 dnsutils aggregate libicu76 \
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

USER root

# [C] .NET SDK
COPY --from=dotnet-sdk /usr/share/dotnet /usr/share/dotnet
RUN ln -s /usr/share/dotnet/dotnet /usr/local/bin/dotnet
ENV DOTNET_ROOT=/usr/share/dotnet \
    DOTNET_CLI_TELEMETRY_OPTOUT=1 \
    DOTNET_NOLOGO=1 \
    DOTNET_CLI_WORKLOAD_UPDATE_NOTIFY_DISABLE=1 \
    DOTNET_GENERATE_ASPNET_CERTIFICATE=false

# [C] uv
COPY --from=uv /uv /uvx /usr/local/bin/

# Firewall: script and allowlist owned by root; node may run only this script as root
COPY init-firewall.sh /usr/local/bin/init-firewall.sh
COPY allowed-domains.txt /usr/local/etc/allowed-domains.txt
RUN chmod 0755 /usr/local/bin/init-firewall.sh \
    && chmod 0644 /usr/local/etc/allowed-domains.txt \
    && echo "node ALL=(root) NOPASSWD: /usr/local/bin/init-firewall.sh" > /etc/sudoers.d/node-firewall \
    && chmod 0440 /etc/sudoers.d/node-firewall
USER node

# [D] Python, installed by uv at build time; no Python downloads afterwards
ARG PYTHON_VERSION=3.13
RUN uv python install "$PYTHON_VERSION" && uv python list --only-installed
ENV UV_PYTHON_DOWNLOADS=never \
    UV_PYTHON_PREFERENCE=only-managed \
    UV_LINK_MODE=copy \
    PATH=/home/node/.local/bin:$PATH
