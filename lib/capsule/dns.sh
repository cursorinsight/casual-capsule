#!/usr/bin/env bash

# On a Mac, the podman backend runs Capsules in a VM whose own resolver
# does not answer quickly on every network. Pass the Mac's resolvers in
# instead of forwarding lookups through podman machine's resolver.

# Print the DNS servers a Capsule should use, one per line, or nothing to keep
# the engine's own resolver: CAPSULE_DNS when set, else on macOS the IPv4
# servers macOS keeps in /etc/resolv.conf. Loopback servers are skipped,
# because a VM cannot reach the host's loopback. CAPSULE_DNS=none keeps the
# engine's resolver; any entry that is not an address fails.
capsule_dns_servers() {
  local servers="${CAPSULE_DNS:-}"
  local server=""

  if [[ "$servers" == "none" ]]; then
    return 0
  fi

  if [[ -n "$servers" ]]; then
    for server in ${servers//,/ }; do
      [[ "$server" =~ ^[0-9A-Fa-f.:]+$ ]] || return 1
      printf '%s\n' "$server"
    done
    return 0
  fi

  [[ "$(uname -s)" == "Darwin" ]] || return 0
  awk '
    $1 == "nameserver" && $2 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ &&
      $2 !~ /^127\./ { print $2 }
  ' "${CAPSULE_RESOLV_CONF:-/etc/resolv.conf}" 2>/dev/null || true
}
