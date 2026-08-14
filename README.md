# WireHole

## What is this?

WireHole is a docker-compose project that combines WireGuard, Pi-hole, and
Unbound to create a full or split tunnel VPN that is easy to deploy and
manage. This setup gives you a VPN with advertisement blocking through
Pi-hole, and better DNS privacy and caching through Unbound.

The stack gives you these functions:

- **A VPN server.** Your devices connect to your own server. Your traffic
  does not go through a public VPN provider.
- **Advertisement blocking.** Pi-hole blocks the advertisement domains and
  the tracker domains for every connected device.
- **Private DNS.** Unbound asks the authoritative name servers directly.
  Your DNS queries do not go to Google or to Cloudflare.
- **DNSSEC validation.** Unbound proves that an answer is authentic.

## How the stack works

```
   Your device                Your server
  +-----------+     +------------------------------------------+
  |           |     |                                          |
  | WireGuard |=====| VPN server -> Pi-hole -> Unbound ---> Internet
  |  client   | VPN |             (filter)   (resolver)   (root servers)
  |           |     |                                          |
  +-----------+     +------------------------------------------+
```

1. Your device sends all DNS queries to Pi-hole.
2. Pi-hole blocks the queries for the advertisement domains.
3. Pi-hole sends the other queries to Unbound.
4. Unbound asks the authoritative name servers and validates the answer.

## Requirements

- Docker Engine 20.10 or later, and the Docker Compose plugin v2.
- A server with a public IP address, or a dynamic DNS name.
- An open UDP port for the VPN. The default port is 51820.
- A machine with an amd64 processor or an arm64 processor.
  Raspberry Pi 3 and later models work.

Check your versions with these commands:

```bash
docker --version
docker compose version
```

## Quick start

```bash
# 1. Get the files.
git clone https://github.com/IAmStoxe/wirehole.git
cd wirehole

# 2. Make the configuration file with strong passwords.
#    The script also finds your public IP address.
./scripts/generate-secrets.sh

# 3. Read the file .env and check the value of VPN_HOST.
#    Set this value to your public IP address or to your domain name.
nano .env

# 4. Start the stack.
docker compose up -d

# 5. Look at the state of the containers.
docker compose ps
```

The script prints your new passwords. Write them in your password manager.

If you do not want the script, copy the file `.env.example` to `.env` and
set the values yourself:

```bash
cp .env.example .env
nano .env
```

You must set `VPN_HOST`, `PIHOLE_PASSWORD`, and `WG_EASY_PASSWORD`. The stack
does not start without these three values.

## Open the web interfaces

The stack publishes the web interfaces on the address 127.0.0.1 only. This
is a safety measure. Only the server itself can open the pages.

| Interface | Address                       | Password variable |
| --------- | ----------------------------- | ----------------- |
| VPN       | http://127.0.0.1:51821        | WG_EASY_PASSWORD  |
| Pi-hole   | http://127.0.0.1:8080/admin   | PIHOLE_PASSWORD   |

To open a page from another computer, use one of these methods:

**Method 1: an SSH tunnel.** This method is safe. Run this command on your
own computer:

```bash
ssh -L 51821:127.0.0.1:51821 -L 8080:127.0.0.1:8080 user@your-server
```

Then open `http://127.0.0.1:51821` in your browser.

**Method 2: the VPN.** Connect a client to the VPN first. Then open Pi-hole
at `http://10.2.0.100/admin`.

**Method 3: publish the ports.** Set `WEB_BIND_ADDRESS=0.0.0.0` in the file
`.env`. This method puts the web interfaces on your network. Do not use this
method on a public server without a reverse proxy with TLS. Read the file
[SECURITY.md](SECURITY.md).

## Add a VPN client

1. Open the VPN web interface at `http://127.0.0.1:51821`.
2. Sign in with the user name `admin` and your `WG_EASY_PASSWORD`.
3. Select **New Client** and give the client a name.
4. Read the QR code with the WireGuard application on your telephone.
   You can also download the configuration file for a computer.

Get the WireGuard client application from https://www.wireguard.com/install/.

## The two VPN back ends

The stack has two VPN back ends. Select one back end with the variable
`COMPOSE_PROFILES` in the file `.env`. Do not select two back ends. Two VPN
servers cannot use the same port.

### Profile `wg-easy` (the default)

```ini
COMPOSE_PROFILES=wg-easy
```

The image `ghcr.io/wg-easy/wg-easy` contains a WireGuard server and a web
interface. You add and remove the clients in your browser. Each client gets
a QR code. The project has an AGPL-3.0 license.

Use this back end if you want to manage the clients in a browser.

### Profile `wireguard`

```ini
COMPOSE_PROFILES=wireguard
```

The image `lscr.io/linuxserver/wireguard` contains a WireGuard server only.
It has no web interface. It writes a configuration file and a QR code for
each client to the directory `./data/wireguard`.

Set the clients with the variable `WIREGUARD_PEERS`:

