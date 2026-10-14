#!/usr/bin/env bash
# faultctl.sh — inject and revert OBSERVABLE fault scenarios into the bankobs lab.
#
#   faults/faultctl.sh <scenario> <start|stop> [target]
#   faults/faultctl.sh status
#   faults/faultctl.sh list
#
# Every scenario here was chosen because you can SEE it in the stack you built (Prometheus /
# Golden Signals / Jaeger / Loki). Two honest facts about this app shaped the list:
#   1. bankobs services degrade GRACEFULLY — a dependency outage yields handled 4xx, never an
#      unhandled 5xx. The only way to force "down" is to make the pod itself un-scrapable
#      (CrashLoop → up==0). So "errors" here means a real 4xx SPIKE, not synthetic 5xx.
#   2. The Python services expose http_requests_total; the Go payment tier (upi-service,
#      payment-gateway) exposes the OTel name http_server_requests_total. Both carry a
#      status="2xx|4xx|5xx" label. The observe-hints below name the right metric per scenario.
#
# Nothing here is destructive: every start has a matching stop, and stop fully reverts.
set -euo pipefail

NS="${APP_NS:-bankobs}"
OBS_NS="${OBS_NS:-monitoring}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOADRUNNER="$ROOT/scripts/loadrunner.sh"

# sensible, low-blast-radius defaults
DEF_APP="insurance-service"     # a graceful Python service, safe to crash/stop
DEF_DB="mongodb"                # a datastore, safe to bounce
DEF_LAT="kyc-service"           # has steady traffic, good for a latency story

c_red=$'\033[1;31m'; c_grn=$'\033[1;32m'; c_cyn=$'\033[1;36m'; c_dim=$'\033[2m'; c_off=$'\033[0m'
say()  { printf '%s%s%s\n' "$c_cyn" "$*" "$c_off"; }
ok()   { printf '%s✓ %s%s\n' "$c_grn" "$*" "$c_off"; }
hint() { printf '  %sobserve: %s%s\n' "$c_dim" "$*" "$c_off"; }

need_kubectl() { command -v kubectl >/dev/null || { echo "✗ kubectl not found"; exit 1; }; }

# restart the shared loadrunner with given FAIL_PCT/INTERVAL (anchored pkill = no self-kill)
restart_load() {
  local fail="$1" interval="$2"
  pkill -f '^bash [^ ]*loadrunner\.sh' 2>/dev/null || true; sleep 1
  FAIL_PCT="$fail" INTERVAL="$interval" nohup bash "$LOADRUNNER" >/tmp/loadrunner.log 2>&1 &
  sleep 2
}

usage() {
  cat <<TXT
faultctl.sh — observable fault scenarios for the bankobs lab

  faults/faultctl.sh <scenario> <start|stop> [target]
  faults/faultctl.sh status | list

scenarios:
  app-crash  [svc]   CrashLoop a service (pod up, un-scrapable)   -> up == 0        default: $DEF_APP
  app-down   [svc]   Scale a service to 0 (gone from the fleet)   -> traffic gap    default: $DEF_APP
  db-down    [db]    Scale a datastore statefulset to 0           -> db up == 0     default: $DEF_DB
  errors     [pct]   Drive a real 4xx error SPIKE (load failures) -> 4xx rate up    default: 50
  latency    [svc]   CPU-throttle a service to 0.1 cores          -> p95 / CPU up   default: $DEF_LAT

examples:
  faults/faultctl.sh app-crash start                 # crash $DEF_APP
  faults/faultctl.sh app-crash stop
  faults/faultctl.sh db-down   start postgres
  faults/faultctl.sh errors    start 70
  faults/faultctl.sh status
TXT
}

scenario="${1:-}"; action="${2:-}"; target="${3:-}"
need_kubectl

