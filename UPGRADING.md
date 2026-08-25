# Upgrading from the old WireHole

This page is for you if your WireHole has the directories `config`,
`etc-pihole`, and `db`, the container `wireguard-ui`, or the variable
`WEBPASSWORD` in the file `.env`. That is the layout from before the 2026
rewrite.

The rewrite is a breaking change. Do not run `docker compose up -d` after
`git pull` without reading this page. The commands below keep your VPN
working. Every device keeps its existing configuration.

## The short version

```bash
git pull
./scripts/migrate-from-v1.sh
docker compose up -d
```

The script validates the new configuration before it stops anything. It
copies your WireGuard keys and Pi-hole data, keeps the endpoint that the old
clients actually use, and starts the LinuxServer profile in preservation
mode. It removes the stopped legacy containers only after the files and new
configuration pass validation. Your old data directories stay in place, and
your old `.env` becomes `.env.v1.backup`.

Check the result:

```bash
./scripts/wirehole-doctor.sh
```

Section 6 of the output lists your devices. Connect one and run the script
again. The device must appear with a recent handshake.

## What changed, and why

**The images.** The old Unbound image (`mvance/unbound`) stopped at Unbound
1.22.0 from October 2024 and missed the security fixes of 2026. The new
image (`klutchell/unbound`) follows upstream and also runs on the Raspberry
Pi. Pi-hole moved to version 6, which replaced its whole configuration
system.

**wireguard-ui is gone.** It had no release since January 2024 and left
about 180 issues open. A login panel needs a maintained project behind it.
The replacement is wg-easy, which now has a normal open source license
(AGPL-3.0). The migration keeps you on the plain `wireguard` back end, so
nothing about your devices changes. The panel is optional.

**The variable names.** Pi-hole v6 removed `WEBPASSWORD` and `PIHOLE_DNS`.
The stack also fixed variables that never worked: the old `.env` set
`WIREGUARD_PEERS` and `TIMEZONE`, but the WireGuard image reads `PEERS` and
`TZ`, so those settings did nothing.

| Old variable            | New variable       |
| ----------------------- | ------------------ |
| `WEBPASSWORD`           | `PIHOLE_PASSWORD`  |
| `TIMEZONE`              | `TZ`               |
| `WIREGUARD_SERVER_PORT` | ignored before; the active endpoint becomes `VPN_PORT` |
| `WIREGUARD_PEERS`       | ignored before; existing peer files are preserved |
| `WIREGUARD_PEER_DNS`    | removed, automatic |
| `WGUI_*`                | removed with wireguard-ui |

**The directories.** All data now lives under `./data`.

| Old place        | New place         |
| ---------------- | ----------------- |
| `config/`        | `data/wireguard/` |
| `etc-pihole/`    | `data/pihole/`    |
| `etc-dnsmasq.d/` | no equivalent, see below |
| `db/`            | removed with wireguard-ui |

**The security defaults.** The web interfaces now answer on 127.0.0.1 only,
and each container gets only its own secrets and the smallest set of
rights. Read [SECURITY.md](SECURITY.md).

## If you migrate by hand

Do the same steps as the script:

```bash
# 1. Remove the old containers. They hold the old names and the VPN port.
docker rm -f wireguard-ui wireguard pihole unbound

# 2. Copy the data. The copy keeps your keys, so your devices keep working.
mkdir -p data
sudo cp -a config data/wireguard
sudo cp -a etc-pihole data/pihole

# 3. Make a new .env and carry your values over.
cp .env .env.v1.backup
cp .env.example .env
nano .env
```

Set at least these values in the new `.env`:

- `COMPOSE_PROFILES=wireguard`, so your existing keys stay in use.
- `VPN_HOST`: the address your devices connect to. Look at the `Endpoint`
  line in any `config/peer_*/peer_*.conf`.
- `VPN_PORT`: the port in that same `Endpoint` line. Do not copy the old
  `WIREGUARD_SERVER_PORT`; the old Compose file did not use it.
- `PIHOLE_PASSWORD`: your old `WEBPASSWORD`.
- `WG_EASY_PASSWORD`: any strong value. The stack refuses to start without
  it, also when the wg-easy panel does not run.
- `WIREGUARD_PEERS=`: leave this value empty. That tells the LinuxServer
  image to load the copied `wg0.conf` without regenerating server or peer keys.
- `TZ`, `PUID`, and `PGID`: carry over the old values when you set them.

Then start and check:

```bash
docker compose up -d
./scripts/wirehole-doctor.sh
```

## Custom dnsmasq files

Pi-hole v6 no longer reads `etc-dnsmasq.d`. If you had custom files there,
move each setting into the variable `FTLCONF_misc_dnsmasq_lines`, with `;`
between lines. The Pi-hole documentation explains the details:
https://docs.pi-hole.net/docker/configuration/

## Moving to the wg-easy panel later

The `wireguard` back end and wg-easy do not share keys. A change means new
configurations for every device. When you are ready:

1. Set `COMPOSE_PROFILES=wg-easy` in the file `.env`.
2. Run `docker compose --profile wireguard down`, then
   `docker compose up -d`.
3. Add each device again in the panel and load the new configuration on
   the device.

## Going back

The migration deletes nothing, so the way back is short:

```bash
docker compose --profile wireguard --profile wg-easy down
git checkout <the old commit>
mv .env .env.new && mv .env.v1.backup .env
docker compose up -d
```

## Problems

Run the doctor first:

```bash
./scripts/wirehole-doctor.sh
```

It checks the containers, the DNS chain, the ports, and your devices, and
it prints the command that fixes each problem it finds. If you are stuck,
open an issue and paste the output.