```ini
# A number of clients:
WIREGUARD_PEERS=3

# Or a list of names:
WIREGUARD_PEERS=phone,laptop,tablet
```

Read a QR code from the log:

```bash
docker compose logs wireguard
```

Find the configuration file of a client here:

```
data/wireguard/peer_phone/peer_phone.conf
```

Use this back end if you do not want a web interface, or if you want fewer
services on your server.

### Change the back end

```bash
docker compose --profile wg-easy --profile wireguard down
nano .env          # Change the value of COMPOSE_PROFILES.
docker compose up -d
```

The two back ends do not share the client keys. Your clients need new
configurations after a change.

## Full tunnel and split tunnel

The variable `VPN_ALLOWED_IPS` controls the traffic of the clients.

**Full tunnel (the default).** The client sends all traffic through the VPN.
The client gets advertisement blocking for all traffic. The client also hides
its traffic from the local network.

```ini
VPN_ALLOWED_IPS=0.0.0.0/0, ::/0
```

**Split tunnel.** The client sends only the DNS traffic and the web
interfaces through the VPN. All other traffic uses the normal connection.
This method is faster, but it blocks advertisements only in DNS.

```ini
VPN_ALLOWED_IPS=10.2.0.0/24
```

The clients that exist already do not change. Make a new client after a
change, or edit the client in the web interface.

### IPv6 and DNS leaks

The default value contains `::/0`. This stack carries IPv4 traffic only.
Therefore the IPv6 traffic of a client goes into the tunnel and stops there.

This behaviour is correct and safe. A client with IPv6 tries IPv6 first,
receives no answer, and then uses IPv4 through the VPN. Your real address
stays secret.

Do not remove `::/0` to make IPv6 faster. Without this value, the client
sends the IPv6 traffic outside the tunnel. Then a website sees your real
address, and the DNS queries do not reach Pi-hole. Disable IPv6 on the
client if you do not want the small delay.

Test your VPN with these steps:

1. Connect a client to the VPN.
2. Open https://dnsleaktest.com and start the standard test.
3. The test must show one server only. The server must be your own server.
4. Open the Pi-hole page and look at the query log. The log must show the
   queries of your client.

## Configuration

All settings are in the file `.env`. The file `.env.example` describes each
setting. This section shows the settings that most users change.

### Necessary settings

| Variable           | Description                                        |
| ------------------ | -------------------------------------------------- |
| `VPN_HOST`         | The public IP address or the domain name of the server. |
| `PIHOLE_PASSWORD`  | The password of the Pi-hole web interface.         |
| `WG_EASY_PASSWORD` | The password of the VPN web interface.             |

### Common settings

| Variable            | Default           | Description                       |
| ------------------- | ----------------- | --------------------------------- |
| `COMPOSE_PROFILES`  | `wg-easy`         | The VPN back end.                 |
| `VPN_PORT`          | `51820`           | The public UDP port of the VPN.   |
| `VPN_ALLOWED_IPS`   | `0.0.0.0/0, ::/0` | Full tunnel or split tunnel.      |
| `VPN_SUBNET`        | `10.8.0.0/24`     | The network of the VPN clients.   |
| `WEB_BIND_ADDRESS`  | `127.0.0.1`       | The address of the web interfaces.|
| `TZ`                | `Etc/UTC`         | Your time zone.                   |

### Network settings

Change these three values together if another network in your system uses
the subnet 10.2.0.0/24. The two addresses must be inside the subnet.

```ini
WIREHOLE_SUBNET=10.2.0.0/24
PIHOLE_IPV4_ADDRESS=10.2.0.100
UNBOUND_IPV4_ADDRESS=10.2.0.200
```

### Pi-hole settings

| Variable                | Default      | Description                     |
| ----------------------- | ------------ | ------------------------------- |
| `PIHOLE_RATE_LIMIT`     | `0/0`        | The query limit for one client. |
| `PIHOLE_QUERY_LOGGING`  | `true`       | Write the query log.            |
| `PIHOLE_THEME`          | `default-auto` | The theme of the web interface. |

The stack disables the rate limit of Pi-hole. All your VPN clients arrive at
Pi-hole with the same address. The normal limit of Pi-hole (1000 queries in
60 seconds) counts the queries of all clients together. That limit blocks
normal traffic. Set a value like `5000/60` if you want a limit.

Set `PIHOLE_QUERY_LOGGING=false` if you do not want a record of the queries.

### Image versions

The stack pins the version of each image. A pinned version gives the same
result on every computer. The file `.env` holds the versions:

```ini
PIHOLE_VERSION=2026.07.2
UNBOUND_VERSION=1.26.0
WG_EASY_VERSION=15
WIREGUARD_VERSION=1.0.20260223-r0-ls120
```

Read the release notes before you change a version.

### Advanced Unbound settings

The directory `unbound/custom.conf.d/` holds the settings of Unbound. Add
your own file with the extension `.conf` to this directory. Your settings
replace the settings of the image.

