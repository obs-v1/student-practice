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
kubectl apply -f profiling/pyroscope-server.yaml          # grafana/pyroscope:2.4.4, Service :4040
# expose it to the host, and grab the kind node's IP
kubectl -n profiling patch svc pyroscope \
  -p '{"spec":{"type":"NodePort","ports":[{"port":4040,"targetPort":4040,"nodePort":30040}]}}'
NODE=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' lab-control-plane)
echo "pyroscope at http://$NODE:30040"
```

## 2. The eBPF agent (on the host)

Put `$NODE:30040` into `config.alloy` (replace `NODE_IP`), then:

```bash
sed -i "s/NODE_IP/$NODE/" profiling/config.alloy
docker run -d --name alloy-ebpf --privileged --pid=host --network=host \
  -v /boot:/boot:ro -v /sys/kernel/debug:/sys/kernel/debug -v /sys/fs/bpf:/sys/fs/bpf \
  -v "$PWD/profiling/config.alloy:/etc/alloy/config.alloy:ro" \
  grafana/alloy:v1.22.0 run /etc/alloy/config.alloy --storage.path=/tmp/alloy

docker logs alloy-ebpf | grep 'eBPF tracer loaded'        # the agent attached to the kernel
```

## 3. Read a process

Open `http://<box-ip>:30040`, pick the `process_cpu` profile type, and choose a service —
`kube-apiserver`, `etcd`, `kubelet`, `containerd`, `coredns`, none of which you instrumented. A
`kube-apiserver` flame graph shows Go-runtime frames **and** kernel frames (`do_syscall_64`) in one
stack — the user+kernel truth eBPF gives you. Once the app is running (`make app`), the payment
tier's process appears the same way.

## Cleanup

```bash
docker rm -f alloy-ebpf
kubectl delete namespace profiling
```

## Versions (tested)

- `grafana/pyroscope:2.4.4`
- `grafana/alloy:v1.22.0`
