SERVICES := account-service auth-service dead-letter-queue notification-service

.PHONY: infra infra-down build setup generate-keys $(SERVICES)

## Start infrastructure (Kafka)
infra:
	docker compose up -d

## Stop infrastructure
infra-down:
	docker compose down

## Generate a fresh EC P-256 key pair (prints JWT_PRIVATE_KEY and JWT_PUBLIC_KEY)
generate-keys:
	stack runghc scripts/generate-keys.hs

## Build all services
build:
	stack build

## Copy .env.example → .env for every service that doesn't have one yet
setup:
	@for svc in $(SERVICES); do \
		if [ ! -f "services/$$svc/.env" ]; then \
			cp "services/$$svc/.env.example" "services/$$svc/.env"; \
			echo "Created services/$$svc/.env"; \
		else \
			echo "Skipped services/$$svc/.env (already exists)"; \
		fi; \
	done

## Run a service (loads services/<name>/.env automatically)
$(SERVICES):
	@./scripts/run.sh $@
