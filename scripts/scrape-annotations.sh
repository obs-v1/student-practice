#!/usr/bin/env bash
# Opt EVERY bankobs service into (or out of) Prometheus scraping in one shot, by
# un/commenting the prometheus.io/scrape annotation block in every per-service
# deployment.yaml. Idempotent either way. Apply the result with `make app`.
#
#   scripts/scrape-annotations.sh on     # uncomment  -> all services scraped
#   scripts/scrape-annotations.sh off    # re-comment -> back to opt-in-yourself
set -euo pipefail

MODE="${1:-on}"
CHARTS="${CHARTS_DIR:-bankobs/helm/bankobserve360/charts}"

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
echo "scrape annotations turned '$MODE' in $n service charts — apply with:  make app"
