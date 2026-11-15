#!/bin/bash
# Egress firewall for the dev container: filter HTTPS by server NAME (SNI).
#
# Based on anthropics/claude-code .devcontainer/init-firewall.sh (commit 0ed9469), redesigned:
#   - HTTPS (tcp/443) from every process is redirected to a local SNI proxy (nginx stream,
#     ssl_preread). The proxy reads the server name from the TLS ClientHello, allows it only
#     if it's on the allowlist, and then connects to that NAME itself, so the address the
#     client asked for is ignored. No decryption: only the plaintext server name is read.
#   - Only the proxy's own user ("egress") may open outbound HTTPS. Nothing can go around it.
#   - SSH (tcp/22) only to GitHub's published IP ranges; DNS only to the configured resolvers.
#   - Everything else outbound, including all IPv6 and UDP/443 (QUIC), is blocked.
#   - Allowlist baked into the image (allowed-domains.txt); wildcards via ".example.com".
#   - Fails closed: if setup stops partway, outbound traffic is blocked.
#
# Usage (as root, via sudo):
#   init-firewall.sh            first run: build everything; later runs: refresh and check
#   init-firewall.sh --refresh  refresh GitHub's SSH ranges and restart the proxy if needed
set -Eeuo pipefail
IFS=$'\n\t'

ALLOWLIST=/usr/local/etc/allowed-domains.txt
PROXY_USER=egress
PROXY_PORT=8443
PROXY_DIR=/etc/egress-proxy
PROXY_STATE=/var/lib/egress-proxy
PROXY_LOGS=/var/log/egress-proxy
GH_SET=github-ssh
REFRESH_SECONDS=300
PIDFILE=/run/firewall-refresher.pid

log() { echo "$*"; }

rules_present() {
    iptables -C OUTPUT -p tcp --dport 443 -m owner --uid-owner "$PROXY_USER" -j ACCEPT 2>/dev/null
}

# The container's DNS servers. On Docker user-defined networks (compose), the nameserver is
# Docker's embedded resolver 127.0.0.11, which forwards queries from inside the container to
# the upstream servers Docker records in the "# ExtServers:" comment, so those are allowed too.
resolvers() {
    {
        awk '/^nameserver/ {print $2}' /etc/resolv.conf
        grep -E '^# ExtServers:' /etc/resolv.conf | grep -oE '[0-9]{1,3}(\.[0-9]{1,3}){3}'
    } | grep -E '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' | sort -u || true
}

# DNS servers nginx should use: the first nameserver line is enough.
proxy_resolvers() {
    awk '/^nameserver/ {print $2}' /etc/resolv.conf | grep -E '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' || true
}

