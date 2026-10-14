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
JAEGER_OTLP ?= http://jaeger-collector.$(OBS_NS).svc:4317

# ── PROVISION (run from your workstation) ───────────────────────────────────────
EC2_USER        ?= ec2-user
EC2_PASS        ?= DevOps321
# Lazily evaluated — terraform is only shelled out to when a target uses it.
EC2_HOST        ?= $(shell terraform output -raw public_ip 2>/dev/null)
KIND_CLUSTER    ?= lab
KUBE_CONTEXT    ?= lab-ec2
KUBE_API_PORT   ?= 6443
KUBECONFIG_OUT  ?= $(HOME)/.kube/lab-ec2.config
SSH_OPTS        := -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10
SSH_WRAP         = $(shell command -v sshpass >/dev/null 2>&1 && echo sshpass -p '$(EC2_PASS)')

export DRY                              # so scripts/*.sh can see it
SECTION := @scripts/section.sh
STEP    := @scripts/step.sh

.DEFAULT_GOAL := help
.PHONY: help tf-install tf-apply tf-destroy kubeconfig kube-check \
        cluster app darken metrics enable-annotations-to-deploy disable-annotations-to-deploy logs traces all grafana golden-dashboard correlation traffic \
        verify verify-metrics verify-logs verify-traces urls clean

help: ## Show this help
	@grep -hE '^[a-zA-Z0-9_-]+:.*?## ' $(MAKEFILE_LIST) \
	 | sed -E 's/:.*## /\t/' | awk -F '\t' '{printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "  On your WORKSTATION: make tf-apply → make kubeconfig   (provision a box + cluster)"
	@echo "  On the BOX:          make cluster → app → metrics → logs → traces   (build the lab)"
	@echo "  Tip: DRY=1 prints steps without running them (do-it-by-hand mode)."

# ═══════════════════════════════════════════════════════════════════════════════
#  PROVISION — run these from your workstation (needs terraform + AWS creds)
#  Creates an EC2 box and an EMPTY kind cluster on it (no app). See main.tf.
# ═══════════════════════════════════════════════════════════════════════════════
tf-install: ## Ensure terraform is installed (workstation)
	@command -v terraform >/dev/null 2>&1 || { \
	  echo "✗ terraform not found. Install it: https://developer.hashicorp.com/terraform/install"; exit 1; }
	@command -v aws >/dev/null 2>&1 || echo "  note: AWS CLI not found — make sure AWS creds are configured for terraform"

tf-apply: tf-install ## Create the EC2 box + empty kind cluster (run from workstation)
	terraform init
	terraform apply -auto-approve
	@echo ""
	@echo "  ✓ box up. Next: make kubeconfig   (fetch a kubeconfig that reaches the cluster)"

tf-destroy: tf-install ## Destroy the EC2 box
	terraform init
	terraform destroy -auto-approve

kubeconfig: ## Fetch a kubeconfig for the EC2 kind cluster (uses the box's public IP)
	@command -v ssh >/dev/null || { echo "✗ ssh not found"; exit 1; }
	@command -v sshpass >/dev/null 2>&1 || echo "  note: sshpass not installed — ssh will prompt for the password ($(EC2_PASS))"
	@HOST="$(EC2_HOST)"; \
	if [ -z "$$HOST" ]; then \
	  echo "  ✗ no EC2 host found. Run 'make tf-apply' first, or: make kubeconfig EC2_HOST=<ip>"; exit 1; fi; \
	mkdir -p $(dir $(KUBECONFIG_OUT)); \
	echo "→ $(EC2_USER)@$$HOST: exposing the '$(KIND_CLUSTER)' API server and fetching its kubeconfig…"; \
	$(SSH_WRAP) ssh $(SSH_OPTS) "$(EC2_USER)@$$HOST" \
	  "PUBLIC_IP='$$HOST' CLUSTER='$(KIND_CLUSTER)' LISTEN_PORT='$(KUBE_API_PORT)' CONTEXT_NAME='$(KUBE_CONTEXT)' bash -s" \
	  < cluster/scripts/expose-kube-api.sh > "$(KUBECONFIG_OUT).tmp" || true; \
	if ! grep -q 'server: https://' "$(KUBECONFIG_OUT).tmp" 2>/dev/null; then \
	  rm -f "$(KUBECONFIG_OUT).tmp"; \
	  echo "  ✗ no kubeconfig came back (see errors above). Try: ssh $(EC2_USER)@$$HOST 'kind get clusters'"; exit 1; fi; \
	mv "$(KUBECONFIG_OUT).tmp" "$(KUBECONFIG_OUT)"; chmod 600 "$(KUBECONFIG_OUT)"; \
	echo ""; echo "  ✓ wrote $(KUBECONFIG_OUT)  (context: $(KUBE_CONTEXT) → $$HOST:$(KUBE_API_PORT))"; \
	echo "      export KUBECONFIG=$(KUBECONFIG_OUT) && kubectl get nodes"

