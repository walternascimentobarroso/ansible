# Homelab Ansible

Ansible automation for the homelab, running inside a Docker container (no need to install Ansible on the host). The `proxmox` playbooks provision the hypervisor, and the `pihole`, `traefik` and `nextcloud` playbooks each create and configure an LXC running that service.

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

# Nextcloud LXC
NEXTCLOUD_VMID=101                # unique LXC ID in Proxmox
NEXTCLOUD_HOSTNAME=nextcloud
NEXTCLOUD_CORES=2
NEXTCLOUD_MEMORY=4096             # RAM in MB
NEXTCLOUD_SWAP=512                # swap in MB
NEXTCLOUD_DISK=32                 # root disk in GB
NEXTCLOUD_DATA_SIZE=200           # data volume in GB
NEXTCLOUD_DATA_MOUNT=/data        # data volume mount point inside the LXC
NEXTCLOUD_IP=192.168.1.102        # static IP the LXC will use
NEXTCLOUD_CIDR=24                 # network prefix (e.g. 24 for /24)
NEXTCLOUD_GATEWAY=192.168.1.1     # local network gateway

# Nextcloud app
NEXTCLOUD_DB_NAME=nextcloud
NEXTCLOUD_DB_USER=nextcloud
NEXTCLOUD_DB_PASSWORD=choose-a-strong-password

NEXTCLOUD_ADMIN_USER=admin
NEXTCLOUD_ADMIN_PASSWORD=choose-a-strong-password

# Pi-hole LXC
PIHOLE_VMID=102
PIHOLE_HOSTNAME=pihole
PIHOLE_CORES=1
PIHOLE_MEMORY=512
PIHOLE_SWAP=512
PIHOLE_DISK=8
PIHOLE_IP=192.168.1.3
PIHOLE_CIDR=24
PIHOLE_GATEWAY=192.168.1.1

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

# Traefik LXC
TRAEFIK_VMID=103
TRAEFIK_HOSTNAME=traefik
TRAEFIK_CORES=1
TRAEFIK_MEMORY=512
TRAEFIK_SWAP=512
TRAEFIK_DISK=8
TRAEFIK_IP=192.168.1.4
TRAEFIK_CIDR=24
TRAEFIK_GATEWAY=192.168.1.1

HOMELAB_DOMAIN=home.arpa          # internal domain; every service is <service>.HOMELAB_DOMAIN
```

All machine-specific values (LXC specs, network, credentials) live only in `.env` — to create another Nextcloud instance or a new machine, just duplicate/adjust these variables, without touching `inventory/group_vars/` or the playbooks.

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

Pi-hole is the network's DNS (and optionally DHCP) server. Besides blocking ads, it resolves every `*.<HOMELAB_DOMAIN>` name to `TRAEFIK_IP`, so all internal services go through Traefik:

```bash
make playbook PLAYBOOK=playbooks/pihole/deploy.yml
```

This aggregates `create-lxc.yml`, `bootstrap-lxc.yml` and `configure-app.yml`: it creates the LXC, authorizes the automation's key, installs Pi-hole natively (no Docker), applies DNS/DHCP settings from `.env`, and deploys the wildcard DNS rule in `roles/pihole/templates/homelab.conf.j2`.

Point your router's DNS (or your devices) at `PIHOLE_IP`. If `PIHOLE_DHCP_ENABLED=true`, disable the router's DHCP server to avoid conflicts.

## 7. Create and configure Traefik

Traefik is the reverse proxy that terminates HTTPS for every internal service. First generate the Root CA and the Traefik certificate — the playbook copies them from `certs/homelab/traefik/` — as described in [docs/certificates.md](docs/certificates.md):

```bash
./scripts/generate-homelab-certificates.sh
```

Then create and configure the LXC (there's no aggregator yet, so run the three steps in order):

```bash
make playbook PLAYBOOK=playbooks/traefik/create-lxc.yml
make playbook PLAYBOOK=playbooks/traefik/bootstrap-lxc.yml
make playbook PLAYBOOK=playbooks/traefik/configure-app.yml
```

`configure-app.yml` installs Docker, copies the certificate, and deploys Traefik with:

- `traefik.yml.j2` — static config: HTTP→HTTPS redirect, Docker and file providers.
- `tls.yml.j2` — the homelab certificate as default.
- `pihole.yml.j2` / `nextcloud.yml.j2` — routes `pihole.<HOMELAB_DOMAIN>` and `nextcloud.<HOMELAB_DOMAIN>` to their LXCs over plain HTTP.

The Traefik dashboard is at `https://traefik.<HOMELAB_DOMAIN>` and a test service at `https://whoami.<HOMELAB_DOMAIN>`.

### Adding a new service to Traefik

The certificate is **not** a `*.home.arpa` wildcard: `home.arpa` is on the Public Suffix List, so Apple's TLS stack (macOS/iOS apps such as the Nextcloud Desktop File Provider) rejects it, even though browsers and `curl` accept it. Instead it lists one SAN per host, read from the `Host(...)` rules in `roles/traefik/templates/*.j2`.