case "$scenario" in
# ───────────────────────────────────────────────────────────────── app-crash ──
app-crash)
  t="${target:-$DEF_APP}"
  case "$action" in
    start)
      say "app-crash: forcing $t into CrashLoopBackOff"
      kubectl -n "$NS" patch deploy "$t" --type=json \
        -p '[{"op":"add","path":"/spec/template/spec/containers/0/command","value":["sh","-c","echo fault-injected; exit 1"]}]' >/dev/null
      ok "$t will CrashLoop within ~30-60s (pod exists but cannot be scraped)"
      hint "Prometheus:  up{namespace=\"$NS\", app=\"$t\"}  -> 0"
      hint "kubectl -n $NS get pod -l app=$t   (CrashLoopBackOff, restarts climbing)" ;;
    stop)
      say "app-crash: reverting $t"
      kubectl -n "$NS" patch deploy "$t" --type=json \
        -p '[{"op":"remove","path":"/spec/template/spec/containers/0/command"}]' >/dev/null 2>&1 || true
      kubectl -n "$NS" rollout status deploy/"$t" --timeout=90s >/dev/null 2>&1 || true
      ok "$t restored (command override removed)" ;;
    *) usage; exit 2 ;;
  esac ;;
# ────────────────────────────────────────────────────────────────── app-down ──
app-down)
  t="${target:-$DEF_APP}"
  case "$action" in
    start)
      say "app-down: scaling $t to 0 replicas"
      kubectl -n "$NS" scale deploy/"$t" --replicas=0 >/dev/null
      ok "$t stopped"
      hint "Golden Signals Traffic: $t's line drops to 0 (its http_requests_total stops climbing)"
      hint "Prometheus: its up{} series goes stale then disappears (target removed, not 'down')" ;;
    stop)
      say "app-down: scaling $t back to 1"
      kubectl -n "$NS" scale deploy/"$t" --replicas=1 >/dev/null
      kubectl -n "$NS" rollout status deploy/"$t" --timeout=90s >/dev/null 2>&1 || true
      ok "$t restored" ;;
    *) usage; exit 2 ;;
  esac ;;
# ─────────────────────────────────────────────────────────────────── db-down ──
db-down)
  t="${target:-$DEF_DB}"
  case "$action" in
    start)
      say "db-down: scaling statefulset/$t to 0"
      kubectl -n "$NS" scale statefulset/"$t" --replicas=0 >/dev/null
      ok "$t stopped"
      hint "Prometheus: up{app=\"$t\"} / the $t pod is gone"
      hint "the app stays up but degrades to handled 4xx (it does NOT emit 5xx) — that resilience is the lesson" ;;
    stop)
      say "db-down: scaling statefulset/$t back to 1"
      kubectl -n "$NS" scale statefulset/"$t" --replicas=1 >/dev/null
      kubectl -n "$NS" rollout status statefulset/"$t" --timeout=180s >/dev/null 2>&1 || true
      ok "$t restored" ;;
    *) usage; exit 2 ;;
  esac ;;
# ──────────────────────────────────────────────────────────────────── errors ──
errors)
  pct="${target:-50}"
  case "$action" in
    start)
      [ -f "$LOADRUNNER" ] || { echo "✗ loadrunner not found at $LOADRUNNER"; exit 1; }
      say "errors: driving a 4xx spike (FAIL_PCT=$pct, denser load)"
      restart_load "$pct" "0.3"
      ok "load generator now fails ~$pct% of journeys (PID $(pgrep -f '^bash [^ ]*loadrunner\.sh' | head -1))"
      hint "Golden Signals Errors / Errors-by-service: 4xx rate climbs (Python 404s)"
      hint "payment tier (real service): sum by(app)(rate(http_server_requests_total{app=~\"upi-service|payment-gateway\",status=\"4xx\"}[5m]))" ;;
    stop)
      say "errors: restoring the load generator to defaults (FAIL_PCT=8)"
      restart_load "8" "0.5"
      ok "load generator back to baseline (PID $(pgrep -f '^bash [^ ]*loadrunner\.sh' | head -1))" ;;
    *) usage; exit 2 ;;
  esac ;;
