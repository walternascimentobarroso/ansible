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

## Ansible commands:

.PHONY: ping
ping: ## Ping all hosts in the inventory
	$(DOCKER_COMPOSE) exec $(SERVICE) ansible all -m ping

.PHONY: playbook
playbook: ## Run a playbook, e.g. make playbook PLAYBOOK=site.yml
	$(DOCKER_COMPOSE) exec $(SERVICE) ansible-playbook $(PLAYBOOK)

.PHONY: syntax-check
syntax-check: ## Check syntax of a playbook, e.g. make syntax-check PLAYBOOK=site.yml
	$(DOCKER_COMPOSE) exec $(SERVICE) ansible-playbook $(PLAYBOOK) --syntax-check

.PHONY: syntax-check-all
syntax-check-all: ## Check syntax of every playbook under playbooks/
	@for playbook in $$(find playbooks -name '*.yml' | sort); do \
		echo "${CYAN}==> $$playbook${NOCOLOR}"; \
		$(DOCKER_COMPOSE) exec -T $(SERVICE) ansible-playbook "$$playbook" --syntax-check || exit 1; \
	done
