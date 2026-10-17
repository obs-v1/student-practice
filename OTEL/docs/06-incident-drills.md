# 06 — Incident drills: find the root cause from the three pillars

Two drills, each one command to inject and one to revert, each a fixed path through
**metrics → traces → logs**. They are the OTel-collected version of the on-call loop: *something
changes → the Golden Signals dashboard shows it → you follow the pillars to the cause.*

## Before you start

```bash
make -C OTEL observe       # Grafana + datasources + dashboards (if not already)
make -C OTEL traffic-bg    # steady load so there is something to perturb
```

Open Grafana (`make -C OTEL urls`, login **admin / admin**) → **bankobs — Golden Signals**,
Service = **All**, Last 15 minutes.

> **An honest note on this app.** bankobs degrades **gracefully** — a database or dependency
> *outage* is absorbed (reads fall back to the Redis cache; writes become handled 4xx), so it
> does **not** spike the **Errors** panel. We tested that thoroughly. The reliable, teachable
> signal here is **latency**, so both drills are read from the **Latency** panel. (The
> `app-down` / `db-down` faults still exist, but you won't get a clean error spike from them —
> that gracefulness is itself a lesson about resilient systems.)

Both drills are *latency* incidents, but they teach opposite root-cause shapes: in Drill 1 the
slow service **is** the culprit; in Drill 2 the slow service is an innocent **victim** of a
downstream dependency — and only the distributed **trace** tells them apart.

---

## Drill 1 — a slow service (the culprit is the service itself)

**Inject** (a 1500 ms `tc-netem` delay on account-service's own network; `LAT_MS=` to tune):

```bash
make -C OTEL fault NAME=latency
```

1. **Metrics — Golden Signals.** Set **Service = `account-service`**. Its **p95 jumps from
   ~90 ms to ~2–4 s**. The **Errors** panel stays flat; **Saturation** (CPU/mem) stays flat too
   — the tell that this is *wait*, not load.
2. **Traces — Jaeger.** Open a recent `account-service` trace: **its own span** is the long one.
   The time is spent inside account-service — the slow thing and the blamed thing are the same.
3. **Logs — Loki.** `{k8s_container_name="account-service"}` around that time: **no errors**. A
   latency incident has no error signature, and that absence *is* the diagnosis.

**Root cause:** account-service itself (its network) is slow.
**Revert:** `make -C OTEL fault-stop NAME=latency`

---

## Drill 2 — a slow downstream dependency (the slow service is a victim)

Now slow a **downstream** service that another service **calls**. `kyc-service` calls
`aadhaar-adapter` (and `pan-adapter`) to verify identity; we slow the adapter.

**Inject** (1500 ms `tc-netem` on `aadhaar-adapter`):

```bash
make -C OTEL fault NAME=latency TARGET=aadhaar-adapter
```

1. **Metrics — Golden Signals.** Set **Service = `kyc-service`** (the *caller*). Its **p95
   explodes to ~10 s** — kyc-service looks broken. Errors flat, Saturation flat.
   **Now set Service = `aadhaar-adapter`** (the service you just broke): its p95 looks
   **perfectly healthy (~90 ms)**. The dashboard is pointing you at the wrong service.
2. **Traces — Jaeger (this is the key step).** Open a slow `kyc-service` trace
   (`/api/v1/kyc/{id}/verify`, ~9 s). The waterfall shows kyc-service's time is spent
   **waiting on its call to `aadhaar-adapter`** (that span is ~4–5 s) — while
   `aadhaar-adapter`'s *own* server span is **~0 ms**. The trace fingers the dependency that
   the per-service metric hid.

   > Why the adapter's own metric looks fine: the netem delay is on the **wire**, so the adapter
   > finishes fast and the bytes arrive at the caller slowly. Server-side timing (its `/metrics`)
   > never sees the delay; the caller's trace span does. Distributed tracing is what makes the
   > real culprit visible.
3. **Logs — Loki.** `{k8s_container_name="kyc-service"}`: no errors (it's waiting, not failing).
   `{k8s_container_name="aadhaar-adapter"}`: also clean. Logs confirm "nobody is erroring" —
   consistent with a pure latency/dependency problem.

**Root cause:** the downstream `aadhaar-adapter` (the hop to it) is slow; `kyc-service` only
*looks* slow because it waits on it.
**Revert:** `make -C OTEL fault-stop NAME=latency TARGET=aadhaar-adapter`

---

## The mental model (both drills)

| Pillar | Question it answers | Drill 1 (slow service) | Drill 2 (slow dependency) |
|---|---|---|---|
| **Metrics** (Golden Latency) | *is* something wrong, **which** service looks bad? | account-service | kyc-service (the caller) |
| **Traces** (Jaeger) | **where** is the time *really* spent? | account-service's own span | the call **to** aadhaar-adapter |
| **Logs** (Loki) | **why** — any errors? | none (pure latency) | none (pure latency) |

The lesson: the Golden Signals tell you *a* service is slow, but when that service is just
**waiting on a dependency**, only the distributed **trace** shows you the real culprit — the
dependency whose own dashboard looks perfectly healthy. Check in-flight faults with
`make -C OTEL fault-status`; `make -C OTEL fault-stop NAME=… [TARGET=…]` always reverts. Keep
`make -C OTEL traffic-bg` running so the panels have live data.

➡ Next: [07-why-this-vs-byhand.md](07-why-this-vs-byhand.md)