kube-check: ## Verify the fetched kubeconfig reaches the cluster
	@[ -f "$(KUBECONFIG_OUT)" ] || { echo "✗ run 'make kubeconfig' first"; exit 1; }
	@KUBECONFIG="$(KUBECONFIG_OUT)" kubectl get nodes

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
	$(STEP) "Deploy bankobs onto THIS cluster (the vendored platform in ./bankobs)" \
	        "$(MAKE) -C bankobs deploy"
	@$(MAKE) --no-print-directory darken

darken:  # internal: turn the app's telemetry off — the blank slate
	$(STEP) "Turn the app's telemetry off (one switch — you add the rest, section by section)" \
	        "kubectl -n $(APP_NS) set env deployment -l domain OTEL_SDK_DISABLED=true"
	@echo ""
	@echo "  ✓ bankobs is up and SILENT. Nothing is collecting metrics, logs or traces."
	@echo "    Next:  make metrics"

# ───────────────────────────────────────────────────────────────────────────────
#  SECTION 2 — METRICS, the pull model (Prometheus), no OTel
# ───────────────────────────────────────────────────────────────────────────────
metrics: ## 2. Prometheus (Helm) scrapes /metrics directly (no OTel)
	$(SECTION) "2" "Metrics with Prometheus (the pull model)" "Prometheus reaches into the app and scrapes /metrics on a timer. No Collector."
	$(STEP) "Add the Prometheus Helm repo" \
	        "helm repo add prometheus-community https://prometheus-community.github.io/helm-charts && helm repo update prometheus-community"
	$(STEP) "Install Prometheus (server only) — brings its own RBAC + scrape config (metrics/values.yaml)" \
	        "helm upgrade --install prometheus prometheus-community/prometheus -n $(OBS_NS) --create-namespace -f metrics/values.yaml && kubectl -n $(OBS_NS) rollout status deploy/prometheus-server --timeout=180s"
	@echo ""
	@echo "  ✓ Prometheus is up — but scraping NOTHING from bankobs yet: no service has the"
	@echo "    prometheus.io/scrape annotation. Opt one in (docs/02), or 'make enable-annotations-to-deploy'."
	@$(MAKE) -s _url HP=9090 NAME=Prometheus

enable-annotations-to-deploy: ## Opt EVERY service into scraping (uncomment the annotation in all charts)
	$(STEP) "Uncomment the prometheus.io/scrape annotation in every service's deployment.yaml" \
	        "bash scripts/scrape-annotations.sh on"
	@echo "  ✓ now apply it:  make app   (helm upgrade rolls the services with the annotation)"

disable-annotations-to-deploy: ## Reverse of enable-annotations-to-deploy: re-comment the annotation in all service charts
	$(STEP) "Re-comment the prometheus.io/scrape annotation in every service's deployment.yaml" \
	        "bash scripts/scrape-annotations.sh off"
	@echo "  ✓ now apply it:  make app"

# ───────────────────────────────────────────────────────────────────────────────
#  SECTION 3 — LOGS (Loki + Promtail), no OTel
# ───────────────────────────────────────────────────────────────────────────────
logs: ## 3. Loki + Promtail (Helm) tail container stdout (no OTel)
	$(SECTION) "3" "Logs with Loki + Promtail" "Promtail tails the node's container logs and pushes to Loki. The app writes stdout — nothing else."
	$(STEP) "Add the Grafana Helm repo" \
	        "helm repo add grafana https://grafana.github.io/helm-charts && helm repo update grafana"
	$(STEP) "Install Loki + Promtail from one chart (loki-stack) — see logs/values.yaml" \
	        "helm upgrade --install loki grafana/loki-stack -n $(OBS_NS) --create-namespace -f logs/values.yaml && kubectl -n $(OBS_NS) rollout status statefulset/loki --timeout=180s"
	@echo ""
	@echo "  ✓ Loki + Promtail up; logs are flowing (no app change was needed). Then: make verify-logs"
	@$(MAKE) -s _url HP=3100 NAME=Loki

