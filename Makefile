# ═══════════════════════════════════════════════════════════════════════════════
#  student-practice — build the three observability pillars BY HAND, no OpenTelemetry
# ═══════════════════════════════════════════════════════════════════════════════
#
#  The lesson: today bankobs ships everything through OpenTelemetry. Here you unplug the
#  OTel Collector and wire each backend to the app yourself — so you feel what OTel does
#  for you, before you appreciate why it exists (docs/05).
#
#  Run a whole section, watching every command as it goes:
#      make app        # 1. deploy the 75 services with observability OFF
#      make metrics    # 2. Prometheus — pull /metrics directly (no OTel)
#      make logs       # 3. Loki + Promtail — tail stdout (no OTel)
#      make traces     # 4. Jaeger — the one pillar that still needs in-app OTel
#      make all        # 1→4 in order
#
#  Prefer to type the commands yourself? Add DRY=1 to PRINT every step without running
#  it — the output matches the documentation line for line:
#      make metrics DRY=1
#
#  Check your work / find the UIs / clean up:
#      make verify   ·   make urls   ·   make traffic   ·   make clean
# ───────────────────────────────────────────────────────────────────────────────

APP_NS   ?= bankobs
OBS_NS   ?= monitoring
# the maintained platform deploy we reuse for the app
BOOTCAMP ?= ../student-bootcamp
JAEGER_OTLP ?= http://jaeger-collector.$(OBS_NS).svc:4317

export DRY                              # so scripts/*.sh can see it
SECTION := @scripts/section.sh
STEP    := @scripts/step.sh

.DEFAULT_GOAL := help
.PHONY: help cluster app darken metrics logs traces all traffic \
        verify verify-metrics verify-logs verify-traces urls clean

help: ## Show this help
	@grep -hE '^[a-zA-Z0-9_-]+:.*?## ' $(MAKEFILE_LIST) \
	 | sed -E 's/:.*## /\t/' | awk -F '\t' '{printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "  Tip: DRY=1 prints steps without running them (do-it-by-hand mode)."

# ───────────────────────────────────────────────────────────────────────────────
#  SECTION 0 — the cluster (empty Kubernetes)
# ───────────────────────────────────────────────────────────────────────────────
cluster: ## 0. Create the empty kind cluster on this host
	$(SECTION) "0" "An empty Kubernetes cluster" "Just Kubernetes, nothing deployed yet."
	$(STEP) "Install tooling if needed, then create the cluster" \
	        "$(MAKE) -C cluster up"

# ───────────────────────────────────────────────────────────────────────────────
#  SECTION 1 — the application, with observability switched OFF
# ───────────────────────────────────────────────────────────────────────────────
app: ## 1. Deploy the bankobs services onto the cluster (no observability at all)
	$(SECTION) "1" "The application, dark" "75 services running, emitting nothing, scraped by nothing."
	$(STEP) "Deploy bankobs onto THIS cluster (reuses the bootcamp deploy; does not create a cluster)" \
	        "$(MAKE) -C $(BOOTCAMP)/ec2-k8s deploy"
	@$(MAKE) --no-print-directory darken

darken:  # internal: force every app service to emit nothing — the blank slate
	$(STEP) "Switch ALL application telemetry OFF (the true starting line)" \
	        "kubectl -n $(APP_NS) set env deployment -l domain OTEL_SDK_DISABLED=true OBSERVABILITY_MODE=dark MANAGEMENT_TRACING_ENABLED=false MANAGEMENT_OTLP_METRICS_EXPORT_ENABLED=false"
	@echo ""
	@echo "  ✓ bankobs is up and SILENT. Nothing is collecting metrics, logs or traces."
	@echo "    Next:  make metrics"

