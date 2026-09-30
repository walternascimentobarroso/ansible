NOCOLOR=\033[0m
GREEN=\033[0;32m
BGREEN=\033[1;32m
YELLOW=\033[0;33m
CYAN=\033[0;36m
RED=\033[0;31m
BREAK=\n

DOCKER_COMPOSE := $(shell command -v docker-compose 2> /dev/null)
ifeq ($(strip $(DOCKER_COMPOSE)),)
    DOCKER_COMPOSE := docker compose
else
    DOCKER_COMPOSE := docker-compose
endif

SERVICE := ansible
HOMELAB_DOMAIN := $(or $(shell sed -n 's/^HOMELAB_DOMAIN=//p' .env 2>/dev/null),home.arpa)

.DEFAULT_GOAL := help

.PHONY: help
help:
	@awk 'BEGIN {FS = ":.*##"; printf "\n${BGREEN}Usage:${NOCOLOR}\n  make ${CYAN}<target>${NOCOLOR}\n"} /^[a-zA-Z0-9_-]+:.*?##/ { printf "  ${CYAN}%-15s${NOCOLOR} %s\n", $$1, $$2 } /^## [A-Za-z]/ { printf "\n${YELLOW}%s${NOCOLOR}\n", substr($$0, 4) }' $(MAKEFILE_LIST)

## General commands:

.PHONY: build
build: ## Build the ansible container image
	$(DOCKER_COMPOSE) build

.PHONY: up
up: ## Start the ansible container in the background
	$(DOCKER_COMPOSE) up -d

.PHONY: stop
stop: ## Stop the ansible container
	$(DOCKER_COMPOSE) stop

.PHONY: restart
restart: stop up ## Restart the ansible container

.PHONY: destroy
destroy: ## Stop and remove the ansible container
	$(DOCKER_COMPOSE) down

.PHONY: rebuild
rebuild: destroy build up ## Rebuild the container image from scratch and start it

.PHONY: logs
logs: ## Follow the ansible container logs
	$(DOCKER_COMPOSE) logs -f $(SERVICE)

.PHONY: bash
bash: ## Open a shell inside the ansible container
	$(DOCKER_COMPOSE) exec $(SERVICE) bash

.PHONY: hosts
hosts: ## List every service exposed by Traefik with its URL
	@printf "${BGREEN}%-12s %s${NOCOLOR}\n" SERVICE URL
	@grep -rho 'Host(`[^.]*' roles/traefik/templates | cut -d'`' -f2 | sort -u \
		| xargs -I{} printf "%-12s ${CYAN}https://{}.$(HOMELAB_DOMAIN)/${NOCOLOR}\n" {}

## Ansible commands:

.PHONY: ping
ping: ## Ping all hosts in the inventory
	$(DOCKER_COMPOSE) exec $(SERVICE) ansible all -m ping

.PHONY: playbook
playbook: ## Run a playbook, e.g. make playbook PLAYBOOK=playbooks/lxc/create.yml NAME=ai
	$(DOCKER_COMPOSE) exec $(SERVICE) ansible-playbook $(PLAYBOOK) $(if $(NAME),-e service=$(NAME))

.PHONY: deploy
deploy: ## Create, bootstrap and configure a service, e.g. make deploy NAME=ai
	$(DOCKER_COMPOSE) exec $(SERVICE) ansible-playbook playbooks/$(NAME)/deploy.yml

.PHONY: site
site: ## Deploy every service (site.yml)
	$(DOCKER_COMPOSE) exec $(SERVICE) ansible-playbook site.yml

.PHONY: syntax-check
syntax-check: ## Check syntax of a playbook, e.g. make syntax-check PLAYBOOK=site.yml
	$(DOCKER_COMPOSE) exec $(SERVICE) ansible-playbook $(PLAYBOOK) --syntax-check

.PHONY: syntax-check-all
syntax-check-all: ## Check syntax of every playbook under playbooks/
	@for playbook in $$(find playbooks -name '*.yml' | sort); do \
		echo "${CYAN}==> $$playbook${NOCOLOR}"; \
		$(DOCKER_COMPOSE) exec -T $(SERVICE) ansible-playbook "$$playbook" --syntax-check || exit 1; \
	done

.PHONY: lint
lint: ## Run ansible-lint on the whole project
	$(DOCKER_COMPOSE) exec $(SERVICE) ansible-lint

## Homelab commands:

.PHONY: certs
certs: ## Generate the Root CA (once) and renew the Traefik certificate
	HOMELAB_DOMAIN=$(HOMELAB_DOMAIN) ./scripts/generate-homelab-certificates.sh

.PHONY: traefik-reload
traefik-reload: certs ## Regenerate the certificate and redeploy Traefik routes
	$(DOCKER_COMPOSE) exec $(SERVICE) ansible-playbook playbooks/traefik/configure-app.yml

.PHONY: new-service
new-service: ## Scaffold a new service, e.g. make new-service NAME=foo VMID=105 IP=192.168.1.6 PORT=8080
	./scripts/new-service.sh $(NAME) $(VMID) $(IP) $(PORT)
