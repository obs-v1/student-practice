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
DEF_LAT="account-service"       # core service on the payment path; its p95 visibly climbs under delay

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
  app-down   [svc]   Scale a service to 0.  TARGET=upi-service -> real 5xx (ERR_UPSTREAM) on
                     payment-gateway/gateway-service.               default: $DEF_APP
  latency    [svc]   Inject network delay (default 1500ms) on a service. If [svc] is a LEAF the
                     service's own p95 climbs; if [svc] is a DOWNSTREAM dependency, its CALLERS'
                     p95 climbs and the trace shows the slow hop.  LAT_MS=2000 to tune.  default: $DEF_LAT
  app-crash  [svc]   CrashLoop a service (pod up, un-scrapable)   -> up == 0        default: $DEF_APP
  db-down    [db]    Scale a datastore statefulset to 0           -> db up == 0     default: $DEF_DB
  errors     [pct]   Drive a real 4xx error SPIKE (load failures) -> 4xx rate up    default: 50

the two demo scenarios (observable via the Golden Signals LATENCY panel):
  faults/faultctl.sh latency start                     # slow SERVICE   -> account-service's own span is slow
  faults/faultctl.sh latency start eligibility-engine  # slow DOWNSTREAM-> loan-origination (caller) p95 ~3s; trace blames eligibility-engine
  faults/faultctl.sh latency stop
  faults/faultctl.sh latency stop eligibility-engine
  faults/faultctl.sh status
  (app-down/db-down also exist, but bankobs degrades gracefully — no clean error spike; see docs.)
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
  ms="${LAT_MS:-1500}"
  case "$action" in
    start)
      say "latency: adding a ${ms}ms tc-netem delay to $t's network (eBPF-free, via kubectl debug)"
      pod=$(kubectl -n "$NS" get pod -l app="$t" --field-selector=status.phase=Running -o name 2>/dev/null | head -1 | sed 's#pod/##')
      [ -n "$pod" ] || { echo "✗ no running pod for $t"; exit 1; }
      kubectl -n "$NS" debug "$pod" --image=nicolaka/netshoot:latest --profile=netadmin -q -- \
        tc qdisc add dev eth0 root netem delay "${ms}ms" >/dev/null 2>&1
      ok "$t's network is now delayed ~${ms}ms (every in/out call waits)"
      hint "If $t is a LEAF (e.g. account-service): Golden Latency Service=$t -> its p95 climbs to ~${ms}ms+"
      hint "If $t is a DOWNSTREAM dep (e.g. eligibility-engine): its CALLER's p99 climbs (loan-origination -> ~3-5s;"
      hint "   p95 may stay low — only the calls reaching $t are slow, so it's a TAIL latency), while $t's OWN p95"
      hint "   stays flat (client-side wire delay). The Jaeger trace shows the caller WAITING on the call to $t."
      hint "Saturation stays flat -> it's WAIT, not CPU/mem.   tune: LAT_MS=3000 make fault NAME=latency TARGET=$t" ;;
    stop)
      say "latency: clearing the netem delay on $t (recreating its pod)"
      # netem lives on the pod's eth0 qdisc; deleting the pod gives a clean interface back
      kubectl -n "$NS" delete pod -l app="$t" --wait=false >/dev/null 2>&1 || true
      kubectl -n "$NS" rollout status deploy/"$t" --timeout=120s >/dev/null 2>&1 || true
      ok "$t pod recreated — netem gone" ;;
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