# ───────────────────────────────────────────────────────────────────────────────
#  SECTION 4 — TRACES (Jaeger) — the pillar that still needs in-app OTel
# ───────────────────────────────────────────────────────────────────────────────
traces: ## 4. Jaeger receives traces straight from the app (no Collector)
	$(SECTION) "4" "Traces with Jaeger" "Point the app's OTLP straight at Jaeger — no Collector. But note WHY the app can speak OTLP at all (docs/04)."
	$(STEP) "Add the Jaeger Helm repo" \
	        "helm repo add jaegertracing https://jaegertracing.github.io/helm-charts && helm repo update jaegertracing"
	$(STEP) "Install Jaeger all-in-one (native OTLP, in-memory) — see traces/values.yaml" \
	        "helm upgrade --install jaeger jaegertracing/jaeger --version 3.4.1 -n $(OBS_NS) --create-namespace -f traces/values.yaml && kubectl -n $(OBS_NS) rollout status deploy/jaeger --timeout=180s"
	$(STEP) "Expose the Jaeger UI on a NodePort (the chart's UI service is headless)" \
	        "kubectl apply -f traces/jaeger-ui.yaml"
	$(STEP) "Turn the SDK back on and point it at Jaeger (metrics+logs stay off OTLP)" \
	        "kubectl -n $(APP_NS) set env deployment -l domain OTEL_SDK_DISABLED=false MANAGEMENT_TRACING_ENABLED=true OTEL_METRICS_EXPORTER=none OTEL_LOGS_EXPORTER=none OTEL_EXPORTER_OTLP_ENDPOINT=$(JAEGER_OTLP) MANAGEMENT_OTLP_TRACING_ENDPOINT=http://jaeger-collector.$(OBS_NS).svc:4318/v1/traces MANAGEMENT_TRACING_SAMPLING_PROBABILITY=1.0"
	$(STEP) "eBPF-instrument the Go payment tier (gateway/payment-gateway/upi) — they have NO in-code OTel (Beyla, traces/beyla.yaml)" \
	        "kubectl apply -f traces/beyla.yaml && kubectl -n $(OBS_NS) rollout status daemonset/beyla --timeout=120s"
	@echo ""
	@echo "  ✓ Traces flowing three ways into Jaeger: Python (in-code SDK), Java (Spring OTLP), Go (eBPF/Beyla)."
	@echo "    Beyla is a privileged DaemonSet scoped by port (8000/8010/8011) so it won't double-trace the OTel tiers."
	@echo "    Generate traffic, then: make verify-traces   (docs/04 explains the three tiers)"
	@$(MAKE) -s _url HP=16686 NAME=Jaeger

all: enable-annotations-to-deploy app metrics logs traces ## 1→4 in order (the by-hand build of the 3 pillars)
	@echo ""
	@echo "═══ Done. Services opted into scraping; metrics in Prometheus, logs in Loki, traces in Jaeger ═══"
	@echo "    Next: make grafana && make datasources && make golden-dashboard && make traffic-bg"
	@echo "    (docs/02 shows opting services in BY HAND — 'make all' does it for you so the dashboards"
	@echo "     have data; without opt-in Prometheus scrapes 0 targets and Golden Signals stays blank.)"

# ───────────────────────────────────────────────────────────────────────────────
#  SECTION 5 — GRAFANA (Helm) — then add the datasources yourself in the UI
# ───────────────────────────────────────────────────────────────────────────────
grafana: ## 5. Grafana (Helm) — plain; you add datasources by hand in the UI (docs/05)
	$(SECTION) "5" "Grafana" "A single pane over your backends. Install it, then add the datasources yourself."
	$(STEP) "Add the Grafana Helm repo" \
	        "helm repo add grafana https://grafana.github.io/helm-charts && helm repo update grafana"
	$(STEP) "Install a PLAIN Grafana (no datasources — you add them in the UI)" \
	        "helm upgrade --install grafana grafana/grafana -n $(OBS_NS) --create-namespace -f grafana/values.yaml && kubectl -n $(OBS_NS) rollout status deploy/grafana --timeout=180s"
	@echo ""
	@echo "  ✓ Grafana up (anonymous admin — no login). Add the datasources by hand in the UI"
	@echo "    (docs/05-grafana.md) — or run 'make datasources' to register all three at once."
	@$(MAKE) -s _url HP=3000 NAME=Grafana

