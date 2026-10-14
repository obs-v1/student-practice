# Fault scenarios — practice the drill-down on real, observable incidents

A small toolkit to inject failures you can actually **see** in the stack you built
(Prometheus / Golden Signals / Jaeger / Loki), then walk metrics → traces → logs. Every
scenario reverts cleanly.

```bash
make fault-list                                  # the menu
make fault      NAME=app-crash                   # inject (default target)
make fault      NAME=db-down  TARGET=postgres    # inject on a chosen target
make fault-stop NAME=app-crash                   # revert
make fault-status                                # what's currently broken

# or call the script directly:
faults/faultctl.sh app-crash start insurance-service
faults/faultctl.sh app-crash stop  insurance-service
```

## The scenarios

| Scenario | What it does | Default target | What you observe |
|---|---|---|---|
| **app-crash** | CrashLoops a service (pod exists, can't be scraped) | `insurance-service` | `up{app=…} == 0`; pod `CrashLoopBackOff` |
| **app-down** | Scales a service to 0 | `insurance-service` | its traffic drops to 0 (gap in the Traffic panel); target removed |
| **db-down** | Scales a datastore statefulset to 0 | `mongodb` | the DB pod/`up` is gone; the app degrades to handled **4xx** |
| **errors** | Drives a real **4xx spike** (load generator fails more journeys) | `50` (percent) | 4xx rate climbs in Golden Signals / Errors-by-service |
| **latency** | CPU-throttles a service to 0.1 cores | `kyc-service` | Saturation(CPU) pegs; p95 rises **if** the service is CPU-bound |

`make fault NAME=errors TARGET=70` sets the failure percentage; for the others `TARGET` is the
service/datastore name.

## Two honest facts about this app (they shape the scenarios)

1. **bankobs degrades gracefully — it does not emit unhandled 5xx.** Take out a dependency
   (a peer service *or* a database) and the callers return a *handled* 4xx, not a 500. We proved
   this live: scaling down the KYC adapters, MongoDB, Redis, and even `account-service` produced
   **zero** 5xx. So the "errors" scenario is a genuine **4xx spike**, and the only way to force a
   hard "down" is `app-crash` (CrashLoop → `up == 0`). That resilience is itself a teaching point.

2. **Two metric names, by tier.** The Python services expose `http_requests_total`; the Go
   **payment tier** (`upi-service`, `payment-gateway`) exposes the OpenTelemetry name
   `http_server_requests_total`. **Both** carry `status="2xx|4xx|5xx"`. The Golden Signals
   dashboard queries the Python name, so payment-tier errors need the OTel name:
   ```promql
   sum by (app) (rate(http_server_requests_total{namespace="bankobs",
                 app=~"upi-service|payment-gateway", status="4xx"}[5m]))
   ```
   (Tip: the payment tier already runs a steady ~0.8/s of 4xx from the load generator's
   ghost-VPA payments — a real error stream to practice on.)

## A worked drill-down (app-crash)

```bash
make fault NAME=app-crash TARGET=insurance-service
```
1. **Metrics** — in Grafana, query `up{namespace="bankobs"}` (or add an availability panel):
   `insurance-service` is now **0**. In `kubectl` it's `CrashLoopBackOff`.
2. **Traces** — the service stops producing spans; callers that depend on it show the gap in
   Jaeger. (A crash is an *availability* incident — the trace story is "it went silent", not a
   red span.)
3. **Logs** — `{app="insurance-service"}` in Loki shows the crash output, then nothing.
4. **Revert** — `make fault-stop NAME=app-crash TARGET=insurance-service`; `up` returns to 1.

## Safety

- Nothing is destructive. `start` and `stop` are symmetric; `stop` fully reverts (removes the
  command override / scales back / restores the CPU limit / resets the load generator).
- `app-crash`/`app-down` default to `insurance-service` (a graceful, non-critical service).
- `balance-service` and `cheque-service` CrashLoop **by design** — `fault-status` ignores them.
- `make fault-status` lists everything currently injected so you never leave a fault running.