Example: send all queries to Cloudflare over TLS instead of a recursive
lookup. Write this text to `unbound/custom.conf.d/forward.conf`:

```yaml
forward-zone:
    name: "."
    forward-tls-upstream: yes
    forward-addr: 1.1.1.1@853#cloudflare-dns.com
    forward-addr: 1.0.0.1@853#cloudflare-dns.com
```

Restart Unbound after a change:

```bash
docker compose restart unbound
```

## Operation

```bash
# Look at the state of the containers.
docker compose ps

# Read the logs of all services.
docker compose logs -f

# Read the logs of one service.
docker compose logs -f pihole

# Stop the stack.
docker compose down

# Start the stack again.
docker compose up -d

# Restart one service.
docker compose restart unbound
```

### Update the images

1. Read the release notes of the projects.
2. Change the versions in the file `.env`.
3. Run these commands:

```bash
docker compose pull
docker compose up -d
```

Docker keeps your data. The data is in the directory `./data`.

### Save your data

The directory `./data` holds the private keys, the client list, and the
Pi-hole database. Stop the stack before you copy this directory.

```bash
docker compose down
tar -czf wirehole-backup.tar.gz data .env
docker compose up -d
```

Keep the backup file in a safe place. The file holds your private keys.

## Solve a problem

### The web page does not open

The stack publishes the web interfaces on 127.0.0.1 only. Read the section
[Open the web interfaces](#open-the-web-interfaces).

### A client connects, but there is no internet

Check the value of `VPN_HOST` in the file `.env`. The value must be the
public address of your server. Then check that your firewall and your router
send the UDP port 51820 to your server.

Test the DNS chain on the server:

```bash
docker exec wirehole-pihole dig +short example.com @127.0.0.1
```

The command must print an IP address.

### The name resolution fails, and Pi-hole shows SERVFAIL

Test Unbound directly:

```bash
docker exec wirehole-pihole dig +short example.com @10.2.0.200
```

If this command fails, read the log of Unbound:

```bash
docker compose logs unbound
```

The message `udp connect failed: Network unreachable` means that Unbound
tried an IPv6 name server on an IPv4 network. The file
`unbound/custom.conf.d/pi-hole.conf` sets `do-ip6: no` to stop this problem.
Do not set `do-ip6: yes` without real IPv6 on your Docker network.

### Unbound writes "so-rcvbuf was not granted"

The kernel buffer of the host is too small. This message is only a warning.
The stack does not set this option. Read the comment in the file
`unbound/custom.conf.d/pi-hole.conf` if you want a larger buffer.

### Pi-hole does not start, and shows a capability error

The file `docker-compose.yml` gives a small set of capabilities to Pi-hole.
Do not remove them. Pi-hole needs `SETFCAP` to run as a normal user.

### Port 53 is in use

Another DNS program uses port 53 on your host. This stack does not publish
port 53, so this problem is rare. On Ubuntu, stop the local resolver:

```bash
sudo systemctl disable --now systemd-resolved
```

### Start again from the beginning

This procedure deletes all clients and all statistics.

```bash
docker compose --profile wg-easy --profile wireguard down -v
sudo rm -rf data
docker compose up -d
```

## Security

Read the file [SECURITY.md](SECURITY.md) for the full information. The most
important points are here:

- Set a strong password for each web interface.
- Keep the web interfaces on 127.0.0.1. Use an SSH tunnel for remote access.
- Do not publish port 53 to the internet. An open DNS resolver helps
  attackers.
- Keep the directory `./data` secret. It holds your private keys.
- Update the images regularly.

## Supported architectures

| Architecture | State     | Note                                   |
| ------------ | --------- | -------------------------------------- |
| amd64        | Supported | Normal servers and personal computers. |
| arm64        | Supported | Raspberry Pi 3 and later, Apple silicon. |
| armhf/arm32  | No        | LinuxServer stopped these images in 2023. |

Docker selects the correct image for your machine.

## Author

Devin Stokes

- GitHub: [@IAmStoxe](https://github.com/IAmStoxe)
- Twitter: [@DevinStokes](https://twitter.com/DevinStokes)

## Contributing

Issues and pull requests are welcome. Look at the
[issues page](https://github.com/IAmStoxe/wirehole/issues).

## Show your support

Give a star if this project helped you.

[![Buy Me A Coffee](https://cdn.buymeacoffee.com/buttons/v2/default-orange.png)](https://www.buymeacoffee.com/stoxe)

## Acknowledgements

This project uses the work of these teams:

- [Pi-hole](https://pi-hole.net/)
- [NLnet Labs Unbound](https://nlnetlabs.nl/projects/unbound/), in the
  [container image](https://github.com/klutchell/unbound-docker) of Kyle Harding
- [wg-easy](https://github.com/wg-easy/wg-easy)
- [LinuxServer.io](https://www.linuxserver.io/)
- [WireGuard](https://www.wireguard.com/) by Jason A. Donenfeld
