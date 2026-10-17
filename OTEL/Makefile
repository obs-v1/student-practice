# ═══════════════════════════════════════════════════════════════════════════════
#  OTEL — the SAME three pillars, but wired through OpenTelemetry (the counterpart lab)
# ═══════════════════════════════════════════════════════════════════════════════
#
#  The parent lab (../) builds metrics, logs and traces BY HAND — three separate mechanisms,
#  no Collector. This module keeps the exact same backends (Prometheus, Loki, Jaeger) but the
#  app emits ALL THREE signals through the OTel SDK over OTLP to ONE OpenTelemetry Collector,
#  which fans them out. One agent, one wire, swap a backend without touching the app.
#
#  Run it (on the box, after the parent lab's cluster + app exist):
#      make backends            # Prometheus + Loki + Jaeger (reuses ../metrics ../logs ../traces)
#      make enable-remote-write # flip ONE flag so Prometheus accepts pushed metrics
#      make collector           # the OpenTelemetry Collector (collector/values.yaml)
#      make app-otel            # point the app's OTLP (all 3 signals) at the Collector
#      make all                 # the four above, in order
#
#  Prefer to type commands yourself?  add DRY=1 to PRINT each step without running it.
#  Check / find UIs / clean up:   make verify   ·   make urls   ·   make traffic   ·   make clean
# ───────────────────────────────────────────────────────────────────────────────

APP_NS       ?= bankobs
OBS_NS       ?= monitoring
COLLECTOR    ?= http://otel-collector.$(OBS_NS).svc:4317
# Pin the collector CHART to match the pinned contrib IMAGE (0.102.1). The chart must NOT be
# left floating: a newer chart auto-renames the `otlp` exporter to `otlp_grpc`, which the
# 0.102.1 binary does not recognise -> the collector crashloops ("unknown type otlp_grpc").
# Chart 0.93.3 ships appVersion 0.102.1 and predates that rename.
OTEL_CHART_VER ?= 0.93.3
# PARENT = the by-hand lab (reused backends live there). Keep the comment on its OWN line:
# an inline "# ..." after the value makes Make keep the alignment spaces as trailing chars,
# so $(PARENT) becomes "..<spaces>" and every $(PARENT)/path step breaks.
PARENT       ?= ..

export DRY                                 # so scripts/*.sh can see it
SECTION := @scripts/section.sh
STEP    := @scripts/step.sh

# traffic: reuse the parent lab's load generator. Lower = denser (clearer graphs).
# FAIL/SWEEP default to 0 so the baseline is a clean ~96% 2xx — a fault's error spike then
# stands out instead of hiding in loadrunner's own noise.
LOAD_INTERVAL ?= 0.5
LOAD_FAIL     ?= 0
LOAD_SWEEP    ?= 0

# Fault + Grafana wiring is REUSED from the parent lab (same metric names/labels land in
# Prometheus here, so the same dashboards + faultctl work unchanged).
PARENT_SCRIPTS ?= $(PARENT)/scripts
FAULTCTL       ?= $(PARENT)/faults/faultctl.sh

.DEFAULT_GOAL := help
.PHONY: help backends enable-remote-write collector app-otel all \
        grafana datasources golden-dashboard observe \
        fault fault-stop fault-status fault-list \
        traffic traffic-bg traffic-stop verify verify-collector verify-metric-names \
        verify-logs verify-traces urls clean _url

help: ## Show this help
	@grep -hE '^[a-zA-Z0-9_-]+:.*?## ' $(MAKEFILE_LIST) \
	 | sed -E 's/:.*## /\t/' | awk -F '\t' '{printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "  Order:  make backends → enable-remote-write → collector → app-otel   (or: make all)"
	@echo "  Assumes the parent lab's cluster + bankobs app are already up (see ../README.md)."
	@echo "  Tip: DRY=1 prints steps without running them (do-it-by-hand mode)."

