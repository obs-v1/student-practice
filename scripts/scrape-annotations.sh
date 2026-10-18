#!/usr/bin/env bash
# Turn the bankobs app's observability surfaces ON (or OFF) before deploy, in one shot:
#   1) METRICS — un/comment the prometheus.io/scrape annotation block in every per-service
#      deployment.yaml (so the Collector/Prometheus can discover each /metrics).
#   2) GO-TIER TRACES — flip OBSERVABILITY_MODE in the bankobs-env ConfigMap (dark<->full).
#      The Go payment tier (gateway/payment/upi + rail services) is OTel-instrumented in code
#      but exports nothing in "dark" mode; it is the ONLY tier that reads OBSERVABILITY_MODE
#      (Python/Java use OTEL_SDK_DISABLED). bankobs' `_wire-apps` injects this ConfigMap into
#      every service, so flipping it here is what actually reaches the Go pods at deploy.
# Idempotent either way. Apply the result with `make app`.
#
#   scripts/scrape-annotations.sh on     # scrape annotations uncommented + Go tracing full
#   scripts/scrape-annotations.sh off    # scrape annotations re-commented  + Go tracing dark
set -euo pipefail

MODE="${1:-on}"
CHARTS="${CHARTS_DIR:-bankobs/helm/bankobserve360/charts}"
ENVCM="${ENVCM:-bankobs/manifests/platform/00-env-configmap.yaml}"

files=$(find "$CHARTS" -name deployment.yaml)
[ -n "$files" ] || { echo "no deployment.yaml found under $CHARTS"; exit 1; }

n=0
for f in $files; do
  case "$MODE" in
    on)
      # uncomment:  "      # annotations:"            -> "      annotations:"
      #             "      #   prometheus.io/X: ..."  -> "        prometheus.io/X: ..."
      perl -pi -e 's/^(\s*)# (annotations:|  prometheus\.io\/(?:scrape|path|port):.*)$/$1$2/' "$f"
      ;;
    off)
      # re-comment (the exact inverse; no-op if already commented)
      perl -pi -e 's/^(      )annotations:$/$1# annotations:/; s/^        (prometheus\.io\/(?:scrape|path|port):.*)$/      #   $1/' "$f"
      ;;
    *) echo "usage: $0 [on|off]"; exit 2 ;;
  esac
  n=$((n+1))
done

# Go-tier traces: flip OBSERVABILITY_MODE in the bankobs-env ConfigMap (on -> full, off -> dark).
if [ -f "$ENVCM" ]; then
  case "$MODE" in
    on)  perl -pi -e 's/^(\s*OBSERVABILITY_MODE:\s*)dark\b/${1}full/' "$ENVCM" ;;
    off) perl -pi -e 's/^(\s*OBSERVABILITY_MODE:\s*)full\b/${1}dark/' "$ENVCM" ;;
  esac
  OBS=$([ "$MODE" = on ] && echo full || echo dark)
  echo "OBSERVABILITY_MODE -> '$OBS' in $(basename "$ENVCM")  (Go-tier tracing)"
else
  echo "⚠ $ENVCM not found — Go-tier OBSERVABILITY_MODE not changed"
fi

echo "scrape annotations '$MODE' in $n service charts (+ Go-tier tracing) — apply with:  make app"
