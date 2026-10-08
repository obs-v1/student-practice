# ──────────────────────────────────────────────────────────────────────────────
#  cluster — make Kubernetes available on an EC2 host, nothing more.
#
#  Kubernetes ONLY: no application, platform or observability deploy here. The result is a
#  bare, empty kind cluster that the rest of this lab deploys onto.
#
#  On a fresh VM:
#      bash scripts/install-tools.sh   # docker, kind, kubectl, helm, jq (needs sudo)
#      # log out / back in (or `newgrp docker`) so docker works without sudo
#      make up                         # prep the host + create the cluster
#      make expose                     # (optional) a kubeconfig reachable from your laptop
#
#  `make help` lists everything.
# ──────────────────────────────────────────────────────────────────────────────

SHELL          := /bin/bash
.DEFAULT_GOAL  := help

CLUSTER        ?= lab

.PHONY: help up tools prep cluster-up expose status down

help: ## Show this help
	@grep -hE '^[a-zA-Z0-9_-]+:.*?## ' $(MAKEFILE_LIST) \
	 | sed -E 's/:.*## /\t/' | awk -F '\t' '{printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

up: prep cluster-up ## ONE SHOT: prep the host, then create the cluster
	@echo ""
	@echo "✓ Kubernetes is up. Cluster: kind-$(CLUSTER)"
	@echo "  kubectl get nodes   ·   make expose (remote kubeconfig)   ·   make down (tear down)"

tools: ## Install docker, kind, kubectl, helm, jq, socat (needs sudo; run once)
	@bash scripts/install-tools.sh

prep: ## Host prep: prereq checks + kind-friendly sysctls (needs sudo)
	@command -v docker  >/dev/null || { echo "✗ docker missing  — run: make tools"; exit 1; }
	@command -v kind    >/dev/null || { echo "✗ kind missing    — run: make tools"; exit 1; }
	@command -v kubectl >/dev/null || { echo "✗ kubectl missing — run: make tools"; exit 1; }
	@docker info >/dev/null 2>&1 || { echo "✗ docker not usable by this user (newgrp docker / re-login)"; exit 1; }
	@CUR=$$(sysctl -n fs.inotify.max_user_watches 2>/dev/null || echo 0); \
	  if [ "$$CUR" -lt 1048576 ]; then \
	    echo "→ raising inotify limits (kind needs them for many pods)"; \
	    sudo sysctl -w fs.inotify.max_user_watches=1048576 fs.inotify.max_user_instances=8192; \
	    printf "fs.inotify.max_user_watches=1048576\nfs.inotify.max_user_instances=8192\n" | \
	      sudo tee /etc/sysctl.d/99-kube-inotify.conf >/dev/null; \
	  else echo "✓ inotify limits ok"; fi
	@CUR=$$(sysctl -n vm.max_map_count 2>/dev/null || echo 0); \
	  if [ "$$CUR" -lt 262144 ]; then \
	    echo "→ raising vm.max_map_count to 262144 (handy if you later run Elasticsearch)"; \
	    sudo sysctl -w vm.max_map_count=262144; \
	    echo "vm.max_map_count=262144" | sudo tee /etc/sysctl.d/99-kube.conf >/dev/null; \
	  else echo "✓ vm.max_map_count=$$CUR"; fi
	@echo "✓ host ready. Next: make cluster-up"

cluster-up: ## Create the kind cluster (idempotent)
	@kind get clusters 2>/dev/null | grep -qx $(CLUSTER) && \
	  echo "✓ kind cluster '$(CLUSTER)' already exists" || \
	  kind create cluster --config kind-config.yaml
	@kubectl cluster-info --context kind-$(CLUSTER) | head -2
	@kubectl get nodes

expose: ## Publish the API server on the public IP + print a kubeconfig (to stdout)
	@CLUSTER=$(CLUSTER) bash scripts/expose-kube-api.sh

status: ## Cluster + node + all-namespace pod summary
	@kubectl get nodes -o wide
	@echo ""
	@kubectl get pods -A

down: ## Delete the kind cluster (everything on it is gone; images stay in docker)
	@kind delete cluster --name $(CLUSTER)
