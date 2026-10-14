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
PARENT       ?= ..                         # the by-hand lab (reused backends live there)

export DRY                                 # so scripts/*.sh can see it
SECTION := @scripts/section.sh
STEP    := @scripts/step.sh

# traffic: reuse the parent lab's load generator. Lower = denser (clearer graphs).
LOAD_INTERVAL ?= 0.5

.DEFAULT_GOAL := help
.PHONY: help backends enable-remote-write collector app-otel all \
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
	$(STEP) "Loki + Promtail (Helm) — the parent lab's exact values" \
	        "helm repo add grafana https://grafana.github.io/helm-charts >/dev/null 2>&1; helm repo update grafana >/dev/null; helm upgrade --install loki grafana/loki-stack -n $(OBS_NS) --create-namespace -f $(PARENT)/logs/values.yaml && kubectl -n $(OBS_NS) rollout status statefulset/loki --timeout=180s"
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
collector: ## 3. Deploy the OpenTelemetry Collector (OTLP in → Prometheus + Loki + Jaeger out)
	$(SECTION) "3" "The OpenTelemetry Collector" "One receiver (OTLP), three exporters. The single pipeline that replaces the lab's three wirings."
	$(STEP) "Add the OpenTelemetry Helm repo" \
	        "helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts >/dev/null 2>&1; helm repo update open-telemetry >/dev/null"
	$(STEP) "Install the Collector (contrib image, deployment mode) — see collector/values.yaml" \
	        "helm upgrade --install otel-collector open-telemetry/opentelemetry-collector -n $(OBS_NS) --create-namespace -f collector/values.yaml && kubectl -n $(OBS_NS) rollout status deploy/otel-collector --timeout=180s"
	@echo ""
	@echo "  ✓ Collector up, listening for OTLP on otel-collector:4317 (grpc) / :4318 (http)."
	@echo "    Watch what it does:  kubectl -n $(OBS_NS) logs -f deploy/otel-collector"

# ───────────────────────────────────────────────────────────────────────────────
#  SECTION 4 — point the APP at the Collector (all three signals over OTLP)
# ───────────────────────────────────────────────────────────────────────────────
app-otel: ## 4. Turn the SDK on and send traces+metrics+logs to the Collector
	$(SECTION) "4" "The app, via OpenTelemetry" "One endpoint for everything. Compare: the by-hand lab needed scrape annotations, a log tailer AND a trace endpoint."
	$(STEP) "Enable the OTel SDK and export ALL THREE signals to the Collector" \
	        "kubectl -n $(APP_NS) set env deployment -l domain OTEL_SDK_DISABLED=false MANAGEMENT_TRACING_ENABLED=true OTEL_TRACES_EXPORTER=otlp OTEL_METRICS_EXPORTER=otlp OTEL_LOGS_EXPORTER=otlp OTEL_EXPORTER_OTLP_PROTOCOL=grpc OTEL_EXPORTER_OTLP_ENDPOINT=$(COLLECTOR)"
	@echo ""
	@echo "  ✓ The app now speaks only OTLP, only to the Collector. Generate traffic, then verify:"
	@echo "    make traffic  &&  make verify"
	@echo "    ⚠ metric NAMES change with OTel (semconv, not the Python client) — see docs/03 + make verify-metric-names."

all: backends enable-remote-write collector app-otel ## 1→4 in order (the whole OTel pipeline)
	@echo ""
	@echo "═══ Done, via OpenTelemetry. One SDK → one Collector → Prometheus + Loki + Jaeger ═══"
	@echo "    Generate load (make traffic), then make verify. Then read docs/06 for the contrast."

# ───────────────────────────────────────────────────────────────────────────────
#  TRAFFIC + VERIFY + URLS + CLEAN
# ───────────────────────────────────────────────────────────────────────────────
traffic: ## Generate load so there is something to see (~60s; reuses the parent loadrunner)
	$(STEP) "Drive the bankobs portal journeys for ~60s" \
	        "INTERVAL=$(LOAD_INTERVAL) timeout 60 bash $(PARENT)/scripts/loadrunner.sh || true"

traffic-bg: ## Keep load running in the background (stop with 'make traffic-stop')
	$(STEP) "Start the loadrunner detached (writes /tmp/loadrunner.log)" \
	        "pkill -f '^bash [^ ]*loadrunner\.sh' 2>/dev/null || true; sleep 1; \
	         INTERVAL=$(LOAD_INTERVAL) nohup bash $(PARENT)/scripts/loadrunner.sh >/tmp/loadrunner.log 2>&1 & \
	         sleep 2; echo '  loadrunner started — tail -f /tmp/loadrunner.log'"

traffic-stop: ## Stop the background loadrunner
	$(STEP) "Stop the background loadrunner" \
	        "pkill -f '^bash [^ ]*loadrunner\.sh' 2>/dev/null && echo '  stopped' || echo '  (none running)'"

verify: verify-collector verify-metric-names verify-logs verify-traces ## Check the whole OTel pipeline

verify-collector: ## Is the Collector accepting OTLP and exporting? (its self-telemetry on :8888)
	$(STEP) "Ask the Collector how many spans/metrics/logs it has accepted + exported" \
	  "kubectl -n $(OBS_NS) port-forward deploy/otel-collector 8888:8888 >/dev/null 2>&1 & PF=$$!; sleep 4; \
	   echo '  accepted/exported (non-zero = flowing):'; \
	   curl -s http://localhost:8888/metrics | grep -E 'otelcol_receiver_accepted|otelcol_exporter_sent' | grep -vE '^#' | sed 's/^/    /' | head -20; \
	   kill $$PF 2>/dev/null || true"

verify-metric-names: ## Which http.* metric NAMES actually landed in Prometheus (OTel semconv, not Python)
	$(STEP) "List Prometheus metric names containing 'http' or 'request' (expect OTel semconv names)" \
	  "kubectl -n $(OBS_NS) port-forward svc/prometheus-server 9090:80 >/dev/null 2>&1 & PF=$$!; sleep 4; \
	   echo '  metric names seen (the OTel names your queries/dashboards must use):'; \
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
