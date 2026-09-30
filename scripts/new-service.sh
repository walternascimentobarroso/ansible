#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 4 ]]; then
    echo "Usage: $0 <name> <vmid> <ip> <port>" >&2
    exit 1
fi

NAME="$1"
VMID="$2"
IP="$3"
PORT="$4"

if [[ -d "roles/${NAME}" || -d "playbooks/${NAME}" ]]; then
    echo "Service '${NAME}' already exists." >&2
    exit 1
fi

echo "==> Inventory"

cat >> inventory/hosts.yml <<EOF

${NAME}:
  hosts:
    ${NAME}-server:
EOF

cat > "inventory/host_vars/${NAME}-server.yml" <<EOF
---
ansible_host: "{{ lxc.ip }}"

lxc:
  vmid: ${VMID}
  hostname: ${NAME}
  cores: 1
  memory: 1024
  swap: 512
  disk: 8
  ip: ${IP}
  features: nesting=1
EOF

echo "==> Playbooks"

mkdir -p "playbooks/${NAME}"

cat > "playbooks/${NAME}/deploy.yml" <<EOF
---
- name: Create LXC
  ansible.builtin.import_playbook: ../lxc/create.yml
  vars:
    service: ${NAME}

- name: Bootstrap LXC
  ansible.builtin.import_playbook: ../lxc/bootstrap.yml
  vars:
    service: ${NAME}

- name: Configure app
  ansible.builtin.import_playbook: configure-app.yml
EOF

cat > "playbooks/${NAME}/configure-app.yml" <<EOF
---
- name: Configure ${NAME}
  hosts: ${NAME}
  become: true

  roles:
    - docker
    - ${NAME}
EOF

cat >> site.yml <<EOF

- name: Deploy ${NAME}
  ansible.builtin.import_playbook: playbooks/${NAME}/deploy.yml
EOF

echo "==> Role"

mkdir -p "roles/${NAME}/tasks" "roles/${NAME}/templates"

cat > "roles/${NAME}/tasks/main.yml" <<EOF
---
- name: Create ${NAME} directory
  ansible.builtin.file:
    path: /opt/${NAME}
    state: directory
    mode: "0755"

- name: Deploy ${NAME} Docker Compose
  ansible.builtin.template:
    src: compose.yml.j2
    dest: /opt/${NAME}/compose.yml
    owner: root
    group: root
    mode: "0600"

- name: Start ${NAME} stack
  community.docker.docker_compose_v2:
    project_src: /opt/${NAME}
EOF

cat > "roles/${NAME}/templates/compose.yml.j2" <<EOF
services:
  ${NAME}:
    image: CHANGE_ME
    container_name: ${NAME}
    restart: unless-stopped

    ports:
      - "${PORT}:${PORT}"
EOF

echo "==> Traefik route"

cat > "roles/traefik/templates/routes/${NAME}.yml.j2" <<EOF
http:
  routers:
    ${NAME}:
      rule: "Host(\`${NAME}.{{ homelab_domain }}\`)"
      entryPoints:
        - websecure
      service: ${NAME}
      tls: {}

  services:
    ${NAME}:
      loadBalancer:
        servers:
          - url: "http://{{ hostvars[groups['${NAME}'][0]].ansible_host }}:${PORT}"
EOF

echo
echo "Service '${NAME}' created. Next steps:"
echo "  1. Set the image in roles/${NAME}/templates/compose.yml.j2 and adjust the LXC specs in inventory/host_vars/${NAME}-server.yml"
echo "  2. make deploy NAME=${NAME}"
echo "  3. make traefik-reload"
