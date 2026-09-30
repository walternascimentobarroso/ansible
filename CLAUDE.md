# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

Homelab Ansible project. Ansible itself runs inside a Docker container (not installed on the host), built from a `python:3.13-slim` image with `ansible`, `ansible-lint`, `proxmoxer`, and `requests` installed via pip, plus `openssh-client` for connecting to managed hosts. The host's SSH keys (`~/.ssh`) are mounted read-only into the container so Ansible can reach remote hosts, and the whole repo is bind-mounted to `/ansible` inside the container.

The `proxmoxer` dependency indicates this inventory/playbooks are intended to target a Proxmox-based homelab.

Each service (`pihole`, `traefik`, `nextcloud`, `ai`) is one inventory group with one host (`<service>-server`) running in its own LXC. Its LXC specs live in `inventory/host_vars/<service>-server.yml` under an `lxc:` dict, and `ansible_host` is derived from `lxc.ip`. The network shared by all LXCs (CIDR, gateway) is in `group_vars/proxmox.yml`.

Creating and bootstrapping an LXC is generic: `playbooks/lxc/create.yml` and `playbooks/lxc/bootstrap.yml` run on `proxmox` and read `hostvars[groups[service][0]].lxc`, where `service` is passed via `import_playbook` vars or `-e service=<name>`. Each `playbooks/<service>/` has only `deploy.yml` (lxc/create → lxc/bootstrap → configure-app) and `configure-app.yml`. `site.yml` imports every `deploy.yml`. Service logic lives in `roles/<service>/`, and Docker stacks are started with `community.docker.docker_compose_v2`.

Traefik routes are one file per service in `roles/traefik/templates/routes/`; every file there is deployed automatically (fileglob). Backend IPs come from `hostvars[groups['<service>'][0]].ansible_host`.

Variables: `group_vars/all.yml` holds SSH settings plus `homelab_domain` and `traefik_ip`; `proxmox.yml` holds hypervisor/API config; `<service>.yml` holds app config. `.env` holds only secrets and app settings, read via `lookup('env', ...)` inside `group_vars`, never hardcoded or re-looked-up inside playbooks. Non-secret specs are versioned in `host_vars`, not in `.env`.

## Commands

All Ansible commands run inside the Docker container via `make`, not directly on the host.

```bash
make build            # build the ansible container image
make up                # start the container in the background
make bash              # open a shell inside the container
make stop               # stop the container
make destroy            # stop and remove the container
make rebuild             # destroy + build + up (rebuild image from scratch)
make logs               # follow container logs

make ping                                  # ping all hosts in the inventory
make deploy NAME=ai                        # create + bootstrap + configure one service
make site                                  # deploy every service
make playbook PLAYBOOK=<path> [NAME=ai]    # run a playbook (NAME → -e service=...)
make syntax-check PLAYBOOK=<path>          # syntax-check one playbook
make syntax-check-all                      # syntax-check every playbook
make lint                                  # ansible-lint
make certs                                 # generate Root CA (once) + renew Traefik certificate
make traefik-reload                        # certs + redeploy Traefik
make new-service NAME=foo VMID=105 IP=192.168.1.6 PORT=3000   # scaffold a new service
```

The Makefile auto-detects whether `docker-compose` (standalone) or `docker compose` (plugin) is available and uses whichever is present.

## Principles

Always follow **YAGNI, KISS and DRY**. Before adding code, check whether an existing generic piece (`playbooks/lxc/`, `routes/`, `new-service.sh`, `host_vars`) already covers it; never copy a playbook, template or task per service when a loop, a dict or a generic playbook solves it. Don't add abstractions, variables or options with no current use, and delete dead code instead of leaving it behind.

## Conventions

- Indentation is 2 spaces (4 in shell scripts, tabs in the Makefile), LF line endings, UTF-8 (see `.editorconfig`).
- The Traefik certificate has one SAN per host, taken from the `Host(...)` rules under `roles/traefik/templates/`. Never use a `*.home.arpa` wildcard: `home.arpa` is a public suffix and Apple's TLS stack rejects it. After adding or renaming a `Host(...)` rule, run `make traefik-reload`.
- New services are created with `make new-service`, never by copying another service's files by hand.
