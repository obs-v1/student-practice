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

# ── PROVISION (run from your workstation; mirrors student-bootcamp) ──────────────
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
        cluster app darken metrics logs traces all traffic \
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
	@$(MAKE) -s _url HP=9090 NAME=Prometheus

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
	@$(MAKE) -s _url HP=9090  NAME=Prometheus
	@$(MAKE) -s _url HP=16686 NAME=Jaeger
	@echo "  Loki      (no UI): kubectl -n $(OBS_NS) port-forward svc/loki 3100:3100  ->  http://localhost:3100"

# Print a UI URL. The services are NodePorts (30909/30686), but kind REMAPS those to
# host ports 9090/16686 (see cluster/kind-config.yaml) — so the reachable address is the
# box's PUBLIC IP on the HOST port, not the node's internal IP on the nodePort.
_url:
	@TOKEN=$$(curl -s -m1 -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 60" 2>/dev/null); \
	 IP=$$(curl -s -m1 -H "X-aws-ec2-metadata-token: $$TOKEN" http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null); \
	 [ -z "$$IP" ] && IP=$$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="ExternalIP")].address}' 2>/dev/null); \
	 [ -z "$$IP" ] && IP=localhost; \
	 printf "  %-10s http://%s:%s\n" "$(NAME)" "$$IP" "$(HP)"

clean: ## Remove the hand-built backends (leaves the app running)
	$(STEP) "Delete the monitoring namespace (Prometheus, Loki, Promtail, Jaeger)" \
	        "kubectl delete namespace $(OBS_NS) --ignore-not-found"
	$(STEP) "Return the app to dark (undo the trace wiring)" \
	        "kubectl -n $(APP_NS) set env deployment -l domain OTEL_SDK_DISABLED=true OBSERVABILITY_MODE=dark MANAGEMENT_TRACING_ENABLED=false OTEL_TRACES_EXPORTER- OTEL_METRICS_EXPORTER- OTEL_LOGS_EXPORTER- OTEL_EXPORTER_OTLP_ENDPOINT- OTEL_EXPORTER_OTLP_PROTOCOL- || true"
	@echo "  ✓ backends gone, app back to blank slate. (To delete the app: make -C $(BOOTCAMP)/ec2-k8s down)"
