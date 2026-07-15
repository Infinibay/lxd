# Infinibay Docker dev environment — thin wrapper over ./dev.sh
# ⚠ DEPRECATED: dev.sh (and these make targets) are superseded by the `iby` CLI.
#   Install:  uv tool install infinibay-iby      Then:  iby up  /  iby --help
# (the LXD production path is unchanged: see setup.sh / run.sh / README.md)

.DEFAULT_GOAL := help
.PHONY: help up up-detached up-kvm down destroy logs pull restart status infiniservice clean

help: ## Show this help  [deprecated → use `iby --help`]
	@printf '\033[33m⚠  dev.sh / make are deprecated — use the `iby` CLI (uv tool install infinibay-iby; iby --help).\033[0m\n\n'
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
	  awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

up: ## Clone/refresh repos and start the stack (live logs)
	@./dev.sh up

up-detached: ## Start the stack in the background
	@./dev.sh up -d

up-kvm: ## Start with the Linux KVM override (Linux hosts only)
	@./dev.sh up --kvm

down: ## Stop the stack (keeps volumes/data)
	@./dev.sh down

destroy: ## Stop and DELETE all volumes (db, node_modules, caches)
	@./dev.sh down -v

logs: ## Follow all logs (use: make logs S=backend)
	@./dev.sh logs $(S)

pull: ## Fast-forward every repo to latest main
	@./dev.sh pull

restart: ## Restart the stack (use: make restart S=backend)
	@./dev.sh restart $(S)

status: ## Show container status
	@./dev.sh status

infiniservice: ## Cross-compile the Rust guest agent
	@./dev.sh build-infiniservice

clean: ## Remove volumes AND built images
	@./dev.sh clean