# ───────────────────────────────────────────────────────────────────────────────
#  SECTION 2 — METRICS, the pull model (Prometheus), no OTel
# ───────────────────────────────────────────────────────────────────────────────
metrics: ## 2. Prometheus scrapes /metrics directly (no OTel)
	$(SECTION) "2" "Metrics with Prometheus (the pull model)" "Prometheus reaches into the app and scrapes /metrics on a timer. No Collector."
	$(STEP) "Create the monitoring namespace (home for the backends)" \
	        "kubectl apply -f metrics/namespace.yaml"
	$(STEP) "Grant Prometheus read-only access to the Kubernetes API (service discovery)" \
	        "kubectl apply -f metrics/prometheus-rbac.yaml"
	$(STEP) "Install the scrape config — the rules that say WHAT to pull and from WHERE" \
	        "kubectl apply -f metrics/prometheus-config.yaml"
	$(STEP) "Deploy the Prometheus server and wait for it" \
	        "kubectl apply -f metrics/prometheus.yaml && kubectl -n $(OBS_NS) rollout status deploy/prometheus --timeout=120s"
	$(STEP) "Configure the app to BE monitored: opt every service into scraping" \
	        "kubectl -n $(APP_NS) get deploy -l domain -o name | xargs -I{} kubectl -n $(APP_NS) patch {} --type=merge -p '{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"prometheus.io/scrape\":\"true\",\"prometheus.io/path\":\"/metrics\"}}}}}'"
	@echo ""
	@echo "  ✓ Prometheus is pulling the app's /metrics. Give it ~30s, then: make verify-metrics"
	@$(MAKE) -s _url NP=30909 NAME=Prometheus

# ───────────────────────────────────────────────────────────────────────────────
#  SECTION 3 — LOGS (Loki + Promtail), no OTel
# ───────────────────────────────────────────────────────────────────────────────
logs: ## 3. Loki + Promtail tail container stdout (no OTel)
	$(SECTION) "3" "Logs with Loki + Promtail" "Promtail tails the node's container logs and pushes to Loki. The app writes stdout — nothing else."
	$(STEP) "Grant Promtail read-only access to the Kubernetes API" \
	        "kubectl apply -f logs/promtail-rbac.yaml"
	$(STEP) "Deploy Loki (the log store) and wait for it" \
	        "kubectl apply -f logs/loki.yaml && kubectl -n $(OBS_NS) rollout status deploy/loki --timeout=120s"
	$(STEP) "Install Promtail's config — what to tail, which labels to attach, where to push" \
	        "kubectl apply -f logs/promtail-config.yaml"
	$(STEP) "Deploy Promtail (one pod per node) and wait for it" \
	        "kubectl apply -f logs/promtail.yaml && kubectl -n $(OBS_NS) rollout status daemonset/promtail --timeout=120s"
	@echo ""
	@echo "  ✓ Logs are flowing to Loki (no app change was needed). Then: make verify-logs"

# ───────────────────────────────────────────────────────────────────────────────
#  SECTION 4 — TRACES (Jaeger) — the pillar that still needs in-app OTel
# ───────────────────────────────────────────────────────────────────────────────
traces: ## 4. Jaeger receives traces straight from the app (no Collector)
	$(SECTION) "4" "Traces with Jaeger" "Point the app's OTLP straight at Jaeger — no Collector. But note WHY the app can speak OTLP at all (docs/04)."
	$(STEP) "Deploy Jaeger all-in-one with its native OTLP receiver, and wait" \
	        "kubectl apply -f traces/jaeger.yaml && kubectl -n $(OBS_NS) rollout status deploy/jaeger --timeout=120s"
	$(STEP) "Point ONLY traces at Jaeger directly (metrics+logs stay on Prometheus/Loki)" \
	        "kubectl -n $(APP_NS) set env deployment -l domain OTEL_SDK_DISABLED=false OBSERVABILITY_MODE=full MANAGEMENT_TRACING_ENABLED=true OTEL_TRACES_EXPORTER=otlp OTEL_METRICS_EXPORTER=none OTEL_LOGS_EXPORTER=none OTEL_EXPORTER_OTLP_PROTOCOL=grpc OTEL_EXPORTER_OTLP_ENDPOINT=$(JAEGER_OTLP)"
	@echo ""
	@echo "  ✓ Traces are going app → Jaeger directly. Generate traffic, then: make verify-traces"
	@echo "    The catch (docs/04): the app can only do this because it is OTel-instrumented."

