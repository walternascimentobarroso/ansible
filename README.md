# Homelab Ansible

Ansible automation for the homelab, running inside a Docker container (no need to install Ansible on the host). The `proxmox` playbooks provision the hypervisor, and the `nextcloud` playbooks create and configure an LXC running Nextcloud.

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

## 6. Create and configure the Nextcloud machine

With Proxmox already prepared, create the LXC, inject the SSH key into it, and install/configure Nextcloud (Docker + Postgres + Redis), all with a single command:

```bash
make playbook PLAYBOOK=playbooks/nextcloud/deploy.yml
```

This aggregates, in order:

1. `create-lxc.yml` — creates the LXC on Proxmox via the API (specs from `.env`, resolved through `inventory/group_vars/nextcloud.yml`).
2. `bootstrap-lxc.yml` — installs `openssh-server` inside the LXC and authorizes the automation's key.
3. `configure-app.yml` — installs Docker on the LXC and brings up the Nextcloud stack (Postgres, Redis, Nextcloud), waiting for the installation to finish.

At the end, Nextcloud is reachable at `http://<NEXTCLOUD_IP>` with the credentials set in `NEXTCLOUD_ADMIN_USER` / `NEXTCLOUD_ADMIN_PASSWORD`.

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
│   ├── hosts.yml                  # proxmox and nextcloud hosts
│   └── group_vars/
│       ├── all.yml                # vars common to every host (SSH, python)
│       ├── proxmox.yml            # hypervisor config + API auth
│       └── nextcloud.yml          # LXC spec and Nextcloud app config
├── playbooks/
│   ├── proxmox/                   # hypervisor bootstrap and administration
│   └── nextcloud/                 # provisioning and deployment of the Nextcloud service
└── roles/
    ├── proxmox_lxc/                # generic LXC creation via the Proxmox API
    ├── docker/                     # Docker installation
    └── nextcloud/                  # directories, docker compose stack, configuration
```

See `CLAUDE.md` for more details on conventions and commands.