datasources: ## Register Prometheus + Loki + Jaeger datasources in one shot (instead of the UI)
	$(STEP) "Register all three datasources via the Grafana API (prometheus=default, loki, jaeger)" \
	        "OBS_NS=$(OBS_NS) bash scripts/add-datasources.sh"
	@echo "  ✓ datasources added + trace↔logs wired (Jaeger 'Logs for this span' → Loki, and back)."
	@echo "    Try them in Explore, or run 'make golden-dashboard'."

golden-dashboard: ## Apply the Golden Signals + Errors dashboards to Grafana (needs a Prometheus datasource)
	$(STEP) "Import the Golden Signals + per-service Errors dashboards (POST /api/dashboards/db)" \
	        "bash scripts/apply-dashboard.sh grafana/golden-signals.json grafana/errors.json"
	@echo "  ✓ open Grafana → Dashboards → 'bankobs — Golden Signals'. On the Errors panel, the"
	@echo "    ▸ link opens 'bankobs — Errors by service' (which service / which endpoint)."
	@$(MAKE) -s _url HP=3000 NAME=Grafana

# ───────────────────────────────────────────────────────────────────────────────
#  CORRELATION — same Grafana, but datasources + trace<->logs PRE-provisioned (the payoff)
# ───────────────────────────────────────────────────────────────────────────────
correlation: ## Grafana (Helm) over all 3 backends — dashboards + trace<->logs
	$(SECTION) "C" "Correlation in Grafana" "One pane over Prometheus+Loki+Jaeger — click from a trace to its logs and back."
	$(STEP) "Add the Grafana Helm repo" \
	        "helm repo add grafana https://grafana.github.io/helm-charts && helm repo update grafana"
	$(STEP) "Install Grafana with datasources + trace<->logs wiring + overview dashboard" \
	        "helm upgrade --install grafana grafana/grafana -n $(OBS_NS) --create-namespace -f correlation/values-grafana.yaml && kubectl -n $(OBS_NS) rollout status deploy/grafana --timeout=180s"
	@echo ""
	@echo "  ✓ Grafana up — open it (dashboard 'bankobs — services overview'):"
	@$(MAKE) -s _url HP=3000 NAME=Grafana

# ───────────────────────────────────────────────────────────────────────────────
#  TRAFFIC + VERIFY + URLS + CLEAN
# ───────────────────────────────────────────────────────────────────────────────
# LOAD_INTERVAL = seconds between journeys (lower = denser traffic, clearer graphs).
# 0.5 -> ~2-3 req/s across the fleet; override with `make traffic LOAD_INTERVAL=2`.
LOAD_INTERVAL ?= 0.5
# LOAD_FAIL = % of journeys the generator deliberately FAILS (ghost-VPA payments -> 4xx).
# Default 0 = clean. Raise for a steady error baseline, or inject on demand: make fault NAME=errors.
LOAD_FAIL ?= 0
# LOAD_SWEEP = run the in-cluster service sweep every N cycles; 0 = OFF (the default).
# The sweep probes every service's /{id} endpoint with a PLACEHOLDER id (CASE-0001, QR-0001, ...)
# to keep all ~60 services reporting — but those ids don't exist, so it manufactures a steady
# stream of lookup-miss 404s on the stub services (no 2xx value). Off by default gives a clean
# ~96%-2xx baseline from the real portal journeys. Set LOAD_SWEEP=15 if you want every service
# to appear on the dashboard and don't mind the baseline 404s.
LOAD_SWEEP ?= 0

traffic: ## Generate load so there is something to see (~60s)
	$(STEP) "Drive the bankobs portal journeys for ~60s" \
	        "INTERVAL=$(LOAD_INTERVAL) FAIL_PCT=$(LOAD_FAIL) SWEEP_EVERY=$(LOAD_SWEEP) timeout 60 bash scripts/loadrunner.sh || true"

traffic-bg: ## Keep load running in the BACKGROUND so the dashboards never go empty
	$(STEP) "Start the loadrunner detached (writes /tmp/loadrunner.log; stop with 'make traffic-stop')" \
	        "pkill -f '^bash scripts/loadrunner.sh' 2>/dev/null || true; sleep 1; \
	         INTERVAL=$(LOAD_INTERVAL) FAIL_PCT=$(LOAD_FAIL) SWEEP_EVERY=$(LOAD_SWEEP) nohup bash scripts/loadrunner.sh >/tmp/loadrunner.log 2>&1 & \
	         sleep 2; echo '  loadrunner PID '\$$(pgrep -f '^bash scripts/loadrunner.sh' | head -1)' (INTERVAL=$(LOAD_INTERVAL)s FAIL_PCT=$(LOAD_FAIL)% sweep-every=$(LOAD_SWEEP)) — tail -f /tmp/loadrunner.log'"

