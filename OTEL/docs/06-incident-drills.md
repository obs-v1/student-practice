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

Now slow a **downstream** service that another service **calls**. `loan-origination` orchestrates
a loan application by fanning out to `eligibility-engine`, `kyc-service` and `account-service`;
we slow one of those dependencies, `eligibility-engine`.

**Inject** (1500 ms `tc-netem` on `eligibility-engine`):

```bash
make -C OTEL fault NAME=latency TARGET=eligibility-engine
```

1. **Metrics — Golden Signals.** Set **Service = `loan-origination`** (the *caller*). Watch the
   **p99** line on the Latency panel — it **spikes to ~3–5 s**. (p50/p95 may stay low: only the
   `/api/loans/apply` calls that reach the slowed dependency are slow, so the pain lives in the
   **tail** — a real tail-latency incident. The panel plots p50/p95/**p99**, so the p99 line is
   your signal.) **Now set Service = `eligibility-engine`** (the service you just broke): its
   latency looks **perfectly healthy (~95 ms)**. The dashboard is pointing you at the wrong
   service, and even then only in the tail.
2. **Traces — Jaeger (this is the key step).** Open a slow `loan-origination` trace
   (`/api/loans/apply`, ~3 s). The waterfall shows loan-origination's time is spent
   **waiting on its call to `eligibility-engine`** (that span is the long one) — while
   `eligibility-engine`'s *own* server span is **~0 ms**. The trace fingers the dependency that
   the per-service metric hid.

   > Why the dependency's own metric looks fine: the netem delay is on the **wire**, so
   > eligibility-engine finishes fast and the bytes arrive at the caller slowly. Server-side
   > timing (its `/metrics`) never sees the delay; the caller's trace span does. Distributed
   > tracing is what makes the real culprit visible.
3. **Logs — Loki.** `{k8s_container_name="loan-origination"}`: no errors (it's waiting, not
   failing). `{k8s_container_name="eligibility-engine"}`: also clean. Logs confirm "nobody is
   erroring" — consistent with a pure latency/dependency problem.

**Root cause:** the downstream `eligibility-engine` (the hop to it) is slow; `loan-origination`
only *looks* slow because it waits on it.
**Revert:** `make -C OTEL fault-stop NAME=latency TARGET=eligibility-engine`

---

## The mental model (both drills)

| Pillar | Question it answers | Drill 1 (slow service) | Drill 2 (slow dependency) |
|---|---|---|---|
| **Metrics** (Golden Latency) | *is* something wrong, **which** service looks bad? | account-service (p95) | loan-origination caller (p99 tail) |
| **Traces** (Jaeger) | **where** is the time *really* spent? | account-service's own span | the call **to** eligibility-engine |
| **Logs** (Loki) | **why** — any errors? | none (pure latency) | none (pure latency) |

The lesson: the Golden Signals tell you *a* service is slow, but when that service is just
**waiting on a dependency**, only the distributed **trace** shows you the real culprit — the
dependency whose own dashboard looks perfectly healthy. Check in-flight faults with
`make -C OTEL fault-status`; `make -C OTEL fault-stop NAME=… [TARGET=…]` always reverts. Keep
`make -C OTEL traffic-bg` running so the panels have live data.

➡ Next: [07-why-this-vs-byhand.md](07-why-this-vs-byhand.md)
