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

## Where to find things

New here? Read the first four sections in order. That is all you need to get
running. Everything after them is reference material for later.

**Set it up**

1. [What you need first](#what-you-need-first)
2. [Quick start](#quick-start)
3. [Open the web interfaces](#open-the-web-interfaces)
4. [Open the port on your router](#open-the-port-on-your-router)
5. [Add a VPN client](#add-a-vpn-client), then
   [check that it works](#check-that-it-works)

**Change how it behaves**

- [Full tunnel and split tunnel](#full-tunnel-and-split-tunnel)
- [The two VPN back ends](#the-two-vpn-back-ends)
- [Configuration](#configuration), for every setting
- [Keep working when your IP address changes](#keep-working-when-your-ip-address-changes)

**Live with it**

- [Operation](#operation): logs, updates, backups
- [Test that everything works](#test-that-everything-works)
- [Solve a problem](#solve-a-problem)
- [Questions people ask](#questions-people-ask)
- [Security](#security)

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

## What you need first

You do not need to be an expert, but you do need four things. Get all four
ready before you start. The setup takes about 20 minutes.

**1. A computer that stays on, running Linux.** This computer is your server.
It can be a Raspberry Pi (model 3 or later), an old desktop computer, a home
server, or a rented server from a hosting company. It must run Linux.

A VPN needs parts of the Linux kernel that Docker Desktop does not give you,
so a Mac or a Windows PC cannot host this stack, even with Docker installed.
Those machines make fine clients. They just cannot be the server.

The server stays on all the time. When it is off, a device with the VPN
switched on has no internet at all until you switch the VPN off again.

**2. Docker, and git.** The stack runs in Docker. Install Docker with the
official guide at https://docs.docker.com/engine/install/. On a Raspberry Pi
or another Debian system, the quick installer also works:

```bash
sudo apt update && sudo apt install -y git
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker $USER
```

The last command lets you run Docker without `sudo` every time. It also gives
your account root-level power on that machine, so use it only on a machine you
control.

Now log out and log back in. Close the whole SSH session and connect again.
Nothing else applies the change. If you skip this and later see
`permission denied while trying to connect to the Docker daemon socket`, this
is the reason.

Check that it all works:

```bash
docker --version          # You need 20.10 or later.
docker compose version    # You need v2 or later.
```

**3. A way for your devices to find your server.** Your phone must know
where to connect. This is a public IP address or a domain name. The setup
script finds your public address automatically. If your address changes,
read [Keep working when your IP address changes](#keep-working-when-your-ip-address-changes).

**4. One open port.** Your router must send UDP port 51820 to your server.
This step is the one that stops most people, so it has its own section:
[Open the port on your router](#open-the-port-on-your-router). Skip this
step if your server is a rented server with a public address.

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

The script prints your new passwords. Write them in your password manager
now, because you need them in the next step.

Step 4 takes a minute, because Pi-hole has to be ready before the VPN starts.
Let it finish.

Then `docker compose ps` shows three containers. Pi-hole and the VPN say
`Up (healthy)`. Unbound says only `Up`, with nothing about health. That is
normal and not a fault: the Unbound image is so small that it has no shell to
run a health check with. If a container restarts again and again, go to
[Solve a problem](#solve-a-problem).

Your stack now runs, but you cannot see the control panel yet. The panels
are closed to the network on purpose, so the next section shows you how to
open them. After that, you add your first device.

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

Most people run this on a server with no screen, so you need a way in from
your own computer. Use Method 1 for your first visit. It is safe, and it is
one command.

**Method 1: an SSH tunnel.** This is the one to use now. Run this command on
your own computer, not on the server:

```bash
ssh -L 51821:127.0.0.1:51821 -L 8080:127.0.0.1:8080 user@your-server
```

Replace the two placeholders:

- `user` is the name you log in with on the server, such as `pi` or `ubuntu`.
- `your-server` is the local address of the server. Run `hostname -I` on the
  server to find it. It looks like 192.168.1.50.

The command then looks like `ssh -L 51821:127.0.0.1:51821 -L
8080:127.0.0.1:8080 pi@192.168.1.50`.

After you run it, the window looks like an ordinary shell prompt and seems to
do nothing. That is correct. Leave the window open. While it stays open, open
`http://127.0.0.1:51821` in the browser **on your own computer**. Close the
window when you finish, and the door closes with it.

Windows 10 and later already have `ssh`. Run the command in PowerShell.

**Method 2: over the VPN, once you have a device set up.** Connect a device
to the VPN, then open Pi-hole at `http://10.2.0.100/admin`. This method
cannot help you yet, because you need the VPN panel to make your first
device. Use Method 1 for that, then come back to this method later.

**Method 3: publish the ports (not recommended).** Set
`WEB_BIND_ADDRESS=0.0.0.0` in the file `.env`. This puts both panels on your
network with no encryption. Anyone on the network can then reach your VPN
control panel and read your password as it goes past, and a person who has
your password can add their own VPN device. Only do this on a network you
trust completely, or behind a reverse proxy with TLS. Read
[SECURITY.md](SECURITY.md) first.

## Open the port on your router

Your devices connect to your server from outside your home. The connection
arrives at your router first, and your router does not know where to send it.
You must tell it. This step is called port forwarding.

Skip this section if your server is a rented server with its own public
address. Those servers have no router in front of them.

First, check that port forwarding can work for you at all. This takes ten
seconds and can save you an hour. Run `curl -s ifconfig.me` on your server and
compare the answer with the internet address shown in your router settings. If
the two differ, or if your router shows an address that starts with 100.64 to
100.127, your provider uses CGNAT and port forwarding cannot work. Read the
note at the end of this section.

Next, open the port on the server itself. Many systems run their own firewall,
and it blocks the VPN before your router ever matters:

```bash
sudo ufw allow 51820/udp
```

Then set up the router:

1. Find the local address of your server. Run `hostname -I` on the server.
   The address looks like 192.168.1.50.
2. Give your server a fixed local address. Open your router settings and look
   for "DHCP reservation" or "static lease". Without this step, your server
   can get a different address later, and the VPN stops.
3. Open the port forwarding page of your router. Routers use different names
   for this page: "Port Forwarding", "Virtual Server", "NAT", or "Applications
   and Gaming". The site https://portforward.com/router.htm has a guide for
   most routers.
4. Make a new rule with these values:
   - External port: 51820
   - Internal port: 51820
   - Protocol: UDP (not TCP)
   - Internal address: the address of your server from step 1
5. Save the rule. Some routers need a restart.

Test the rule from a phone with mobile data, not from your home network.
A test from inside your home often gives a false result.

If the connection does not work, your internet provider may use CGNAT. CGNAT
gives you an address that you share with other customers, and port forwarding
cannot work. Ask your provider for a public IP address. Many providers give
one at no cost.

## Add a VPN client

1. Open the VPN web interface at `http://127.0.0.1:51821`. If you cannot
   reach it, use the SSH tunnel from
   [Open the web interfaces](#open-the-web-interfaces).
2. Sign in with your `WG_EASY_USERNAME`, which is `admin` unless you changed
   it, and your `WG_EASY_PASSWORD`.
3. Select **New Client** and give the device a name, such as "phone".
4. Read the QR code with the WireGuard application on your phone.
   You can also download the configuration file for a computer.

Get the WireGuard client application from https://www.wireguard.com/install/.

Give every device its own client. Do not put one configuration on two
devices. WireGuard ties a configuration to one device, and sharing it makes
both connections unreliable.

### Remove a device

Remove a device when you lose it, or when someone should no longer have
access.

Open the VPN web interface, find the device in the list, and delete it. The
change takes effect at once, and the old configuration stops working.

For the `wireguard` profile, a smaller `WIREGUARD_PEERS` number does **not**
remove access. The old keys stay in `./data/wireguard`. Delete the directory
of that client, then restart the service:

```bash
sudo rm -rf data/wireguard/peer_phone
docker compose restart wireguard
```

### Check that it works

Turn the VPN on in the WireGuard application on your phone. Then make
these three checks. Use mobile data, not your home network, for a true test.

**1. The internet works.** Open any website. If nothing loads, your router
probably does not send the port to your server. Read
[Open the port on your router](#open-the-port-on-your-router).

**2. The advertisements are gone.** Open a news website that usually shows
many advertisements. You should see empty spaces where the advertisements
were.

**3. Your traffic uses your server.** Open https://dnsleaktest.com and start
the standard test. The result must show your own server, and one server only.
If you see the name of your internet provider or of Google, your device does
not use the VPN for DNS.

You can also watch the queries arrive. Open the Pi-hole page and look at
**Query Log**. Every website that your phone opens appears in that list
within a few seconds.

## Keep working when your IP address changes

Most home internet connections get a new public IP address from time to time.
When that happens, your devices try the old address, and the VPN stops. Your
server is fine. Only the address is wrong.

Use a dynamic DNS name to solve this. The service gives you a name like
`myhome.duckdns.org` and keeps the name pointed at your current address.

1. Make a free account at https://www.duckdns.org or at another provider.
2. Follow their instructions to keep the name up to date. Most providers
   give a small program or a cron job for your server.
3. Put the name in your file `.env`:

   ```ini
   VPN_HOST=myhome.duckdns.org
   ```

4. Start the stack again:

   ```bash
   docker compose up -d
   ```

**Important, and easy to miss.** The default wg-easy back end reads the server
address only one time, at the very first start. If your stack has run before,
step 3 and step 4 alone change nothing. You must also open the VPN web
interface, go to the server settings, and change the host there. Then download
the configuration again for each device.

This catches everybody once, so it is worth saying twice: editing `.env` after
the first start does not move an existing server. The web interface does.

Devices you set up before the change still point at the old address. Fix each
one in the VPN web interface, or just create it again.

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
This is faster, but it protects less. Your normal traffic does not use the
VPN, so websites still see your real address, and your device is not protected
on untrusted Wi-Fi. You still get ad blocking, because the DNS still goes
through Pi-hole.

```ini
VPN_ALLOWED_IPS=10.2.0.0/24
```

Devices you already set up keep the old setting.

The default wg-easy back end reads these values only at the very first start,
so editing `.env` later does not change a server that has already run. Change
it in the VPN web interface instead, then download the configuration again for
each device.

### IPv6 and DNS leaks

The default value contains `::/0`. This stack carries IPv4 traffic only.
Therefore the IPv6 traffic of a client goes into the tunnel and stops there.

This behavior is correct and safe. A client with IPv6 tries IPv6 first,
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

```conf
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
sudo tar -czf wirehole-backup.tar.gz data .env
docker compose up -d
```

The `sudo` is necessary. The containers make some of those files as root.
Without it, `tar` skips them and writes an incomplete archive.

Keep the backup file in a safe place. The file holds your private keys.

To restore, put the file back and start the stack:

```bash
docker compose down
sudo tar -xzf wirehole-backup.tar.gz
docker compose up -d
```

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

## Test that everything works

The project has two scripts. One checks your own stack. The other proves
that a real device can connect.

### Check your own stack

Run this on your server at any time. It reads only, and it changes nothing.

```bash
./scripts/wirehole-doctor.sh
```

It checks Docker, the file `.env` and its permissions, every container, the
whole DNS chain, DNSSEC, ad blocking, the ports, your firewall, and whether
`VPN_HOST` still matches your public address. Each problem comes with the
command that fixes it.

Section 6 of the output lists your devices and the time of the last
handshake. Run the script again after you connect a phone. If the phone
appears as connected a few seconds ago, the VPN works.

### Test with a phone on the same Wi-Fi

Test the server before you spend time on your router. This proves the server
works, and it separates a server problem from a router problem.

```bash
./scripts/wirehole-doctor.sh --phone
```

The script prints the steps for your own network, with the local address of
your server already filled in. In short: put the phone on the same Wi-Fi,
change the endpoint in the WireGuard app to the local address of the server,
turn the VPN on, and run the script again.

If the phone connects on your Wi-Fi but not from mobile data, the server is
fine and the problem is your router or your provider. Read
[Open the port on your router](#open-the-port-on-your-router).

### Prove that a real client connects

This test starts a complete stack in a temporary directory, makes client
configurations the same way you do, and connects real WireGuard clients to
it. Each client is a container that behaves like a phone.

```bash
./tests/e2e-vpn.sh
```

It tests both back ends and makes two devices for each one, because a stack
that connects the first device and fails on the second is a common fault. For
every client it checks the handshake, traffic through the tunnel, DNS through
Pi-hole, ad blocking, and reaching the internet.

The test never touches your stack, your file `.env`, or your directory
`./data`. It uses its own directory, network, and ports.

```bash
./tests/e2e-vpn.sh --profile wg-easy   # Test one back end.
./tests/e2e-vpn.sh --keep              # Keep everything, to study a failure.
```

The same test runs in CI on every change and once a week.

## Questions people ask

**Do I really need a computer on all the time?** Yes. The server answers your
devices, so it has to be awake. A Raspberry Pi is popular for this because it
uses about as much power as a phone charger.

**Will this slow down my internet?** A little, and you will probably not
notice. Your traffic goes to your server first, so your home upload speed sets
the limit. The first visit to a new website is slightly slower, because
Unbound looks up the answer itself. Every visit after that is faster, because
the answer is in the cache. A split tunnel avoids most of the cost.

**What does it cost?** Nothing, if you own the hardware. A Raspberry Pi uses a
few dollars of electricity a year. A small rented server costs about five
dollars a month.

**At home or on a rented server?** At home, your devices appear to be at
home, and you can reach your printer and your other devices. You have to
forward a port, and CGNAT can stop you. On a rented server, there is no port
forwarding and no CGNAT, and the address never changes. But your traffic
leaves from a data center, so some streaming services block it and some sites
show you more puzzles to solve. Ad blocking works the same in both cases.

**What happens when the server restarts?** The stack starts again by itself.
That is the `RESTART_POLICY` setting, and `unless-stopped` is the default.
Your devices reconnect on their own.

**Can I use one configuration on my phone and my laptop?** No. Make one
client for each device. See [Add a VPN client](#add-a-vpn-client).

**A banking app or a video call stopped working.** Some services refuse
traffic that arrives from a data center, and a few block VPNs completely. Turn
the VPN off for that app, or use a split tunnel.

**Is this legal?** Running your own VPN is normal and legal in most countries.
You are connecting to your own computer. Some countries restrict VPNs, so
check your local law.

**How do I remove it?** Stop everything, then delete the folder:

```bash
docker compose --profile wg-easy --profile wireguard down -v
cd .. && sudo rm -rf wirehole
```

Also remove the firewall rule with `sudo ufw delete allow 51820/udp` and the
port forwarding rule in your router.

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
| arm64        | Supported | Raspberry Pi 3 and later, arm64 Linux servers. |
| armhf/arm32  | No        | LinuxServer stopped these images in 2023. |

Docker selects the correct image for your machine.

The server must run Linux. macOS and Windows cannot host this stack, because
Docker Desktop runs containers inside its own virtual machine and does not
give them the kernel features a VPN needs. Both make fine client devices.

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