traffic-stop: ## Stop the background loadrunner started by 'make traffic-bg'
	$(STEP) "Stop the background loadrunner" \
	        "pkill -f '^bash scripts/loadrunner.sh' 2>/dev/null && echo '  stopped' || echo '  (none running)'"

# ───────────────────────────────────────────────────────────────────────────────
#  FAULTS — inject OBSERVABLE incidents to practice the drill-down (see faults/README.md)
# ───────────────────────────────────────────────────────────────────────────────
fault: ## Inject a fault:  make fault NAME=app-crash [TARGET=insurance-service]   (NAME=app-crash|app-down|db-down|errors|latency)
	$(STEP) "Inject fault scenario: $(NAME) $(TARGET)" \
	        "bash faults/faultctl.sh $(NAME) start $(TARGET)"

fault-stop: ## Revert a fault:  make fault-stop NAME=app-crash [TARGET=insurance-service]
	$(STEP) "Revert fault scenario: $(NAME) $(TARGET)" \
	        "bash faults/faultctl.sh $(NAME) stop $(TARGET)"

fault-status: ## Show which fault scenarios are currently active
	@bash faults/faultctl.sh status

fault-list: ## List the available fault scenarios
	@bash faults/faultctl.sh list

verify: verify-metrics verify-logs verify-traces ## Check all three pillars

verify-metrics: ## How many app targets is Prometheus scraping?
	$(STEP) "Ask Prometheus how many bankobs targets are UP" \
	  "kubectl -n $(OBS_NS) port-forward svc/prometheus-server 9090:80 >/dev/null 2>&1 & PF=$$!; sleep 4; \
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
	@$(MAKE) -s _url HP=9090  NAME=Prometheus
	@$(MAKE) -s _url HP=16686 NAME=Jaeger
	@$(MAKE) -s _url HP=3000  NAME=Grafana
	@$(MAKE) -s _url HP=3100  NAME="Loki API"

# Print a UI URL. The services are NodePorts (30909/30686), but kind REMAPS those to
# host ports 9090/16686 (see cluster/kind-config.yaml) — so the reachable address is the
# box's PUBLIC IP on the HOST port, not the node's internal IP on the nodePort.
_url:
	@TOKEN=$$(curl -s -m1 -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 60" 2>/dev/null); \
	 IP=$$(curl -s -m1 -H "X-aws-ec2-metadata-token: $$TOKEN" http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null); \
	 [ -z "$$IP" ] && IP=$$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="ExternalIP")].address}' 2>/dev/null); \
	 [ -z "$$IP" ] && IP=localhost; \
	 printf "  %-10s http://%s:%s\n" "$(NAME)" "$$IP" "$(HP)"

clean: ## Remove the backends (leaves the app running)
	$(STEP) "Uninstall the Helm releases (Prometheus, Loki+Promtail, Jaeger, Grafana) incl. cluster RBAC" \
	        "helm -n $(OBS_NS) uninstall prometheus loki jaeger grafana 2>/dev/null || true"
	$(STEP) "Delete the monitoring namespace (Loki, Promtail, Jaeger, + anything left)" \
	        "kubectl delete namespace $(OBS_NS) --ignore-not-found"
	$(STEP) "Turn the app's telemetry back off (undo the trace wiring)" \
	        "kubectl -n $(APP_NS) set env deployment -l domain OTEL_SDK_DISABLED=true OTEL_METRICS_EXPORTER- OTEL_LOGS_EXPORTER- OTEL_EXPORTER_OTLP_ENDPOINT- MANAGEMENT_OTLP_TRACING_ENDPOINT- MANAGEMENT_TRACING_SAMPLING_PROBABILITY- || true"
	$(STEP) "Remove the Beyla eBPF cluster RBAC (its DaemonSet went with the monitoring namespace)" \
	        "kubectl delete clusterrole beyla clusterrolebinding beyla --ignore-not-found 2>/dev/null || true"
	@echo "  ✓ backends gone, app back to blank slate. (To delete the app: make -C bankobs down)"