# ─────────────────────────────────────────────────────────────────── latency ──
latency)
  t="${target:-$DEF_LAT}"
  FPOD_SEL='-l app=fault-injector'
  case "$action" in
    start)
      say "latency: arming the fault-injector and CPU-throttling $t to 0.1 cores"
      kubectl -n "$NS" scale deploy/fault-injector --replicas=1 >/dev/null 2>&1 || true
      kubectl -n "$NS" rollout status deploy/fault-injector --timeout=90s >/dev/null 2>&1 || true
      FPOD=$(kubectl -n "$NS" get pod $FPOD_SEL -o name | head -1)
      kubectl -n "$NS" exec "$FPOD" -- wget -qO- --header='Content-Type: application/json' \
        --post-data="{\"type\":\"cpu_throttle\",\"duration_seconds\":1800,\"target\":{\"service\":\"$t\"},\"params\":{\"cpu_percent\":95}}" \
        http://localhost:8091/api/v1/faults >/dev/null 2>&1 || true
      ok "$t CPU limit throttled to 0.1 cores"
      hint "Golden Signals Saturation(CPU): $t pegs near its limit under load"
      hint "Latency p95 only rises if $t is CPU-bound — drive heavy load to see it; sim services may stay ~95ms"
      hint "best latency story is on the Go payment tier (real work): try 'latency start upi-service'" ;;
    stop)
      say "latency: clearing the throttle on $t and restoring its CPU limit"
      FPOD=$(kubectl -n "$NS" get pod $FPOD_SEL -o name 2>/dev/null | head -1)
      if [ -n "$FPOD" ]; then
        for id in $(kubectl -n "$NS" exec "$FPOD" -- wget -qO- http://localhost:8091/api/v1/faults 2>/dev/null \
            | python3 -c 'import sys,json;[print(f["id"]) for f in json.load(sys.stdin)["data"]["active"]]' 2>/dev/null); do
          kubectl -n "$NS" exec "$FPOD" -- wget -qO- "http://localhost:8091/api/v1/faults/$id" >/dev/null 2>&1 || true
        done
      fi
      # the injector's DELETE is unreliable from busybox; restore the CPU limit directly
      kubectl -n "$NS" scale deploy/fault-injector --replicas=0 >/dev/null 2>&1 || true
      kubectl -n "$NS" patch deploy "$t" --type=json \
        -p '[{"op":"replace","path":"/spec/template/spec/containers/0/resources/limits/cpu","value":"500m"}]' >/dev/null 2>&1 || true
      kubectl -n "$NS" rollout status deploy/"$t" --timeout=90s >/dev/null 2>&1 || true
      ok "$t CPU limit restored (500m); injector disarmed" ;;
    *) usage; exit 2 ;;
  esac ;;
# ──────────────────────────────────────────────────────────────────── status ──
status)
  say "active faults in '$NS':"
  echo "  scaled to 0 (app-down / db-down):"
  kubectl -n "$NS" get deploy,statefulset -o json 2>/dev/null | python3 -c "
import sys,json
d=json.load(sys.stdin)
any_=False
for it in d['items']:
    name=it['metadata']['name']
    if name=='fault-injector': continue   # dormant by design, not an injected fault
    if it['spec'].get('replicas',1)==0: print('    - '+it['kind'].lower()+'/'+name); any_=True
print('    (none)') if not any_ else None
"
  echo "  CrashLooping (app-crash):"
  kubectl -n "$NS" get pods --no-headers 2>/dev/null | awk '$3=="CrashLoopBackOff"{print "    - "$1" (restarts "$4")"}' | grep -v -e 'balance-service' -e 'cheque-service' || true
  kubectl -n "$NS" get pods --no-headers 2>/dev/null | awk '$3=="CrashLoopBackOff"' | grep -qE 'balance-service|cheque-service' && echo "    (balance-service/cheque-service CrashLoop = intentional, not a fault)"
  echo "  fault-injector (latency):"
  r=$(kubectl -n "$NS" get deploy fault-injector -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 0)
  echo "    replicas=$r"
  echo "  load generator (errors):"
  if pgrep -f '^bash [^ ]*loadrunner\.sh' >/dev/null 2>&1; then
    grep -oE 'fail=[0-9]+%' /tmp/loadrunner.log 2>/dev/null | tail -1 | sed 's/^/    current /' || echo "    running (fail% unknown)"
  else echo "    not running"; fi ;;
# ────────────────────────────────────────────────────────────────────── list ──
list|--list|-l|help|-h|"") usage ;;
*) echo "✗ unknown scenario: $scenario"; echo; usage; exit 2 ;;
esac
