#!/bin/bash
# Egress firewall for the dev container.
# Based on anthropics/claude-code .devcontainer/init-firewall.sh (commit 0ed9469), hardened:
#   - DNS only to the container's configured resolvers, not to any server
#   - no blanket outbound SSH: port 22 only to GitHub (via the allowlist)
#   - IPv6 outbound blocked entirely
#   - allowlist baked into the image (allowed-domains.txt), so it can't be
#     changed from the workspace without a rebuild
#   - CDN-friendly: each domain is resolved several times, and the allowed
#     addresses are refreshed every few minutes by a root background process
#
# Usage (as root, via sudo):
#   init-firewall.sh            first run: build the rules; later runs: refresh addresses
#   init-firewall.sh --refresh  refresh the allowed addresses only (used by the refresher)
#
# Refreshing never opens the firewall: the rules stay in place and the address
# set is rebuilt alongside, then swapped in atomically.
set -Eeuo pipefail
IFS=$'\n\t'

ALLOWLIST=/usr/local/etc/allowed-domains.txt
SET=allowed-domains
REFRESH_SECONDS=300
RESOLVE_ROUNDS=4
PIDFILE=/run/firewall-refresher.pid

log() { echo "$*"; }

rules_present() {
    iptables -C OUTPUT -m set --match-set "$SET" dst -j ACCEPT 2>/dev/null
}

# Build a fresh address set from GitHub's ranges and the allowlist, then swap it in.
refresh_addresses() {
    local tmp="${SET}-new"
    ipset create "$SET" hash:net -exist
    ipset create "$tmp" hash:net -exist
    ipset flush "$tmp"

    local gh_ranges
    gh_ranges=$(curl -fsS --connect-timeout 10 https://api.github.com/meta)
    if ! echo "$gh_ranges" | jq -e '.web and .api and .git' >/dev/null; then
        log "ERROR: GitHub meta response missing required fields"
        return 1
    fi
    while read -r cidr; do
        if [[ ! "$cidr" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$ ]]; then
            log "ERROR: invalid CIDR from GitHub meta: $cidr"
            return 1
        fi
        ipset -exist add "$tmp" "$cidr"
    done < <(echo "$gh_ranges" | jq -r '(.web + .api + .git)[] | select(contains(":") | not)' | aggregate -q)

    local domain ips ip round
    while read -r domain; do
        domain="${domain%%#*}"
        domain="$(echo "$domain" | tr -d '[:space:]')"
        [ -z "$domain" ] && continue
        ips=""
        for round in $(seq "$RESOLVE_ROUNDS"); do
            ips+=$'\n'"$(dig +noall +answer A "$domain" | awk '$4 == "A" {print $5}')"
            if [ "$round" -lt "$RESOLVE_ROUNDS" ]; then sleep 0.2; fi
        done
        ips=$(echo "$ips" | sed '/^$/d' | sort -u)
        if [ -z "$ips" ]; then
            log "ERROR: failed to resolve $domain"
            return 1
        fi
        while read -r ip; do
            if [[ ! "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
                log "ERROR: invalid IP for $domain: $ip"
                return 1
            fi
            ipset -exist add "$tmp" "$ip"
        done <<< "$ips"
    done < "$ALLOWLIST"

    ipset swap "$tmp" "$SET"
    ipset destroy "$tmp"
}

# First run only: start from an open state and build the rules.
build_rules() {
    local docker_dns_rules
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

    # Populate the address set while the network is still open
    log "Resolving allowed destinations..."
    refresh_addresses

    iptables -A INPUT -i lo -j ACCEPT
    iptables -A OUTPUT -o lo -j ACCEPT
    iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
    iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

    # DNS only to the resolvers this container is configured with
    local resolvers ns
    resolvers=$(awk '/^nameserver/ {print $2}' /etc/resolv.conf | grep -E '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' || true)
    if [ -z "$resolvers" ]; then
        log "ERROR: no IPv4 nameserver in /etc/resolv.conf"
        return 1
    fi
    while read -r ns; do
        log "Allowing DNS to $ns"
        iptables -A OUTPUT -p udp -d "$ns" --dport 53 -j ACCEPT
        iptables -A OUTPUT -p tcp -d "$ns" --dport 53 -j ACCEPT
    done <<< "$resolvers"

    # The container's own network (compose sidecars such as databases)
    local host_ip host_network
    host_ip=$(ip route | awk '/^default/ {print $3; exit}')
    if [ -z "$host_ip" ]; then
        log "ERROR: failed to detect gateway"
        return 1
    fi
    host_network=$(echo "$host_ip" | sed 's/\.[0-9]*$/.0\/24/')
    log "Container network: $host_network"
    iptables -A INPUT -s "$host_network" -j ACCEPT
    iptables -A OUTPUT -d "$host_network" -j ACCEPT

    iptables -A OUTPUT -m set --match-set "$SET" dst -j ACCEPT
    iptables -A OUTPUT -j REJECT --reject-with icmp-admin-prohibited
    iptables -P INPUT DROP
    iptables -P FORWARD DROP
    iptables -P OUTPUT DROP

    # IPv6: no outbound at all
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
    log "Address refresh every ${REFRESH_SECONDS}s (pid $(cat "$PIDFILE"))"
}

verify() {
    if curl -fsS --connect-timeout 5 https://example.com >/dev/null 2>&1; then
        log "ERROR: firewall verification failed: example.com is reachable"
        return 1
    fi
    log "OK: example.com blocked"
    if ! curl -fsS --connect-timeout 5 https://api.github.com/zen >/dev/null 2>&1; then
        log "ERROR: firewall verification failed: api.github.com is not reachable"
        return 1
    fi
    log "OK: api.github.com reachable"
    if ! curl -sS --connect-timeout 5 -o /dev/null https://api.anthropic.com 2>/dev/null; then
        log "ERROR: firewall verification failed: api.anthropic.com is not reachable"
        return 1
    fi
    log "OK: api.anthropic.com reachable"
}

if [ "${1:-}" = "--refresh" ]; then
    rules_present || { log "ERROR: firewall rules not present; run without --refresh"; exit 1; }
    refresh_addresses
    log "Allowed addresses refreshed"
    exit 0
fi

if rules_present; then
    log "Firewall already configured: refreshing allowed addresses"
    refresh_addresses
else
    log "Configuring firewall"
    # Fail closed: if setup stops partway, block all outbound traffic
    trap 'iptables -P OUTPUT DROP; iptables -P INPUT DROP; ip6tables -P OUTPUT DROP 2>/dev/null || true; log "ERROR: firewall setup failed: outbound traffic blocked. Restart the container to retry."' ERR
    build_rules
    trap - ERR
fi

start_refresher
log "Verifying..."
verify
log "Firewall verification passed"