# nginx map entries from the allowlist. "name" matches exactly; ".name" matches name and subdomains.
write_proxy_config() {
    local ns line count=0
    ns=$(proxy_resolvers | tr '\n' ' ')
    [ -n "$ns" ] || { log "ERROR: no IPv4 nameserver in /etc/resolv.conf"; return 1; }

    : > "$PROXY_DIR/allowed.map"
    while read -r line; do
        line="${line%%#*}"
        line="$(echo "$line" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
        [ -z "$line" ] && continue
        line="${line#\*}"                                   # "*.x" is written as ".x"
        if [[ ! "$line" =~ ^\.?[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]]; then
            log "ERROR: invalid allowlist entry: $line"
            return 1
        fi
        echo "$line 1;" >> "$PROXY_DIR/allowed.map"
        count=$((count + 1))
    done < "$ALLOWLIST"
    log "Allowlist: $count entries"

    cat > "$PROXY_DIR/nginx.conf" <<EOF
load_module /usr/lib/nginx/modules/ngx_stream_module.so;
worker_processes 1;
pid $PROXY_STATE/nginx.pid;
events { worker_connections 1024; }
stream {
    resolver $ns valid=30s ipv6=off;
    resolver_timeout 5s;
    map \$ssl_preread_server_name \$sni_allowed {
        hostnames;
        include $PROXY_DIR/allowed.map;
        default 0;
    }
    map \$sni_allowed \$sni_upstream {
        1       \$ssl_preread_server_name:443;
        default 127.0.0.1:1;
    }
    log_format sni '\$time_iso8601 \$ssl_preread_server_name allowed=\$sni_allowed status=\$status';
    access_log $PROXY_LOGS/access.log sni;
    server {
        listen 127.0.0.1:$PROXY_PORT;
        ssl_preread on;
        proxy_pass \$sni_upstream;
        proxy_connect_timeout 10s;
    }
}
EOF
    chmod 0644 "$PROXY_DIR/nginx.conf" "$PROXY_DIR/allowed.map"
}

proxy_running() {
    [ -f "$PROXY_STATE/nginx.pid" ] && kill -0 "$(cat "$PROXY_STATE/nginx.pid")" 2>/dev/null
}

start_proxy() {
    proxy_running && return 0
    install -d -o "$PROXY_USER" -g "$PROXY_USER" -m 0755 "$PROXY_STATE" "$PROXY_LOGS"
    runuser -u "$PROXY_USER" -- nginx -t -q -c "$PROXY_DIR/nginx.conf" -e "$PROXY_LOGS/error.log"
    runuser -u "$PROXY_USER" -- nginx -c "$PROXY_DIR/nginx.conf" -e "$PROXY_LOGS/error.log"
    log "SNI proxy running on 127.0.0.1:$PROXY_PORT as $PROXY_USER"
}

# GitHub's published ranges, for SSH (git@github.com) only.
refresh_github_ranges() {
    local tmp="${GH_SET}-new" gh cidr
    ipset create "$GH_SET" hash:net -exist
    ipset create "$tmp" hash:net -exist
    ipset flush "$tmp"
    gh=$(curl -fsS --connect-timeout 10 https://api.github.com/meta)
    echo "$gh" | jq -e '.git' >/dev/null || { log "ERROR: GitHub meta response missing .git"; return 1; }
    while read -r cidr; do
        [[ "$cidr" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$ ]] || { log "ERROR: invalid CIDR: $cidr"; return 1; }
        ipset -exist add "$tmp" "$cidr"
    done < <(echo "$gh" | jq -r '.git[] | select(contains(":") | not)' | aggregate -q)
    ipset swap "$tmp" "$GH_SET"
    ipset destroy "$tmp"
}

build_rules() {
    local docker_dns_rules ns host_ip host_network
    docker_dns_rules=$(iptables-save -t nat | grep "127\.0\.0\.11" || true)

    iptables -P INPUT ACCEPT
    iptables -P OUTPUT ACCEPT
    iptables -P FORWARD ACCEPT
    iptables -F
    iptables -X
    iptables -t nat -F
    iptables -t nat -X
    iptables -t mangle -F
    iptables -t mangle -X

    if [ -n "$docker_dns_rules" ]; then
        log "Restoring Docker DNS rules..."
        iptables -t nat -N DOCKER_OUTPUT 2>/dev/null || true
        iptables -t nat -N DOCKER_POSTROUTING 2>/dev/null || true
        echo "$docker_dns_rules" | xargs -L 1 iptables -t nat
    fi

    write_proxy_config
    start_proxy

    host_ip=$(ip route | awk '/^default/ {print $3; exit}')
    [ -n "$host_ip" ] || { log "ERROR: failed to detect gateway"; return 1; }
    host_network=$(echo "$host_ip" | sed 's/\.[0-9]*$/.0\/24/')
    log "Container network: $host_network"

    # Redirect all HTTPS to the proxy, except the proxy's own connections, loopback and sidecars
    iptables -t nat -A OUTPUT -d 127.0.0.0/8 -j RETURN
    iptables -t nat -A OUTPUT -d "$host_network" -j RETURN
    iptables -t nat -A OUTPUT -p tcp --dport 443 -m owner --uid-owner "$PROXY_USER" -j RETURN
    iptables -t nat -A OUTPUT -p tcp --dport 443 -j REDIRECT --to-ports "$PROXY_PORT"

    iptables -A INPUT -i lo -j ACCEPT
    iptables -A OUTPUT -o lo -j ACCEPT
    # Redirected connections keep their original output interface, so "-o lo" doesn't match them
    iptables -A OUTPUT -p tcp -d 127.0.0.1 --dport "$PROXY_PORT" -j ACCEPT
    iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
    iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

    while read -r ns; do
        log "Allowing DNS to $ns"
        iptables -A OUTPUT -p udp -d "$ns" --dport 53 -j ACCEPT
        iptables -A OUTPUT -p tcp -d "$ns" --dport 53 -j ACCEPT
    done < <(resolvers)

    iptables -A INPUT -s "$host_network" -j ACCEPT
    iptables -A OUTPUT -d "$host_network" -j ACCEPT

    # Only the proxy may open outbound HTTPS
    iptables -A OUTPUT -p tcp --dport 443 -m owner --uid-owner "$PROXY_USER" -j ACCEPT

    # The proxy is running, so GitHub's API is now reachable for its SSH ranges
    log "Fetching GitHub SSH ranges..."
    refresh_github_ranges
    iptables -A OUTPUT -p tcp --dport 22 -m set --match-set "$GH_SET" dst -j ACCEPT

    iptables -A OUTPUT -j REJECT --reject-with icmp-admin-prohibited
    iptables -P INPUT DROP
    iptables -P FORWARD DROP
    iptables -P OUTPUT DROP

    if command -v ip6tables >/dev/null && ip6tables -L -n >/dev/null 2>&1; then
        ip6tables -F
        ip6tables -A INPUT -i lo -j ACCEPT
        ip6tables -A OUTPUT -o lo -j ACCEPT
        ip6tables -P INPUT DROP
        ip6tables -P FORWARD DROP
        ip6tables -P OUTPUT DROP
        log "IPv6 blocked"
    fi
}

start_refresher() {
    if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
        return 0
    fi
    setsid nohup bash -c "while sleep $REFRESH_SECONDS; do $0 --refresh >/dev/null 2>&1 || true; done" \
        >/dev/null 2>&1 < /dev/null &
    echo $! > "$PIDFILE"
    log "Background refresh every ${REFRESH_SECONDS}s (pid $(cat "$PIDFILE"))"
}

verify() {
    if curl -fsS --connect-timeout 5 https://example.com >/dev/null 2>&1; then
        log "ERROR: firewall verification failed: example.com is reachable"
        return 1
    fi
    log "OK: example.com blocked"
    if ! curl -fsS --connect-timeout 10 https://api.github.com/zen >/dev/null 2>&1; then
        log "ERROR: firewall verification failed: api.github.com is not reachable"
        return 1
    fi
    log "OK: api.github.com reachable"
    if ! curl -sS --connect-timeout 10 -o /dev/null https://api.anthropic.com 2>/dev/null; then
        log "ERROR: firewall verification failed: api.anthropic.com is not reachable"
        return 1
    fi
    log "OK: api.anthropic.com reachable"
}

if [ "${1:-}" = "--refresh" ]; then
    rules_present || { log "ERROR: firewall rules not present; run without --refresh"; exit 1; }
    start_proxy
    refresh_github_ranges
    log "Refreshed"
    exit 0
fi

if rules_present; then
    log "Firewall already configured: checking proxy, refreshing GitHub ranges"
    start_proxy
    refresh_github_ranges
else
    log "Configuring firewall"
    # Fail closed: if setup stops partway, allow nothing out but loopback
    trap 'iptables -P OUTPUT DROP; iptables -P INPUT DROP; iptables -F OUTPUT; iptables -A OUTPUT -o lo -j ACCEPT; ip6tables -P OUTPUT DROP 2>/dev/null || true; log "ERROR: firewall setup failed: outbound traffic blocked. Restart the container to retry."' ERR
    build_rules
    trap - ERR
fi

start_refresher
log "Verifying..."
verify
log "Firewall verification passed"
