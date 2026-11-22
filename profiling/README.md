# 4.2.6 — zero-instrumentation profiling (Pyroscope + eBPF)

A 15-minute, **Linux-only** demo: CPU flame graphs for *every* process on the node, with nothing
added to any application — no SDK, no restart.

## Why the agent runs on the host (not a DaemonSet)

On a real multi-node cluster the eBPF agent is a privileged **DaemonSet**, one per node. This lab
cluster is **kind**, where the "node" is itself a Docker container. The eBPF profiler engine — the
OpenTelemetry/Elastic profiler that **both** Parca's agent and Grafana Alloy's `pyroscope.ebpf`
build on — cannot load one layer down inside that nested container (it fails its *system analysis*
step). So here the agent runs on the **host** (the box kind runs on), where the real kernel is. With
`--pid=host` it still profiles every process on the node, because in kind the cluster's containers
*are* host processes.

> Verified: the same Alloy profiler fails inside the kind node but prints `eBPF tracer loaded` on the
> host. Same eBPF, same result — only the placement differs.

## 1. Pyroscope server (in the cluster)

```bash
kubectl apply -f profiling/pyroscope-server.yaml     # grafana/pyroscope:2.4.4, NodePort 30040
```

The Service is a **NodePort (30040)**, and `cluster/kind-config.yaml` already publishes it on the
host as **`:4040`** — so the UI is at **`http://<box-ip>:4040`** and the host agent reaches it at
`http://localhost:4040`. No port-forward, no tunnel.

## 2. The eBPF agent (on the host)

```bash
docker run -d --name alloy-ebpf --privileged --pid=host --network=host \
  -v /boot:/boot:ro -v /sys/kernel/debug:/sys/kernel/debug -v /sys/fs/bpf:/sys/fs/bpf \
  -v "$PWD/profiling/config.alloy:/etc/alloy/config.alloy:ro" \
  grafana/alloy:v1.22.0 run /etc/alloy/config.alloy --storage.path=/tmp/alloy

docker logs alloy-ebpf | grep 'eBPF tracer loaded'   # the agent attached to the kernel
```

`config.alloy` discovers every process, names it by its executable, profiles it with eBPF, and ships
to `http://localhost:4040` — no edits needed.

## 3. Read a process

Open **`http://<box-ip>:4040`**, pick the `process_cpu` profile type, and choose a service —
`kube-apiserver`, `etcd`, `kubelet`, `containerd`, `coredns`, none of which you instrumented. A
`kube-apiserver` flame graph shows Go-runtime frames **and** kernel frames (`do_syscall_64`) in one
stack — the user+kernel truth eBPF gives you. Once the app is running (`make app`), the payment
tier's process appears the same way.

> `:4040` must be open on the box's security group to reach the UI from a browser; otherwise use an
> SSH tunnel: `ssh -L 4040:localhost:4040 ec2-user@<box-ip>` then open `http://localhost:4040`.

## Cleanup

```bash
docker rm -f alloy-ebpf
kubectl delete namespace profiling
```

## Versions (tested)

- `grafana/pyroscope:2.4.4`
- `grafana/alloy:v1.22.0`
