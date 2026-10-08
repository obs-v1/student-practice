# bankobs platform deploy — vendored into student-practice so this repo is self-contained.
# Brings up the ~75-service bankobs application (databases, Kafka, RabbitMQ, license-checker,
# and the Helm-installed services) onto the CURRENT kube context. No observability stack —
# the student-practice lab adds Prometheus/Loki/Jaeger by hand.
#
#   make deploy   platform + Helm chart + env wiring   (what `student-practice: make app` calls)
#   make wait     block until the data stores are Ready and seeded
#   make down     delete the whole bankobs namespace
#
# Needs a LICENSE_KEY (the images refuse to start without it): copy .env.example to .env and
# paste your key, or pass it inline:  LICENSE_KEY=eyJ... make deploy
SHELL          := /bin/bash
.DEFAULT_GOAL  := help

NS             := bankobs
RELEASE        := bankobs
HELM_DIR       := helm/bankobserve360
KCTL           := kubectl -n $(NS)
HELM_SSA       := $(shell helm version --short 2>/dev/null | grep -q "^v4" && echo --force-conflicts)

HOST_MACHINE_ID := $(shell if [ -f /etc/machine-id ]; then cat /etc/machine-id; else echo unknown; fi)
HOST_MAC        := $(shell ip -o link show 2>/dev/null | awk -F'link/ether ' 'NR==2{print $$2}' | awk '{print $$1}')
HOST_HOSTNAME   := $(shell hostname)
# Overridable from the environment:  LICENSE_KEY=eyJ... make deploy
LICENSE_KEY     ?= $(shell grep '^LICENSE_KEY=' .env 2>/dev/null | cut -d= -f2-)

.PHONY: help deploy _wire-apps _check-license wait seed-extras down

help: ## Show this help
	@grep -hE '^[a-zA-Z0-9_-]+:.*?## ' $(MAKEFILE_LIST) | sed -E 's/:.*## /\t/' | awk -F '\t' '{printf "  \033[36m%-10s\033[0m %s\n", $$1, $$2}'

deploy: _check-license ## Deploy the platform: infra manifests + Helm chart + env wiring
	@echo "🏗  [1/5] namespace + init ConfigMaps + license Secret"
	@kubectl create namespace $(NS) --dry-run=client -o yaml | kubectl apply -f -
	@$(KCTL) create configmap oracle-init            --from-file=infrastructure/databases/oracle/init-scripts        --dry-run=client -o yaml | kubectl apply -f -
	@$(KCTL) create configmap postgres-init          --from-file=infrastructure/databases/postgres/init-scripts      --dry-run=client -o yaml | kubectl apply -f -
	@$(KCTL) create configmap mongo-init             --from-file=infrastructure/databases/mongodb/init-scripts       --dry-run=client -o yaml | kubectl apply -f -
	@$(KCTL) create configmap cassandra-init-scripts --from-file=infrastructure/databases/cassandra/init-scripts     --dry-run=client -o yaml | kubectl apply -f -
	@$(KCTL) create configmap es-init-scripts        --from-file=infrastructure/databases/elasticsearch/init-scripts --dry-run=client -o yaml | kubectl apply -f -
	@$(KCTL) create configmap kafka-init-scripts     --from-file=infrastructure/messaging/kafka                      --dry-run=client -o yaml | kubectl apply -f -
	@$(KCTL) create configmap rabbitmq-definitions   --from-file=infrastructure/messaging/rabbitmq/definitions.json  --dry-run=client -o yaml | kubectl apply -f -
	@$(KCTL) create configmap redis-conf             --from-file=infrastructure/databases/redis/redis.conf           --dry-run=client -o yaml | kubectl apply -f -
	@$(KCTL) create secret generic bankobs-license \
	  --from-literal=LICENSE_KEY='$(LICENSE_KEY)' \
	  --from-literal=HOST_MACHINE_ID='$(HOST_MACHINE_ID)' \
	  --from-literal=HOST_MAC='$(HOST_MAC)' \
	  --from-literal=HOST_HOSTNAME='$(HOST_HOSTNAME)' \
	  --dry-run=client -o yaml | kubectl apply -f -
	@echo ""
	@echo "🗄  [2/5] infrastructure (databases, Kafka, RabbitMQ, license-checker, portal)"
	@$(KCTL) delete job -l part-of=bankobs-init --ignore-not-found >/dev/null
	@kubectl apply -f manifests/platform/
	@echo ""
	@echo "🔑 [3/5] waiting for license-checker (app services refuse to start without it)"
	@$(KCTL) rollout status deployment/license-checker --timeout=10m
	@echo ""
	@echo "⛵ [4/5] Helm — the application services (public images, no build)"
	@helm status $(RELEASE) -n $(NS) >/dev/null 2>&1 && $(MAKE) -s _wire-apps || true
	@helm dependency build $(HELM_DIR) >/dev/null 2>&1 || true
	@helm upgrade --install $(RELEASE) $(HELM_DIR) -n $(NS) $(HELM_SSA) \
	  -f $(HELM_DIR)/values.yaml -f values-kind.yaml --timeout 20m
	@echo ""
	@echo "🔌 [5/5] wiring compose-equivalent environment into every app service"
	@$(MAKE) -s _wire-apps
	@echo "✓ bankobs deployed. First-run image pulls take 15–40 min (Oracle/Cassandra are slow)."
	@echo "  make wait   # block until the data stores are Ready + seeded"

