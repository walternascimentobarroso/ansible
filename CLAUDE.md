# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

Homelab Ansible project. Ansible itself runs inside a Docker container (not installed on the host), built from a `python:3.13-slim` image with `ansible`, `proxmoxer`, and `requests` installed via pip, plus `openssh-client` for connecting to managed hosts. The host's SSH keys (`~/.ssh`) are mounted read-only into the container so Ansible can reach remote hosts, and the whole repo is bind-mounted to `/ansible` inside the container.

The `proxmoxer` dependency indicates this inventory/playbooks are intended to target a Proxmox-based homelab.

`inventory/`, `playbooks/`, and `roles/` are currently empty — populate them with standard Ansible inventory files, playbooks, and roles respectively.

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

make ping                                    # ping all hosts in the inventory
make playbook PLAYBOOK=site.yml              # run a playbook
make syntax-check PLAYBOOK=site.yml          # syntax-check a playbook without running it
```

The Makefile auto-detects whether `docker-compose` (standalone) or `docker compose` (plugin) is available and uses whichever is present.

## Conventions

- Indentation is 4 spaces, LF line endings, UTF-8 (see `.editorconfig`).
