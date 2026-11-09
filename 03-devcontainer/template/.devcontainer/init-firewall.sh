#!/bin/bash
# Egress firewall for the dev container.
# Based on anthropics/claude-code .devcontainer/init-firewall.sh (commit 0ed9469), hardened:
#   - DNS only to the container's configured resolvers, not to any server
#   - no blanket outbound SSH: port 22 only to GitHub (via the allowlist)
#   - IPv6 outbound blocked entirely
#   - allowlist baked into the image (allowed-domains.txt), so it can't be
#     changed from the workspace without a rebuild
# Runs as root via sudo at container start (postStartCommand). Re-running it is safe.
set -euo pipefail
IFS=$'\n\t'

ALLOWLIST=/usr/local/etc/allowed-domains.txt

# 1. Keep Docker's embedded DNS rules (user-defined networks) before flushing
DOCKER_DNS_RULES=$(iptables-save -t nat | grep "127\.0\.0\.11" || true)

iptables -F
iptables -X
iptables -t nat -F
iptables -t nat -X
iptables -t mangle -F
iptables -t mangle -X
ipset destroy allowed-domains 2>/dev/null || true

if [ -n "$DOCKER_DNS_RULES" ]; then
    echo "Restoring Docker DNS rules..."
    iptables -t nat -N DOCKER_OUTPUT 2>/dev/null || true
    iptables -t nat -N DOCKER_POSTROUTING 2>/dev/null || true
    echo "$DOCKER_DNS_RULES" | xargs -L 1 iptables -t nat
fi

# 2. Loopback
iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

# 3. DNS only to the resolvers this container is configured with
mapfile -t RESOLVERS < <(awk '/^nameserver/ {print $2}' /etc/resolv.conf | grep -E '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' || true)
if [ "${#RESOLVERS[@]}" -eq 0 ]; then
    echo "ERROR: no IPv4 nameserver in /etc/resolv.conf"
    exit 1
fi
for ns in "${RESOLVERS[@]}"; do
    echo "Allowing DNS to $ns"
    iptables -A OUTPUT -p udp -d "$ns" --dport 53 -j ACCEPT
    iptables -A OUTPUT -p tcp -d "$ns" --dport 53 -j ACCEPT
done

# 4. Allowed destinations
ipset create allowed-domains hash:net

echo "Fetching GitHub IP ranges..."
gh_ranges=$(curl -fsS --connect-timeout 10 https://api.github.com/meta)
if ! echo "$gh_ranges" | jq -e '.web and .api and .git' >/dev/null; then
    echo "ERROR: GitHub meta response missing required fields"
    exit 1
fi
while read -r cidr; do
    if [[ ! "$cidr" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$ ]]; then
        echo "ERROR: invalid CIDR from GitHub meta: $cidr"
        exit 1
    fi
    ipset add allowed-domains "$cidr"
done < <(echo "$gh_ranges" | jq -r '(.web + .api + .git)[] | select(contains(":") | not)' | aggregate -q)
echo "Added GitHub ranges"

while read -r domain; do
    domain="${domain%%#*}"
    domain="$(echo "$domain" | tr -d '[:space:]')"
    [ -z "$domain" ] && continue
    ips=$(dig +noall +answer A "$domain" | awk '$4 == "A" {print $5}')
    if [ -z "$ips" ]; then
        echo "ERROR: failed to resolve $domain"
        exit 1
    fi
    while read -r ip; do
        if [[ ! "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            echo "ERROR: invalid IP for $domain: $ip"
            exit 1
        fi
        ipset -exist add allowed-domains "$ip"
    done <<< "$ips"
    echo "Allowed $domain"
done < "$ALLOWLIST"

# 5. The container's own network (compose sidecars such as databases)
HOST_IP=$(ip route | awk '/^default/ {print $3; exit}')
if [ -z "$HOST_IP" ]; then
    echo "ERROR: failed to detect gateway"
    exit 1
fi
HOST_NETWORK=$(echo "$HOST_IP" | sed 's/\.[0-9]*$/.0\/24/')
echo "Container network: $HOST_NETWORK"
iptables -A INPUT -s "$HOST_NETWORK" -j ACCEPT
iptables -A OUTPUT -d "$HOST_NETWORK" -j ACCEPT

# 6. Default deny
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT DROP
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m set --match-set allowed-domains dst -j ACCEPT
iptables -A OUTPUT -j REJECT --reject-with icmp-admin-prohibited

# 7. IPv6: no outbound at all
if command -v ip6tables >/dev/null && ip6tables -L -n >/dev/null 2>&1; then
    ip6tables -F
    ip6tables -A INPUT -i lo -j ACCEPT
    ip6tables -A OUTPUT -o lo -j ACCEPT
    ip6tables -P INPUT DROP
    ip6tables -P FORWARD DROP
    ip6tables -P OUTPUT DROP
    echo "IPv6 blocked"
fi

echo "Firewall configured. Verifying..."

# 8. Verify
if curl -fsS --connect-timeout 5 https://example.com >/dev/null 2>&1; then
    echo "ERROR: firewall verification failed: example.com is reachable"
    exit 1
fi
echo "OK: example.com blocked"

if ! curl -fsS --connect-timeout 5 https://api.github.com/zen >/dev/null 2>&1; then
    echo "ERROR: firewall verification failed: api.github.com is not reachable"
    exit 1
fi
echo "OK: api.github.com reachable"

if ! curl -sS --connect-timeout 5 -o /dev/null https://api.anthropic.com 2>/dev/null; then
    echo "ERROR: firewall verification failed: api.anthropic.com is not reachable"
    exit 1
fi
echo "OK: api.anthropic.com reachable"

echo "Firewall verification passed"