# Injects the compose-equivalent env (from the bankobs-env ConfigMap) into every app service
# as LITERAL values, and halves the chart's CPU request so the full stack fits a smaller host.
# Idempotent. (domain != platform: license-checker/web-portal stay kubectl-apply-clean.)
_wire-apps:
	@$(KCTL) get deploy -l 'domain,domain!=platform' -o name | \
	  xargs -I{} $(KCTL) patch {} --type=merge \
	    -p '{"spec":{"strategy":{"type":"RollingUpdate","rollingUpdate":{"maxSurge":0,"maxUnavailable":1}}}}' >/dev/null
	@VALS=$$($(KCTL) get configmap bankobs-env -o go-template='{{range $$k, $$v := .data}}{{$$k}}={{$$v}} {{end}}'); \
	for d in $$($(KCTL) get deploy -l 'domain,domain!=platform' -o name); do \
	  $(KCTL) set env $$d $$VALS >/dev/null || exit 1; \
	done
	@$(KCTL) set resources deployment -l 'domain,domain!=platform' --requests=cpu=50m,memory=128Mi >/dev/null
	@echo "✓ env injected (deployments roll once with the DB/Kafka/license settings)"

_check-license:
	@[ -n "$(LICENSE_KEY)" ] || { \
	  echo "✗ LICENSE_KEY is empty."; \
	  echo "    cp .env.example .env   and paste your key as LICENSE_KEY=..."; \
	  echo "    (or run: LICENSE_KEY=eyJ... make deploy)"; exit 1; }

wait: ## Block until all data stores are Ready, then apply post-boot seeds
	@for s in postgres mongodb redis rabbitmq kafka elasticsearch cassandra oracle; do \
	  echo "→ waiting for $$s"; \
	  $(KCTL) rollout status statefulset/$$s --timeout=20m || exit 1; \
	done
	@echo "→ waiting for init jobs (Kafka topics, Cassandra keyspace, ES indices)"
	@$(KCTL) wait --for=condition=complete job -l part-of=bankobs-init --timeout=15m
	@$(MAKE) -s seed-extras
	@echo "✓ all data stores ready and seeded"

seed-extras:
	@$(KCTL) exec postgres-0 -- psql -U bankobs -d bankobs_retail -c \
	  "ALTER TABLE fixed_deposits     ALTER COLUMN fd_id TYPE VARCHAR(40); \
	   ALTER TABLE recurring_deposits ALTER COLUMN rd_id TYPE VARCHAR(40);" >/dev/null 2>&1 || true
	@$(KCTL) exec postgres-0 -- psql -U bankobs -d bankobs_retail -c \
	  "INSERT INTO credit_cards (card_id, customer_id, card_number_masked, credit_limit, current_balance, status) \
	   SELECT 'CC-CUST' || lpad(g::text, 3, '0') || '-0001', 'CUST-' || lpad(g::text, 8, '0'), \
	   'XXXX XXXX XXXX ' || lpad((1000 + g)::text, 4, '0'), \
	   (CASE WHEN g % 5 = 0 THEN 500000 WHEN g % 3 = 0 THEN 300000 WHEN g % 2 = 0 THEN 150000 ELSE 75000 END)::numeric, \
	   ((g % 11) * 5000)::numeric, CASE WHEN g % 50 = 0 THEN 'BLOCKED' ELSE 'ACTIVE' END \
	   FROM generate_series(1, 500) g ON CONFLICT (card_id) DO NOTHING;" >/dev/null 2>&1 || true
	@echo "✓ extra seeds applied"

down: ## Delete the entire bankobs namespace (app + databases)
	kubectl delete namespace $(NS) --ignore-not-found
