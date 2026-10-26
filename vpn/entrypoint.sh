#!/bin/sh
# VPN gateway container: AdGuard VPN CLI in TUN mode with a kill switch.
# Other containers share this network stack (network_mode: service:vpn) and must
# run as a non-root user. The firewall lets only root (the VPN client) and replies
# to the LAN out through eth0; everything else has to go through the tunnel (tun+).
set -u

LAN_SUBNET="${LAN_SUBNET:-192.168.1.0/24}"
VPN_LOCATION="${VPN_LOCATION:-}"
CHECK_INTERVAL="${CHECK_INTERVAL:-30}"
LOG_LIMIT_BYTES="${LOG_LIMIT_BYTES:-5242880}"
INSTALL_URL="https://raw.githubusercontent.com/AdguardTeam/AdGuardVPNCLI/master/scripts/release/install.sh"
DATA_DIR="/root/.local/share/adguardvpn-cli"
export USER=root HOME=/root DEBIAN_FRONTEND=noninteractive

log() { echo "[vpn] $(date '+%F %T') $*"; }

# Applied first on every start (as soon as iptables is installed).
apply_killswitch() {
  ipt="$1"
  docker_net="$(ip -4 route show dev eth0 scope link 2>/dev/null | awk '{print $1; exit}')"
  "$ipt" -P OUTPUT ACCEPT || return 1
  "$ipt" -F OUTPUT || return 1
  "$ipt" -A OUTPUT -o lo -j ACCEPT || return 1
  "$ipt" -A OUTPUT -o tun+ -j ACCEPT || return 1
  "$ipt" -A OUTPUT -d "$LAN_SUBNET" -j ACCEPT || return 1
  if [ -n "$docker_net" ]; then
    "$ipt" -A OUTPUT -d "$docker_net" -j ACCEPT || return 1
  fi
  # only root (the VPN client itself) may use eth0 to reach the internet
  "$ipt" -A OUTPUT -m owner --uid-owner 0 -j ACCEPT || return 1
  "$ipt" -A OUTPUT -j REJECT 2>/dev/null || true
  "$ipt" -P OUTPUT DROP || return 1
  return 0
}

killswitch() {
  for ipt in iptables iptables-legacy; do
    command -v "$ipt" >/dev/null 2>&1 || continue
    if apply_killswitch "$ipt"; then
      log "kill switch active ($ipt)"
      # no IPv6 at all, except loopback
      for ip6 in ip6tables ip6tables-legacy; do
        command -v "$ip6" >/dev/null 2>&1 || continue
        "$ip6" -P OUTPUT DROP 2>/dev/null && "$ip6" -F OUTPUT 2>/dev/null \
          && "$ip6" -A OUTPUT -o lo -j ACCEPT 2>/dev/null && break
      done
      return 0
    fi
  done
  return 1
}

# Replies of web interfaces must go back to the LAN through eth0,
# even after the VPN client has taken over the default route.
lan_routes() {
  gw="$(ip -4 route show default dev eth0 2>/dev/null | awk '{print $3; exit}')"
  [ -n "$gw" ] && echo "$gw" > /tmp/eth0-gw
  gw="$(cat /tmp/eth0-gw 2>/dev/null)"
  [ -n "$gw" ] || return 0
  ip route replace "$LAN_SUBNET" via "$gw" dev eth0 2>/dev/null
  ip rule show | grep -q "to $LAN_SUBNET lookup main" \
    || ip rule add to "$LAN_SUBNET" lookup main priority 100 2>/dev/null
  docker_net="$(ip -4 route show dev eth0 scope link 2>/dev/null | awk '{print $1; exit}')"
  if [ -n "$docker_net" ]; then
    ip rule show | grep -q "to $docker_net lookup main" \
      || ip rule add to "$docker_net" lookup main priority 101 2>/dev/null
  fi
}

connected() { adguardvpn-cli status 2>/dev/null | grep -q "Connected to"; }

# The VPN client's logs grow with every status call; empty them above LOG_LIMIT_BYTES.
trim_logs() {
  for f in "$DATA_DIR/app.log" "$DATA_DIR/tunnel.log"; do
    [ -f "$f" ] || continue
    size="$(stat -c %s "$f" 2>/dev/null || echo 0)"
    if [ "$size" -gt "$LOG_LIMIT_BYTES" ]; then : > "$f"; fi
  done
  return 0
}

connect() {
  if [ -n "$VPN_LOCATION" ]; then
    adguardvpn-cli connect -y -l "$VPN_LOCATION"
  else
    adguardvpn-cli connect -y -f
  fi
}

# The VPN client binds its login to the device (/etc/machine-id, otherwise the MAC
# address). Both must survive container re-creation or the login is lost:
# the ID is kept in the data volume, the MAC is fixed in docker-compose.yaml.
machine_id() {
  store="$DATA_DIR/machine-id"
  mkdir -p "$DATA_DIR"
  if [ ! -s "$store" ]; then
    tr -d '-' < /proc/sys/kernel/random/uuid > "$store" || return 1
    chmod 600 "$store"
    log "created a new machine ID"
  fi
  cp "$store" /etc/machine-id && chmod 444 /etc/machine-id
}

# --- start -----------------------------------------------------------------
machine_id || { log "ERROR: cannot set machine ID, stopping"; exit 1; }
if command -v iptables >/dev/null 2>&1; then
  killswitch || { log "ERROR: cannot set up the kill switch, stopping"; exit 1; }
fi

if ! command -v iptables >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1 \
   || ! command -v ip >/dev/null 2>&1; then
  log "installing packages (first start only)"
  apt-get update -qq && apt-get install -y -qq --no-install-recommends \
    ca-certificates curl iproute2 iptables procps >/dev/null \
    || { log "ERROR: package installation failed"; exit 1; }
  rm -rf /var/lib/apt/lists/*
  killswitch || { log "ERROR: cannot set up the kill switch, stopping"; exit 1; }
fi

[ -c /dev/net/tun ] || { log "ERROR: /dev/net/tun is missing"; exit 1; }

if ! command -v adguardvpn-cli >/dev/null 2>&1; then
  log "installing AdGuard VPN CLI (official install script)"
  cd /tmp && curl -fsSL "$INSTALL_URL" | sh -s -- -v -a y \
    || { log "ERROR: installing adguardvpn-cli failed"; exit 1; }
fi
adguardvpn-cli --version 2>/dev/null | head -n 1

adguardvpn-cli config set-mode TUN >/dev/null 2>&1
adguardvpn-cli config set-tun-routing-mode AUTO >/dev/null 2>&1
adguardvpn-cli config send-reports off >/dev/null 2>&1
adguardvpn-cli config set-show-hints off >/dev/null 2>&1

trap 'log "stopping"; adguardvpn-cli disconnect >/dev/null 2>&1; exit 0' TERM INT

lan_routes
hinted=0
while true; do
  if connected; then
    lan_routes
    hinted=0
  else
    log "not connected, connecting (location: ${VPN_LOCATION:-fastest})"
    connect 2>&1 | tail -n 5
    sleep 3
    if connected; then
      lan_routes
      log "$(adguardvpn-cli status 2>/dev/null | head -n 1)"
    elif [ "$hinted" -eq 0 ]; then
      log "no connection. If you have not logged in yet: open a shell in this container,"
      log "run 'adguardvpn-cli login' and open the link it prints in your browser."
      hinted=1
    fi
  fi
  trim_logs
  sleep "$CHECK_INTERVAL" &
  wait $!
done