# ───────────────────────────────────────────────────────────────────────────────
#  SECTION 1 — the backends (REUSED from the parent lab, unchanged)
# ───────────────────────────────────────────────────────────────────────────────
backends: ## 1. Install Prometheus + Loki + Jaeger (reuses ../metrics ../logs ../traces)
	$(SECTION) "1" "The backends (reused)" "Same Prometheus, Loki and Jaeger as the by-hand lab. The Collector will export TO them."
	$(STEP) "Prometheus (Helm) — the parent lab's exact values" \
	        "helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1; helm repo update prometheus-community >/dev/null; helm upgrade --install prometheus prometheus-community/prometheus -n $(OBS_NS) --create-namespace -f $(PARENT)/metrics/values.yaml && kubectl -n $(OBS_NS) rollout status deploy/prometheus-server --timeout=180s"
	$(STEP) "Loki (Helm) — WITHOUT Promtail: the Collector's filelog receiver tails logs instead" \
	        "helm repo add grafana https://grafana.github.io/helm-charts >/dev/null 2>&1; helm repo update grafana >/dev/null; helm upgrade --install loki grafana/loki-stack -n $(OBS_NS) --create-namespace -f $(PARENT)/logs/values.yaml --set promtail.enabled=false && kubectl -n $(OBS_NS) rollout status statefulset/loki --timeout=180s"
	$(STEP) "Jaeger all-in-one (Helm) + its NodePort UI — the parent lab's exact values" \
	        "helm repo add jaegertracing https://jaegertracing.github.io/helm-charts >/dev/null 2>&1; helm repo update jaegertracing >/dev/null; helm upgrade --install jaeger jaegertracing/jaeger --version 3.4.1 -n $(OBS_NS) --create-namespace -f $(PARENT)/traces/values.yaml && kubectl -n $(OBS_NS) rollout status deploy/jaeger --timeout=180s && kubectl apply -f $(PARENT)/traces/jaeger-ui.yaml"
	@echo ""
	@echo "  ✓ backends up. Unlike the by-hand lab, we do NOT opt pods into scraping and we do"
	@echo "    NOT point the app at Jaeger — the Collector will feed all three. Next: make enable-remote-write"

# ───────────────────────────────────────────────────────────────────────────────
#  SECTION 2 — let Prometheus ACCEPT pushed metrics (the one backend tweak OTel needs)
# ───────────────────────────────────────────────────────────────────────────────
enable-remote-write: ## 2. Turn on Prometheus's remote-write RECEIVER (so OTLP metrics can be pushed in)
	$(SECTION) "2" "Prometheus: accept pushes" "By-hand Prometheus only PULLS. The OTel pipeline PUSHES, so flip on the remote-write receiver."
	$(STEP) "helm upgrade Prometheus with --web.enable-remote-write-receiver (collector/prometheus-rw.values.yaml)" \
	        "helm upgrade prometheus prometheus-community/prometheus -n $(OBS_NS) -f $(PARENT)/metrics/values.yaml -f collector/prometheus-rw.values.yaml && kubectl -n $(OBS_NS) rollout status deploy/prometheus-server --timeout=180s"
	@echo "  ✓ Prometheus now accepts remote-write at http://prometheus-server/api/v1/write"

# ───────────────────────────────────────────────────────────────────────────────
#  SECTION 3 — the OpenTelemetry Collector (the one new moving part)
# ───────────────────────────────────────────────────────────────────────────────
collector: ## 3. Deploy the OpenTelemetry Collector (scrape + tail + OTLP in → Prometheus + Loki + Jaeger out)
	$(SECTION) "3" "The OpenTelemetry Collector" "ONE node-agent that COLLECTS all three signals: scrapes /metrics, tails pod logs, receives OTLP traces — replacing Prometheus's scraper AND Promtail."
	$(STEP) "Add the OpenTelemetry Helm repo" \
	        "helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts >/dev/null 2>&1; helm repo update open-telemetry >/dev/null"
	$(STEP) "Install the Collector (contrib image, DaemonSet node-agent) — see collector/values.yaml" \
	        "helm upgrade --install otel-collector open-telemetry/opentelemetry-collector --version $(OTEL_CHART_VER) -n $(OBS_NS) --create-namespace -f collector/values.yaml && kubectl -n $(OBS_NS) rollout status daemonset/otel-collector-agent --timeout=180s"
	@echo ""
	@echo "  ✓ Collector up (DaemonSet). It SCRAPES each bankobs /metrics, TAILS pod logs, and"
	@echo "    receives OTLP traces on otel-collector:4317 (grpc) / :4318 (http)."
	@echo "    Watch what it does:  kubectl -n $(OBS_NS) logs -f daemonset/otel-collector-agent"

