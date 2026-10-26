# adguard-vpn-docker-gateway

Route any Docker container through **AdGuard VPN**, with a kill switch. The official AdGuard VPN CLI runs in a small gateway container; other containers share its network and can only reach the internet through the tunnel. If the VPN drops, their traffic is blocked instead of leaking over your normal connection.

Popular VPN gateway images like gluetun cover many providers, but as far as I know not AdGuard VPN. This repository fills that gap with plain Debian, the official CLI and a few lines of shell. qBittorrent is included as an example; any other service works the same way.

## How it works

```
LAN ──> host port 8888 ──> [ vpn container ] ── tun0 ──> AdGuard VPN ──> internet
                              │   eth0: only root (the VPN client) and LAN replies
                              │
                     shared network stack
                              │
                        [ qbittorrent ]   (network_mode: service:vpn, non-root)
```

1. The `vpn` container (Debian 13 slim) installs `iptables`, `iproute2`, `curl` and the AdGuard VPN CLI with the official install script on its first start.
2. Before anything connects, it sets a kill switch: outgoing traffic on `eth0` is only allowed for root (the VPN client itself), for the LAN and for the Docker network. Everything else must leave through `tun0`. IPv6 is disabled.
3. It connects in TUN mode, checks the connection every 30 seconds and reconnects if needed.
4. Services with `network_mode: "service:vpn"` use exactly this network stack. They run as a non-root user, so the kill switch applies to them.
5. Policy routes keep replies to your LAN on `eth0`, so web interfaces stay reachable while all internet traffic goes through the tunnel.

## Tested setup

Running since October 2026 on a UGREEN NAS (UGOS Pro, x86_64) with AdGuard VPN CLI 1.7.12, Debian 13, iptables 1.8.11 (nf_tables) and qBittorrent 5.2.4 behind it. With the VPN connected, the public IP seen from the qBittorrent user belonged to a VPN data center; with the VPN disconnected, a request as that user was blocked and no DNS packets left through `eth0`.

The script in this repository is the same as in that setup, with English messages and configurable defaults. Its kill switch was checked again in a throwaway container before publishing.

## Requirements

- Docker with Compose v2 on Linux (NAS, server, Raspberry Pi, VM). The host needs `/dev/net/tun`.
- An AdGuard VPN account.
- Your LAN subnet, for example `192.168.1.0/24`.

## Quick start

```bash
git clone https://github.com/Githubtezla/adguard-vpn-docker-gateway.git
cd adguard-vpn-docker-gateway
```

1. In `docker-compose.yaml` set `LAN_SUBNET` to your home network and `TZ` to your time zone. Optionally bind the published port to your server's LAN IP (`"192.168.1.10:8888:8888"`).
2. Start only the gateway first:

```bash
docker compose up -d vpn
docker compose logs -f vpn
```

3. The first start installs the packages and the CLI, then reports that there is no connection. Log in once:

```bash
docker exec -it adguard-vpn adguardvpn-cli login
```

Open the link it prints in a browser and confirm with your AdGuard account. The login is stored in `./vpn-data`. Within 30 seconds the container connects; the log shows the location.

4. Start the rest:

```bash
docker compose up -d
```

5. Check that it works. The first command shows the VPN's public IP, not yours:

```bash
docker exec -u 1000 qbittorrent curl -s https://ifconfig.me
docker exec adguard-vpn adguardvpn-cli status
```

## Adding your own services

```yaml
  myservice:
    image: example/myservice:1.2.3
    network_mode: "service:vpn"
    depends_on:
      vpn:
        condition: service_healthy
    user: "1000:1000"          # never root, see below
```

- Publish its ports on the `vpn` service, not on the service itself (a container with `network_mode: service:...` cannot publish ports).
- The service must not run as root. The kill switch lets root out through `eth0`, because the VPN client runs as root. For linuxserver.io images that means `PUID` not `0`.

## Configuration

| Variable (vpn service) | Default | Meaning |
| --- | --- | --- |
| `LAN_SUBNET` | `192.168.1.0/24` | Your home network. Traffic to it bypasses the tunnel (needed for web interfaces). |
| `VPN_LOCATION` | empty | Empty means the fastest server; otherwise a location as listed by `adguardvpn-cli list-locations`. |
| `CHECK_INTERVAL` | `30` | Seconds between connection checks. |
| `LOG_LIMIT_BYTES` | `5242880` | The CLI's `app.log` and `tunnel.log` are emptied when they grow past this size. |

## Things that cost me time

- **Login lost after every re-creation.** The CLI binds its login to the device: `/etc/machine-id`, otherwise the MAC address. A new container has neither. The script keeps a machine ID in `./vpn-data` and copies it to `/etc/machine-id` on start, and the compose file sets a fixed `mac_address`. Keep both.
- **Re-creating only the vpn container breaks the others.** Services with `network_mode: service:vpn` keep pointing to the old network namespace. After re-creating or restarting `vpn` alone, restart the whole project (`docker compose down && docker compose up -d`).
- **Service does not start, project shows an error.** Dependent services wait until the VPN is healthy. If the CLI is not logged in yet, they never start. Log in, then start the project again.
- **Root bypasses the tunnel.** That is how the VPN client itself gets out. Running a dependent service as root defeats the kill switch.
- **No port forwarding.** AdGuard VPN does not offer incoming ports, so peers cannot connect to you; outgoing connections work.
- **Growing logs.** The CLI appends to its logs on every status call; the script trims them (`LOG_LIMIT_BYTES`).

## Security notes

- The `vpn` container needs `NET_ADMIN` and `/dev/net/tun`. Dependent services need neither.
- The AdGuard VPN CLI is installed from AdGuard's official install script at first start. Pin or review it if that matters to you; the installed version is printed in the log.
- `./vpn-data` contains your AdGuard VPN login. Do not commit or share it; it is excluded in `.gitignore`.
- DNS inside the gateway uses Quad9 (`9.9.9.9`, `149.112.112.112`); with the tunnel up, these queries go through the tunnel.

## Credits and license

- [AdGuard VPN CLI](https://github.com/AdguardTeam/AdGuardVPNCLI) by AdGuard. This project is not affiliated with or endorsed by AdGuard.
- [linuxserver/qbittorrent](https://github.com/linuxserver/docker-qbittorrent) as the example service.
- Released under the [MIT License](LICENSE).