all: app metrics logs traces ## 1→4 in order (the full by-hand build)
	@echo ""
	@echo "═══ Done, by hand. Metrics in Prometheus, logs in Loki, traces in Jaeger ═══"
	@echo "    Now read docs/05-why-opentelemetry.md — three backends, three mechanisms,"
	@echo "    three configs. OTel's Collector + SDK is what collapses all of that into one."

# ───────────────────────────────────────────────────────────────────────────────
#  TRAFFIC + VERIFY + URLS + CLEAN
# ───────────────────────────────────────────────────────────────────────────────
traffic: ## Generate load so there is something to see (~60s)
	$(STEP) "Drive the bankobs portal journeys for ~60s" \
	        "timeout 60 bash $(BOOTCAMP)/scripts/loadrunner.sh || true"

verify: verify-metrics verify-logs verify-traces ## Check all three pillars

verify-metrics: ## How many app targets is Prometheus scraping?
	$(STEP) "Ask Prometheus how many bankobs targets are UP" \
	  "kubectl -n $(OBS_NS) port-forward svc/prometheus 9090:9090 >/dev/null 2>&1 & PF=$$!; sleep 4; \
	   echo -n '  bankobs targets up: '; \
	   curl -s 'http://localhost:9090/api/v1/query?query=up%7Bnamespace%3D%22$(APP_NS)%22%7D' | jq '[.data.result[]|select(.value[1]==\"1\")]|length'; \
	   kill $$PF 2>/dev/null || true"

verify-logs: ## Which app services are landing in Loki?
	$(STEP) "Ask Loki which app labels it has seen" \
	  "kubectl -n $(OBS_NS) port-forward svc/loki 3100:3100 >/dev/null 2>&1 & PF=$$!; sleep 4; \
	   echo '  apps reporting logs:'; \
	   curl -s 'http://localhost:3100/loki/api/v1/label/app/values' | jq -r '.data[]? // \"  (none yet — run make traffic)\"' | sed 's/^/    /'; \
	   kill $$PF 2>/dev/null || true"

verify-traces: ## Which app services have sent traces to Jaeger?
	$(STEP) "Ask Jaeger which services have reported traces" \
	  "kubectl -n $(OBS_NS) port-forward svc/jaeger 16686:16686 >/dev/null 2>&1 & PF=$$!; sleep 4; \
	   echo '  services in Jaeger:'; \
	   curl -s 'http://localhost:16686/api/services' | jq -r '.data[]? // \"  (none yet — run make traffic)\"' | sed 's/^/    /'; \
	   kill $$PF 2>/dev/null || true"

urls: ## Print the UI URLs
	@$(MAKE) -s _url NP=30909 NAME=Prometheus
	@$(MAKE) -s _url NP=30686 NAME=Jaeger
	@echo "  Loki      (no UI): kubectl -n $(OBS_NS) port-forward svc/loki 3100:3100  ->  http://localhost:3100"

_url:
	@IP=$$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="ExternalIP")].address}' 2>/dev/null); \
	 [ -z "$$IP" ] && IP=$$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null); \
	 printf "  %-10s UI: http://%s:%s\n" "$(NAME)" "$$IP" "$(NP)"

clean: ## Remove the hand-built backends (leaves the app running)
	$(STEP) "Delete the monitoring namespace (Prometheus, Loki, Promtail, Jaeger)" \
	        "kubectl delete namespace $(OBS_NS) --ignore-not-found"
	$(STEP) "Return the app to dark (undo the trace wiring)" \
	        "kubectl -n $(APP_NS) set env deployment -l domain OTEL_SDK_DISABLED=true OBSERVABILITY_MODE=dark MANAGEMENT_TRACING_ENABLED=false OTEL_TRACES_EXPORTER- OTEL_METRICS_EXPORTER- OTEL_LOGS_EXPORTER- OTEL_EXPORTER_OTLP_ENDPOINT- OTEL_EXPORTER_OTLP_PROTOCOL- || true"
	@echo "  ✓ backends gone, app back to blank slate. (To delete the app: make -C $(BOOTCAMP)/ec2-k8s down)"
