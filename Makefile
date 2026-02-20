SERVICES := account-service auth-service dead-letter-queue notification-service
DEV_TARGETS := $(addprefix dev-,$(SERVICES))
COMPOSE := podman compose

.PHONY: infra infra-down logs-up logs-down build setup generate-keys $(SERVICES) $(DEV_TARGETS) admin-ui-install admin-ui-dev admin-ui-build

## Start infrastructure (Kafka)
infra:
	$(COMPOSE) up -d

## Stop infrastructure
infra-down:
	$(COMPOSE) down

## Start logging stack (Loki + Promtail + Grafana) — http://localhost:3000
logs-up:
	$(COMPOSE) --profile logging up -d

## Stop logging stack
logs-down:
	$(COMPOSE) --profile logging down

## Generate a fresh EC P-256 key pair (prints JWT_PRIVATE_KEY and JWT_PUBLIC_KEY)
generate-keys:
	stack runghc scripts/generate-keys.hs

## Build all services
build:
	stack build

## Copy .env.example → .env for every service and app that doesn't have one yet
setup:
	@for svc in $(SERVICES); do \
		if [ ! -f "services/$$svc/.env" ]; then \
			cp "services/$$svc/.env.example" "services/$$svc/.env"; \
			echo "Created services/$$svc/.env"; \
		else \
			echo "Skipped services/$$svc/.env (already exists)"; \
		fi; \
	done
	@if [ ! -f "apps/admin-ui/.env" ]; then \
		cp "apps/admin-ui/.env.example" "apps/admin-ui/.env"; \
		echo "Created apps/admin-ui/.env"; \
	else \
		echo "Skipped apps/admin-ui/.env (already exists)"; \
	fi

## Run a service (loads services/<name>/.env automatically)
$(SERVICES):
	@./scripts/run.sh $@

## Run a service with auto-reload on source changes (requires ghcid)
$(DEV_TARGETS):
	@./scripts/dev.sh $(patsubst dev-%,%,$@)

## Install admin UI dependencies
admin-ui-install:
	cd apps/admin-ui && npm install

## Start admin UI dev server (http://localhost:5173)
admin-ui-dev:
	cd apps/admin-ui && npm run dev

## Build admin UI for production
admin-ui-build:
	cd apps/admin-ui && npm run build