# ───────────────────────────────────────────────────────────────────────────────
#  SECTION 4 — point the APP at the Collector (all three signals over OTLP)
# ───────────────────────────────────────────────────────────────────────────────
app-otel: ## 4. Point the app's TRACES at the Collector (metrics+logs are collected FOR the app)
	$(SECTION) "4" "The app's traces, via the Collector" "Only traces need the app's help — the SDK emits spans. Metrics and logs the Collector collects on its own (scrape + tail), no app change."
	$(STEP) "Turn the SDK on for traces and point OTLP at the Collector (metrics/logs exporters OFF — the Collector handles those)" \
	        "kubectl -n $(APP_NS) set env deployment -l domain OTEL_SDK_DISABLED=false OTEL_TRACES_EXPORTER=otlp OTEL_METRICS_EXPORTER=none OTEL_LOGS_EXPORTER=none OTEL_EXPORTER_OTLP_PROTOCOL=grpc OTEL_EXPORTER_OTLP_ENDPOINT=$(COLLECTOR) MANAGEMENT_TRACING_ENABLED=true MANAGEMENT_OTLP_TRACING_ENDPOINT=http://otel-collector.$(OBS_NS).svc:4318/v1/traces MANAGEMENT_TRACING_SAMPLING_PROBABILITY=1.0"
	@echo ""
	@echo "  ✓ Python traces → Collector :4317 (gRPC); Java/Spring traces → Collector :4318 (HTTP)."
	@echo "    Metrics come from the Collector SCRAPING /metrics; logs from it TAILING pod logs."
	@echo "    Generate traffic, then verify:  make traffic && make verify"

all: backends enable-remote-write collector app-otel ## 1→4 in order (the whole OTel pipeline)
	@echo ""
	@echo "═══ Done, via OpenTelemetry. ONE Collector → Prometheus + Loki + Jaeger ═══"
	@echo "    Generate load (make traffic), then make verify. Then: make observe"
	@echo "    Reminder: the bankobs pods must carry scrape annotations so the Collector can find each"
	@echo "    /metrics — deploy the app with 'make -C .. enable-annotations-to-deploy' first (docs/00)."

# ───────────────────────────────────────────────────────────────────────────────
#  SECTION 5 — GRAFANA: one pane over the three backends (REUSED from the parent lab)
#  The Collector preserves the Prometheus-client metric names + labels (app/status/handler),
#  so the parent's Golden Signals + Errors dashboards and datasource wiring work unchanged.
#  Only trace<->logs correlation differs (by service, not trace_id) — see OTEL/scripts.
# ───────────────────────────────────────────────────────────────────────────────
grafana: ## 5. Grafana (Helm) — same install as the parent lab (admin/admin login)
	$(SECTION) "5" "Grafana" "A single pane over Prometheus + Loki + Jaeger — all fed by the Collector."
	$(STEP) "Add the Grafana Helm repo" \
	        "helm repo add grafana https://grafana.github.io/helm-charts >/dev/null 2>&1; helm repo update grafana >/dev/null"
	$(STEP) "Install Grafana (parent lab's values: v13, login admin/admin)" \
	        "helm upgrade --install grafana grafana/grafana -n $(OBS_NS) --create-namespace -f $(PARENT)/grafana/values.yaml && kubectl -n $(OBS_NS) rollout status deploy/grafana --timeout=180s"
	@$(MAKE) -s _url HP=3000 NAME=Grafana

