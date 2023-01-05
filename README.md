## Fork difference

Simple setup for personal usage

Requirements:
* docker & docker compose [must be installed](https://www.digitalocean.com/community/tutorials/how-to-install-and-use-docker-compose-on-ubuntu-22-04)

Fork peculiarities:
* env vars usage
* auto-generated .env for docker-compose
* support user-defined vars via .env.vars file 
* removed deprecations

### Quickstart

```bash
git clone https://github.com/kamartem/wirehole.git
cd wirehole
cp ./scripts/.env.vars.example ./scripts/.env.vars
```

Edit .env.vars file due to your requirements, then

```bash
./scripts/run.sh
```

---

Helped?

<a href="https://www.buymeacoffee.com/kamartem" target="_blank"><img src="https://cdn.buymeacoffee.com/buttons/v2/default-orange.png" alt="Buy Me A Coffee" style="height: 60px !important;width: 217px !important;" ></a>

---

For full documentation & creds please visit [original repo](https://github.com/IAmStoxe/wirehole)
