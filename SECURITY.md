# Security

This document describes the security design of WireHole. It also tells you
how to operate the stack safely.

## Report a weakness

Do not open a public issue for a security weakness. Send a private report
with the "Report a vulnerability" button on the Security page of the GitHub
repository. Describe the problem and the steps that show the problem.

## The safe defaults of this stack

The stack starts with safe values. You do not need to change them.

### The web interfaces are private

The stack publishes the Pi-hole page and the VPN page on the address
127.0.0.1 only. Only the server itself can open these pages. A person on
the internet cannot open them.

The variable `WEB_BIND_ADDRESS` controls this behavior. Read the section
"Publish the web interfaces" below before you change the value.

### The DNS port is not public

The stack does not publish port 53 to the host. Pi-hole receives the queries
of the VPN clients on the internal Docker network only.

An open DNS resolver on the internet is dangerous. Attackers use an open
resolver for amplification attacks against other people. Such an attack sends
a small query with your victim's address, and your server sends a large answer
to the victim.

Publish port 53 only to a local network address, and never to 0.0.0.0. The
file `docker-compose.yml` contains an example with a comment.

### The containers have few rights

| Service   | User      | Capabilities                                          |
| --------- | --------- | ----------------------------------------------------- |
| Unbound   | 101:102   | `NET_BIND_SERVICE` only. All others are removed.      |
| Pi-hole   | root, then `pihole` | A small list. All others are removed.        |
| wg-easy   | root      | `NET_ADMIN`, `SYS_MODULE`.                            |
| WireGuard | root      | `NET_ADMIN`, `SYS_MODULE`.                            |

Unbound runs as a normal user and cannot become root. The option
`no-new-privileges` is active for this container.

Pi-hole needs a small list of capabilities. It writes capabilities on its own
program file, and then it runs the DNS process as the user `pihole`. Do not
remove these capabilities. Pi-hole does not start without them.

A VPN server must create a network interface and write firewall rules.
Therefore the two VPN services need `NET_ADMIN`. This is normal for a VPN.

You can remove `SYS_MODULE` and the volume `/lib/modules` if your kernel is
version 5.6 or later. Such a kernel contains the WireGuard module already.

### Each service gets only its own secrets

Each service receives only the variables that it needs. The Pi-hole password
does not go to the Unbound container or to the VPN container.

Do not use the key `env_file` for the whole file `.env`. That key sends every
password to every container.

### The images have fixed versions

The file `.env` pins the version of each image. A fixed version stops an
unexpected change. Read the release notes and then change a version.

## Your tasks

### Use strong passwords

Make the passwords with the helper script:

```bash
./scripts/generate-secrets.sh
```

The script writes a random password with 32 characters for each interface. It
also sets the file permission 600 on the file `.env`.

Never keep a default password. Never use the same password twice.

### Protect the file .env and the directory data

These two places hold your secrets:

- The file `.env` holds the passwords.
- The directory `./data` holds the private keys of the VPN server and of
  every client. It also holds the Pi-hole database.

Git ignores both places. Do not commit them. Do not put them in a public
place. Set the permission 600 on the file `.env`:

```bash
chmod 600 .env
```

A person with the directory `./data` can read your VPN traffic. Encrypt your
backups of this directory.

### Open the firewall for one port only

The VPN needs one open UDP port. The default port is 51820. Do not open the
web ports to the internet.

Example with the firewall of Ubuntu:

```bash
sudo ufw allow 51820/udp
sudo ufw enable
```

### Update the images

Read the release notes, then change the versions in the file `.env`:

```bash
docker compose pull
docker compose up -d
```

Look at these pages for new versions:

- https://github.com/pi-hole/docker-pi-hole/releases
- https://github.com/klutchell/unbound-docker/releases
- https://github.com/wg-easy/wg-easy/releases
- https://github.com/linuxserver/docker-wireguard/releases

## Publish the web interfaces

The web interfaces use HTTP. HTTP sends your password as plain text. A person
on the same network can read it.

Use one of these methods for remote access. The first method is the safest.

### Method 1: an SSH tunnel (recommended)

Keep `WEB_BIND_ADDRESS=127.0.0.1`. Make a tunnel from your own computer:

```bash
ssh -L 51821:127.0.0.1:51821 -L 8080:127.0.0.1:8080 user@your-server
```

Then open `http://127.0.0.1:51821` in your browser. The tunnel uses the
encryption of SSH. You do not open a new port.

### Method 2: the VPN

Connect a client to the VPN. Then open Pi-hole at `http://10.2.0.100/admin`.
The traffic uses the encryption of WireGuard.

### Method 3: a reverse proxy with TLS

Put a reverse proxy in front of the web interfaces. The proxy adds HTTPS with
a certificate. Caddy and Traefik get a free certificate automatically.

Set these values after the proxy works:

```ini
WEB_BIND_ADDRESS=127.0.0.1
WG_EASY_INSECURE=false
```

The value `false` tells wg-easy that the connection uses HTTPS. wg-easy then
sets a secure cookie.

### Do not do this

Do not set `WEB_BIND_ADDRESS=0.0.0.0` on a public server without a proxy with
TLS. That action puts your VPN control panel on the internet with a plain
HTTP login. A person can read your password and then add a VPN client.

## Privacy

The stack keeps your DNS queries private in these ways:

- Unbound asks the authoritative name servers directly. Your queries do not
  go to a public resolver like Google or Cloudflare.
- Unbound sends the minimum information to each server (`qname-minimisation`).
- Unbound does not write a log of the queries.

Pi-hole writes a query log. The log shows the domain of each query. Stop the
query log with this value in the file `.env`:

```ini
PIHOLE_QUERY_LOGGING=false
```

The VPN service writes the QR code of a client to the log when the variable
`WIREGUARD_LOG_CONFS` is `true`. A QR code holds a private key. Set the value
`false` if other persons can read your logs.

## DNSSEC

Unbound validates the DNSSEC signature of each answer. A false answer gets
the status SERVFAIL and does not reach the client.

Pi-hole does not validate DNSSEC in this stack (`FTLCONF_dns_dnssec` is
`false`). Two validators can report a false error for the same answer. Keep
the validation in Unbound only.

Test the validation with these commands:

```bash
# A good domain gives the flag "ad" (authenticated data).
docker exec wirehole-pihole dig +dnssec cloudflare.com @10.2.0.200 | grep flags

# A bad domain gives SERVFAIL.
docker exec wirehole-pihole dig dnssec-failed.org @10.2.0.200 | grep status
```
