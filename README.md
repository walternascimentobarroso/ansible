# Homelab Ansible

Ansible automation for the homelab, running inside a Docker container (no need to install Ansible on the host). The `proxmox` playbooks provision the hypervisor, and the `pihole`, `traefik`, `nextcloud` and `ai` playbooks each create and configure an LXC running that service.

Internal services live under `*.home.arpa` (RFC 8375) behind Traefik with a self-signed Root CA — see [docs/certificates.md](docs/certificates.md) to generate it and install it on each device.

## Prerequisites

- Docker and Docker Compose installed on the host.
- An SSH key pair dedicated to this automation, e.g. `~/.ssh/proxmox` / `~/.ssh/proxmox.pub`.
- Root access (password or already-authorized key) to the Proxmox server, only for the initial bootstrap step.
- A Proxmox API user with administrator permissions (created in one of the steps below).

## 1. Configure `.env`

Copy the example file and fill in your values:

```bash
cp .env.example .env
```

```dotenv
PROXMOX_HOST=192.168.1.2          # Proxmox server IP or hostname
PROXMOX_USER=ansible@pve          # API user you'll create in step 3
PROXMOX_TOKEN_ID=ansible          # API token name
PROXMOX_TOKEN_SECRET=             # generated automatically by the create-api-token.yml playbook

HOMELAB_DOMAIN=home.arpa          # internal domain; every service is <service>.HOMELAB_DOMAIN

# Nextcloud app
NEXTCLOUD_DB_NAME=nextcloud
NEXTCLOUD_DB_USER=nextcloud
NEXTCLOUD_DB_PASSWORD=choose-a-strong-password
NEXTCLOUD_ADMIN_USER=admin
NEXTCLOUD_ADMIN_PASSWORD=choose-a-strong-password

# Pi-hole app
PIHOLE_VERSION=v6.4.3
PIHOLE_UPSTREAM_DNS=1.1.1.1,1.0.0.1
PIHOLE_ADMIN_PASSWORD=choose-a-strong-password

# Pi-hole DHCP
PIHOLE_DHCP_ENABLED=true
PIHOLE_DHCP_START=192.168.1.20
PIHOLE_DHCP_END=192.168.1.254
PIHOLE_DHCP_ROUTER=192.168.1.1
PIHOLE_DHCP_NETMASK=255.255.255.0
PIHOLE_DHCP_LEASE_TIME=24h
```

`.env` only holds secrets and a few app settings. The LXC specs (VMID, hostname, cores, memory, disk, IP) are versioned in `inventory/host_vars/<service>-server.yml` under an `lxc:` key, and the network shared by every LXC (CIDR, gateway) is in `inventory/group_vars/proxmox.yml`:

```yaml
# inventory/host_vars/ai-server.yml
ansible_host: "{{ lxc.ip }}"

lxc:
  vmid: 104
  hostname: ai-server
  cores: 4
  memory: 8192
  swap: 2048
  disk: 20
  data_size: 50          # optional extra volume (GB)
  data_mount: /data      # where that volume is mounted
  ip: 192.168.1.5
  features: nesting=1    # required to run Docker inside the LXC
```