datasources: ## Register Prometheus+Loki+Jaeger + wire trace→logs BY SERVICE (OTEL-specific)
	$(STEP) "Register the three datasources + trace→logs-by-service correlation (OTEL/scripts/add-datasources.sh)" \
	        "OBS_NS=$(OBS_NS) bash scripts/add-datasources.sh"
	@echo "  ✓ datasources added. Trace→logs opens the service's logs around the span's time"
	@echo "    (logs carry correlation_id/k8s_container_name, not trace_id — see docs/04)."

golden-dashboard: ## Apply the Golden Signals + Errors dashboards (parent lab's — names match)
	$(STEP) "Import the Golden Signals + per-service Errors dashboards" \
	        "bash $(PARENT_SCRIPTS)/apply-dashboard.sh $(PARENT)/grafana/golden-signals.json $(PARENT)/grafana/errors.json"
	@echo "  ✓ open Grafana → Dashboards → 'bankobs — Golden Signals'."
	@$(MAKE) -s _url HP=3000 NAME=Grafana

observe: grafana datasources golden-dashboard ## 5 in one: Grafana + datasources + dashboards
	@echo ""
	@echo "═══ Grafana ready over the OTel-collected signals. Open the Golden Signals dashboard. ═══"

# ───────────────────────────────────────────────────────────────────────────────
#  FAULTS — inject observable incidents to practice the drill-down (REUSED faultctl)
# ───────────────────────────────────────────────────────────────────────────────
fault: ## Inject a fault:  make fault NAME=latency [TARGET=account-service]  (NAME=latency|db-down|app-down|app-crash|errors)
	$(STEP) "Inject fault scenario: $(NAME) $(TARGET)" \
	        "bash $(FAULTCTL) $(NAME) start $(TARGET)"

fault-stop: ## Revert a fault:  make fault-stop NAME=latency [TARGET=account-service]
	$(STEP) "Revert fault scenario: $(NAME) $(TARGET)" \
	        "bash $(FAULTCTL) $(NAME) stop $(TARGET)"

fault-status: ## Show which fault scenarios are currently active
	@bash $(FAULTCTL) status

fault-list: ## List the available fault scenarios
	@bash $(FAULTCTL) list

# ───────────────────────────────────────────────────────────────────────────────
#  TRAFFIC + VERIFY + URLS + CLEAN
# ───────────────────────────────────────────────────────────────────────────────
traffic: ## Generate load so there is something to see (~60s; reuses the parent loadrunner)
	$(STEP) "Drive the bankobs portal journeys for ~60s" \
	        "INTERVAL=$(LOAD_INTERVAL) FAIL_PCT=$(LOAD_FAIL) SWEEP_EVERY=$(LOAD_SWEEP) timeout 60 bash $(PARENT)/scripts/loadrunner.sh || true"

traffic-bg: ## Keep load running in the background (stop with 'make traffic-stop')
	$(STEP) "Start the loadrunner detached (writes /tmp/loadrunner.log)" \
	        "pkill -f '^bash [^ ]*loadrunner\.sh' 2>/dev/null || true; sleep 1; \
	         INTERVAL=$(LOAD_INTERVAL) FAIL_PCT=$(LOAD_FAIL) SWEEP_EVERY=$(LOAD_SWEEP) nohup bash $(PARENT)/scripts/loadrunner.sh >/tmp/loadrunner.log 2>&1 & \
	         sleep 2; echo '  loadrunner started — tail -f /tmp/loadrunner.log'"

traffic-stop: ## Stop the background loadrunner
	$(STEP) "Stop the background loadrunner" \
	        "pkill -f '^bash [^ ]*loadrunner\.sh' 2>/dev/null && echo '  stopped' || echo '  (none running)'"

verify: verify-collector verify-metric-names verify-logs verify-traces ## Check the whole OTel pipeline

verify-collector: ## Is the Collector accepting OTLP and exporting? (its self-telemetry on :8888)
	$(STEP) "Ask the Collector how many spans/metrics/logs it has accepted + exported" \
	  "kubectl -n $(OBS_NS) port-forward daemonset/otel-collector-agent 8888:8888 >/dev/null 2>&1 & PF=$$!; sleep 4; \
	   echo '  accepted/exported (non-zero = flowing):'; \
	   curl -s http://localhost:8888/metrics | grep -E 'otelcol_receiver_accepted|otelcol_exporter_sent' | grep -vE '^#' | sed 's/^/    /' | head -20; \
	   kill $$PF 2>/dev/null || true"

