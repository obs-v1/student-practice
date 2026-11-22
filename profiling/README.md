# 4.2.6 — zero-instrumentation profiling (Pyroscope + eBPF)

A 15-minute, **Linux-only** demo: profile an application running **inside Kubernetes** without
touching it — no SDK, no sidecar, no restart. The CPU flame graph comes straight from the kernel.

## Why the agent runs on the host (not a DaemonSet)

On a real multi-node cluster the eBPF agent is a privileged **DaemonSet**, one per node. This lab
cluster is **kind**, where the "node" is itself a Docker container. The eBPF profiler engine — the
OpenTelemetry/Elastic profiler that **both** Parca's agent and Grafana Alloy's `pyroscope.ebpf`
build on — cannot load one layer down inside that nested container (it fails its *system analysis*
step). So here the agent runs on the **host** (the box kind runs on), where the real kernel is. With
`--pid=host` it still profiles every process on the node — **including the app's Pod**, because in
kind the cluster's containers *are* host processes.

> Verified: the same Alloy profiler fails inside the kind node but prints `eBPF tracer loaded` on the
> host. Same eBPF, same result — only the placement differs. The **application** stays in Kubernetes;
> only the sensor sits on the node (which, on a real cluster, is exactly where the DaemonSet runs).

## 1. The app to profile (in Kubernetes)

```bash
kubectl apply -f profiling/sample-app.yaml     # Deployment 'payment-processor' — a tiny Go app, no SDK
```

A one-Pod `payment-processor` (small **Go** service) that burns CPU "signing" fake payments.
**Nothing is added to it** — no profiling library, no sidecar. It compiles from source at startup, so
there's no image to build or push. **Go** is deliberate: it compiles to a native binary with symbols,
so the eBPF profiler shows the app's **own functions** (`main.processPayment`, `main.signTransaction`)
as the big blocks — the thing a beginner should see first.

## 2. Pyroscope server (in the cluster)

```bash
kubectl apply -f profiling/pyroscope-server.yaml     # grafana/pyroscope:2.4.4, NodePort 30040
```

The Service is a **NodePort (30040)**, and `cluster/kind-config.yaml` already publishes it on the
host as **`:4040`** — so the UI is at **`http://<box-ip>:4040`** and the host agent reaches it at
`http://localhost:4040`. No port-forward, no tunnel.

## 3. The eBPF agent (on the host)

```bash
docker run -d --name alloy-ebpf --privileged --pid=host --network=host \
  -v /boot:/boot:ro -v /sys/kernel/debug:/sys/kernel/debug -v /sys/fs/bpf:/sys/fs/bpf \
  -v "$PWD/profiling/config.alloy:/etc/alloy/config.alloy:ro" \
  grafana/alloy:v1.22.0 run /etc/alloy/config.alloy --storage.path=/tmp/alloy

docker logs alloy-ebpf | grep 'eBPF tracer loaded'   # the agent attached to the kernel
```

`config.alloy` discovers every process, names it by its executable, profiles it with eBPF, and ships
to `http://localhost:4040` — no edits needed.

## 4. Read the app

Open **`http://<box-ip>:4040`**, pick the `process_cpu` profile type, and choose the
`payment-processor` process — **`/payment-processor`** (eBPF names processes by their executable).
Within ~30 s its flame graph reads cleanly, top to bottom:

```
main.main → main.processPayment → main.signTransaction → crypto/sha256.* → runtime
```

`main.processPayment` and `main.signTransaction` are the **app's own functions** — the wide blocks —
and you can follow them down into the SHA-256 work, **with nothing added to the app.** The same
dropdown also lists every other process on the node (`kube-apiserver`, `etcd`, `kubelet`, …).

> `:4040` must be open on the box's security group to reach the UI from a browser; otherwise use an
> SSH tunnel: `ssh -L 4040:localhost:4040 ec2-user@<box-ip>` then open `http://localhost:4040`.

## Optional second lesson — the interpreted-language limit

```bash
kubectl apply -f profiling/sample-app-python.yaml    # 'payment-processor-py' — same app, in Python
```

Profile the `/usr/local/bin/python3.12` process and compare. eBPF nails the **native** work (you'll
see `SHA256_Final`, `EVP_DigestFinal`, OpenSSL internals) but can **only approximate** the Python call
chain — `process_payment` / `sign_transaction` stay faint while the C frames dominate. The lesson:
**eBPF gives you the native/kernel truth for free; an interpreted language's own call chain needs an
in-app SDK profiler** (which means instrumenting the app). Compiled languages (the Go app above)
symbolize natively, so their functions show up as first-class frames.

## Cleanup

```bash
docker rm -f alloy-ebpf
kubectl delete namespace profiling
```

## Versions (tested)

- `grafana/pyroscope:2.4.4`
- `grafana/alloy:v1.22.0`
- sample app: `golang:1.23-alpine` (compiled at startup) · second lesson: `python:3.12-slim`