So every time you add a `Host(...)` rule, regenerate the certificate and redeploy Traefik (the Root CA is kept, so clients don't need to reinstall anything):

```bash
./scripts/generate-homelab-certificates.sh
make playbook PLAYBOOK=playbooks/traefik/configure-app.yml
```

The playbook restarts Traefik when the certificate changes.

## 8. Create and configure the Nextcloud machine

With Proxmox already prepared, create the LXC, inject the SSH key into it, and install/configure Nextcloud (Docker + Postgres + Redis), all with a single command:

```bash
make playbook PLAYBOOK=playbooks/nextcloud/deploy.yml
```

This aggregates, in order:

1. `create-lxc.yml` — creates the LXC on Proxmox via the API (specs from `.env`, resolved through `inventory/group_vars/proxmox.yml`).
2. `bootstrap-lxc.yml` — installs `openssh-server` inside the LXC and authorizes the automation's key.
3. `configure-app.yml` — installs Docker on the LXC and brings up the Nextcloud stack (Postgres, Redis, Nextcloud), waiting for the installation to finish.

Nextcloud itself only serves plain HTTP on port 80 of the LXC. HTTPS is handled by the Traefik LXC (`TRAEFIK_IP`), which routes `nextcloud.<HOMELAB_DOMAIN>` to `http://<NEXTCLOUD_IP>` via the file-provider config in `roles/traefik/templates/nextcloud.yml.j2`, using the homelab certificate signed by the homelab Root CA (see [docs/certificates.md](docs/certificates.md)). This requires `HOMELAB_DOMAIN` and `TRAEFIK_IP` to be set in `.env`, and `nextcloud.<HOMELAB_DOMAIN>` to resolve to `TRAEFIK_IP` (Pi-hole handles this).

At the end, Nextcloud is reachable at `https://nextcloud.<HOMELAB_DOMAIN>` with the credentials set in `NEXTCLOUD_ADMIN_USER` / `NEXTCLOUD_ADMIN_PASSWORD`. This only works over the local network; it does not expose Nextcloud to the internet.

If you change the Nextcloud route, re-run `playbooks/traefik/configure-app.yml` — Traefik watches its dynamic config directory, so the change takes effect without a restart.

Since Traefik terminates TLS and talks plain HTTP to Nextcloud, Nextcloud otherwise has no way to know the original request was HTTPS and generates `http://` URLs for its assets — the browser then blocks them under CSP (`img-src` mismatch). `configure-app.yml` fixes this by adding `nextcloud.<HOMELAB_DOMAIN>` to `trusted_domains`, setting `overwriteprotocol=https`, and adding `TRAEFIK_IP` to `trusted_proxies`, so Nextcloud trusts Traefik's `X-Forwarded-*` headers and generates `https://` URLs consistently.

### Running the steps individually

If you need to repeat just one stage (e.g. the LXC already exists and you only want to reconfigure the app):

```bash
make playbook PLAYBOOK=playbooks/nextcloud/create-lxc.yml
make playbook PLAYBOOK=playbooks/nextcloud/bootstrap-lxc.yml
make playbook PLAYBOOK=playbooks/nextcloud/configure-app.yml
```

All steps are idempotent — running them again won't duplicate the LXC or recreate what already exists.

## Other useful commands

```bash
make hosts       # list every service exposed by Traefik with its URL
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
├── inventory/
│   ├── hosts.yml                  # proxmox, pihole, traefik and nextcloud hosts
│   └── group_vars/
│       ├── all.yml                # vars common to every host (SSH, python)
│       ├── proxmox.yml            # hypervisor config + API auth + LXC specs
│       ├── pihole.yml             # Pi-hole app config (DNS, DHCP)
│       ├── traefik.yml            # Traefik domain and backend IPs
│       └── nextcloud.yml          # Nextcloud app config
├── playbooks/
│   ├── proxmox/                   # hypervisor bootstrap and administration
│   ├── pihole/                    # provisioning and deployment of Pi-hole
│   ├── traefik/                   # provisioning and deployment of Traefik
│   └── nextcloud/                 # provisioning and deployment of the Nextcloud service
├── roles/
│   ├── proxmox_lxc/                # generic LXC creation via the Proxmox API
│   ├── lxc_bootstrap/              # SSH setup inside a new LXC
│   ├── docker/                     # Docker installation
│   ├── pihole/                     # Pi-hole install, DNS/DHCP and homelab DNS rule
│   ├── traefik/                    # Traefik config, TLS and per-service routes
│   └── nextcloud/                  # directories, docker compose stack, configuration
├── scripts/
│   └── generate-homelab-certificates.sh  # Root CA + Traefik certificate (one SAN per host)
└── docs/
    └── certificates.md             # certificate generation and client install
```

See `CLAUDE.md` for more details on conventions and commands.