verify-metric-names: ## Which http.* metric NAMES landed in Prometheus (native Prometheus-client names — the Collector scrapes /metrics)
	$(STEP) "List Prometheus metric names containing 'http' or 'request' (expect http_requests_total / http_server_requests_total — NOT semconv)" \
	  "kubectl -n $(OBS_NS) port-forward svc/prometheus-server 9090:80 >/dev/null 2>&1 & PF=$$!; sleep 4; \
	   echo '  metric names seen (same Prometheus-client names as the by-hand lab, so the parent dashboards match):'; \
	   curl -s 'http://localhost:9090/api/v1/label/__name__/values' | jq -r '.data[]? | select(test(\"http|request\"))' | sed 's/^/    /' | head -40; \
	   echo '  (if empty: give it ~1 min after make traffic, and check make verify-collector)'; \
	   kill $$PF 2>/dev/null || true"

verify-logs: ## Which services are landing in Loki (pushed via the Collector)?
	$(STEP) "Ask Loki which service labels it has seen" \
	  "kubectl -n $(OBS_NS) port-forward svc/loki 3100:3100 >/dev/null 2>&1 & PF=$$!; sleep 4; \
	   echo '  log stream labels in Loki:'; \
	   curl -s 'http://localhost:3100/loki/api/v1/labels' | jq -r '.data[]? // \"  (none yet — run make traffic)\"' | sed 's/^/    /'; \
	   kill $$PF 2>/dev/null || true"

verify-traces: ## Which services have sent traces to Jaeger (via the Collector)?
	$(STEP) "Ask Jaeger which services have reported traces" \
	  "kubectl -n $(OBS_NS) port-forward svc/jaeger 16686:16686 >/dev/null 2>&1 & PF=$$!; sleep 4; \
	   echo '  services in Jaeger:'; \
	   curl -s 'http://localhost:16686/api/services' | jq -r '.data[]? // \"  (none yet — run make traffic)\"' | sed 's/^/    /'; \
	   kill $$PF 2>/dev/null || true"

urls: ## Print the UI URLs (Prometheus / Jaeger; Grafana if the parent lab installed it)
	@$(MAKE) -s _url HP=9090  NAME=Prometheus
	@$(MAKE) -s _url HP=16686 NAME=Jaeger
	@$(MAKE) -s _url HP=3000  NAME=Grafana
	@$(MAKE) -s _url HP=3100  NAME="Loki API"

_url:
	@TOKEN=$$(curl -s -m1 -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 60" 2>/dev/null); \
	 IP=$$(curl -s -m1 -H "X-aws-ec2-metadata-token: $$TOKEN" http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null); \
	 [ -z "$$IP" ] && IP=$$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="ExternalIP")].address}' 2>/dev/null); \
	 [ -z "$$IP" ] && IP=localhost; \
	 printf "  %-10s http://%s:%s\n" "$(NAME)" "$$IP" "$(HP)"

clean: ## Remove the Collector + revert the app (backends stay; use ../make clean to remove them)
	$(STEP) "Uninstall the OpenTelemetry Collector" \
	        "helm -n $(OBS_NS) uninstall otel-collector 2>/dev/null || true"
	$(STEP) "Revert the app env (SDK off, clear the OTLP exporters + endpoint)" \
	        "kubectl -n $(APP_NS) set env deployment -l domain OTEL_SDK_DISABLED=true OTEL_TRACES_EXPORTER- OTEL_METRICS_EXPORTER- OTEL_LOGS_EXPORTER- OTEL_EXPORTER_OTLP_PROTOCOL- OTEL_EXPORTER_OTLP_ENDPOINT- MANAGEMENT_TRACING_ENABLED- || true"
	@echo "  ✓ Collector gone, app back to a blank slate."
	@echo "    (Prometheus keeps the remote-write flag — harmless. To remove ALL backends: make -C $(PARENT) clean)"