`.env` is never committed (it's in `.gitignore`) — secrets stay only on your machine.

## 2. Build and start the Ansible container

```bash
make build
make up
```

This builds the image (`python:3.13-slim` + `ansible` + `proxmoxer`) and starts the `homelab-ansible` container in the background, with the repository mounted at `/ansible` and `~/.ssh` mounted read-only.

## 3. Bootstrap the Proxmox server

Add your public key to `root` on Proxmox (asks for a password the first time):

```bash
make playbook PLAYBOOK=playbooks/proxmox/bootstrap-host.yml
```

Confirm the key-based connection works:

```bash
make ping
```

## 4. Create the Proxmox API user and token

These steps run `pveum` commands directly on the Proxmox host (over SSH), so they already use the key installed in the previous step:

```bash
make playbook PLAYBOOK=playbooks/proxmox/setup.yml
```

This aggregates, in order:

1. `create-api-user.yml` — creates the API user (`PROXMOX_USER`).
2. `create-api-token.yml` — generates a new token and automatically writes the secret to `PROXMOX_TOKEN_SECRET` in `.env`.
3. `grant-api-permissions.yml` — grants the `PVEAdmin` role to the user.

> `.env` gets edited by the playbook itself (`create-api-token.yml`). After running it, confirm `PROXMOX_TOKEN_SECRET` was filled in.

Validate that the API responds:

```bash
make playbook PLAYBOOK=playbooks/proxmox/test-api.yml
```

## 5. Prepare the LXC template

Download the Debian template used to create LXCs (only needs to run once, or when you change the version in `inventory/group_vars/proxmox.yml`):

```bash
make playbook PLAYBOOK=playbooks/proxmox/download-template.yml
```

(Optional) To inspect nodes, storage, network and templates available on the cluster:

```bash
make playbook PLAYBOOK=playbooks/proxmox/show-info.yml
```

## 6. Create and configure Pi-hole

Pi-hole is the network's DNS (and optionally DHCP) server. Besides blocking ads, it resolves every `*.<HOMELAB_DOMAIN>` name to the Traefik IP, so all internal services go through Traefik:

```bash
make deploy NAME=pihole
```

Like every service, this runs `playbooks/lxc/create.yml`, `playbooks/lxc/bootstrap.yml` and `playbooks/pihole/configure-app.yml`: it creates the LXC, authorizes the automation's key, installs Pi-hole natively (no Docker), applies DNS/DHCP settings from `.env`, and deploys the wildcard DNS rule in `roles/pihole/templates/homelab.conf.j2`.

Point your router's DNS (or your devices) at the Pi-hole IP (`lxc.ip` in `inventory/host_vars/pihole-server.yml`). If `PIHOLE_DHCP_ENABLED=true`, disable the router's DHCP server to avoid conflicts.

## 7. Create and configure Traefik

Traefik is the reverse proxy that terminates HTTPS for every internal service. First generate the Root CA and the Traefik certificate — the playbook copies them from `certs/homelab/traefik/` — as described in [docs/certificates.md](docs/certificates.md):

```bash
make certs
```

Then create and configure the LXC:

```bash
make deploy NAME=traefik
```

`configure-app.yml` installs Docker, copies the certificate, and deploys Traefik with:

- `traefik.yml.j2` — static config: HTTP→HTTPS redirect, Docker and file providers.
- `tls.yml.j2` — the homelab certificate as default.
- `routes/*.yml.j2` — one file per service (`pihole`, `nextcloud`, `ai`), routing `<service>.<HOMELAB_DOMAIN>` to its LXC over plain HTTP. Every file in `routes/` is deployed automatically.

The Traefik dashboard is at `https://traefik.<HOMELAB_DOMAIN>` and a test service at `https://whoami.<HOMELAB_DOMAIN>`.

### Adding a new service to Traefik

The certificate is **not** a `*.home.arpa` wildcard: `home.arpa` is on the Public Suffix List, so Apple's TLS stack (macOS/iOS apps such as the Nextcloud Desktop File Provider) rejects it, even though browsers and `curl` accept it. Instead it lists one SAN per host, read from the `Host(...)` rules under `roles/traefik/templates/`.

So every time you add a `Host(...)` rule, regenerate the certificate and redeploy Traefik in one step (the Root CA is kept, so clients don't need to reinstall anything):

```bash
make traefik-reload
```

The playbook restarts Traefik when the certificate changes.

## 8. Create and configure the Nextcloud machine

With Proxmox already prepared, create the LXC, inject the SSH key into it, and install/configure Nextcloud (Docker + Postgres + Redis), all with a single command:

```bash
make deploy NAME=nextcloud
```

This runs, in order:

1. `playbooks/lxc/create.yml` — creates the LXC on Proxmox via the API (specs from `inventory/host_vars/nextcloud-server.yml`).
2. `playbooks/lxc/bootstrap.yml` — installs `openssh-server` inside the LXC and authorizes the automation's key.
3. `configure-app.yml` — installs Docker on the LXC and brings up the Nextcloud stack (Postgres, Redis, Nextcloud), waiting for the installation to finish.

Nextcloud itself only serves plain HTTP on port 80 of the LXC. HTTPS is handled by the Traefik LXC, which routes `nextcloud.<HOMELAB_DOMAIN>` to the LXC's IP via `roles/traefik/templates/routes/nextcloud.yml.j2`, using the homelab certificate signed by the homelab Root CA (see [docs/certificates.md](docs/certificates.md)). This requires `nextcloud.<HOMELAB_DOMAIN>` to resolve to the Traefik IP (Pi-hole handles this).

At the end, Nextcloud is reachable at `https://nextcloud.<HOMELAB_DOMAIN>` with the credentials set in `NEXTCLOUD_ADMIN_USER` / `NEXTCLOUD_ADMIN_PASSWORD`. This only works over the local network; it does not expose Nextcloud to the internet.

If you change the Nextcloud route, re-run `playbooks/traefik/configure-app.yml` — Traefik watches its dynamic config directory, so the change takes effect without a restart.

Since Traefik terminates TLS and talks plain HTTP to Nextcloud, Nextcloud otherwise has no way to know the original request was HTTPS and generates `http://` URLs for its assets — the browser then blocks them under CSP (`img-src` mismatch). `configure-app.yml` fixes this by adding `nextcloud.<HOMELAB_DOMAIN>` to `trusted_domains`, setting `overwriteprotocol=https`, and adding the Traefik IP to `trusted_proxies`, so Nextcloud trusts Traefik's `X-Forwarded-*` headers and generates `https://` URLs consistently.

### Running the steps individually

If you need to repeat just one stage (e.g. the LXC already exists and you only want to reconfigure the app):

```bash
make playbook PLAYBOOK=playbooks/lxc/create.yml NAME=nextcloud
make playbook PLAYBOOK=playbooks/lxc/bootstrap.yml NAME=nextcloud
make playbook PLAYBOOK=playbooks/nextcloud/configure-app.yml
```

All steps are idempotent — running them again won't duplicate the LXC or recreate what already exists.

## 9. Create and configure the AI machine (Ollama + Open WebUI)

An LXC that runs local LLMs with [Ollama](https://ollama.com) and exposes a chat UI with [Open WebUI](https://openwebui.com):

```bash
make deploy NAME=ai
```

The LXC specs are in `inventory/host_vars/ai-server.yml`. `configure-app.yml` installs Docker and brings up the stack in `/opt/ai/compose.yml`:
- `ollama` — model runtime, data in `<data_mount>/ollama` (not exposed outside the LXC).
- `open-webui` — web UI on port `8080`, talking to Ollama at `http://ollama:11434`, data in `<data_mount>/open-webui`.

Traefik routes `ai.<HOMELAB_DOMAIN>` to port `8080` of the LXC via `roles/traefik/templates/routes/ai.yml.j2`. Since this is a new `Host(...)` rule, run `make traefik-reload`.

Open WebUI is then at `https://ai.<HOMELAB_DOMAIN>`; the first account created there becomes the admin. Models are pulled from the UI (or with `docker exec ollama ollama pull <model>` inside the LXC). Ollama runs on CPU — there's no GPU passthrough configured.

## Adding a new service

```bash
make new-service NAME=foo VMID=105 IP=192.168.1.6 PORT=3000
```

This scaffolds everything a service needs:

- `inventory/hosts.yml` — a `foo` group with the `foo-server` host.
- `inventory/host_vars/foo-server.yml` — LXC specs (defaults: 1 core, 1 GB RAM, 8 GB disk).
- `playbooks/foo/deploy.yml` and `configure-app.yml`, plus an entry in `site.yml`.
- `roles/foo/` — a Docker Compose stack in `/opt/foo`.
- `roles/traefik/templates/routes/foo.yml.j2` — route `foo.<HOMELAB_DOMAIN>` → `<IP>:<PORT>`.

Then set the image in `roles/foo/templates/compose.yml.j2`, adjust the specs, and run:

```bash
make deploy NAME=foo
make traefik-reload
```

## Other useful commands

```bash
make hosts            # list every service exposed by Traefik with its URL
make deploy NAME=ai    # create + bootstrap + configure one service
make site             # deploy every service (site.yml)
make certs            # generate the Root CA (once) and renew the Traefik certificate
make traefik-reload   # certs + redeploy Traefik
make lint             # ansible-lint
make bash        # open a shell inside the Ansible container
make logs        # follow the container logs
make stop        # stop the container
make destroy     # stop and remove the container
make rebuild     # destroy + build + up (rebuild the image from scratch)

make syntax-check PLAYBOOK=playbooks/nextcloud/deploy.yml   # syntax-check a single playbook
make syntax-check-all                                        # syntax-check every playbook
```

## Project structure

```
ansible/
├── site.yml                       # deploys every service
├── inventory/
│   ├── hosts.yml                  # one group per service
│   ├── host_vars/
│   │   └── <service>-server.yml   # LXC specs (lxc:) and ansible_host
│   └── group_vars/
│       ├── all.yml                # SSH, python, homelab_domain, traefik_ip
│       ├── proxmox.yml            # hypervisor config, API auth, shared LXC network
│       ├── pihole.yml             # Pi-hole app config (DNS, DHCP)
│       └── nextcloud.yml          # Nextcloud app config
├── playbooks/
│   ├── lxc/                       # generic create.yml / bootstrap.yml (-e service=<name>)
│   ├── proxmox/                   # hypervisor bootstrap and administration
│   └── <service>/                 # deploy.yml + configure-app.yml
├── roles/
│   ├── proxmox_lxc/               # LXC creation via the Proxmox API
│   ├── lxc_bootstrap/             # SSH setup inside a new LXC
│   ├── docker/                    # Docker installation
│   ├── traefik/                   # Traefik config, TLS and routes/ (one file per service)
│   └── <service>/                 # the service's app
├── scripts/
│   ├── generate-homelab-certificates.sh  # Root CA + Traefik certificate (one SAN per host)
│   └── new-service.sh                    # scaffold used by make new-service
└── docs/
    └── certificates.md            # certificate generation and client install
```

See `CLAUDE.md` for more details on conventions and commands.
