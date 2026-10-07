# ec2-kube — Kubernetes only, no application

A minimal clone of `student-bootcamp/ec2-k8s` with **all app/platform/observability deploy
removed**. It does exactly one thing: stand up an empty single-node **kind** cluster on an
EC2 host, ready for you to deploy anything onto (for example the `student-practice` lab).

## What it is / isn't

- ✅ Installs the tooling (docker, kind, kubectl, helm, jq).
- ✅ Preps the host (kind-friendly sysctls) and creates the kind cluster.
- ✅ Optionally exposes the API server so you can `kubectl` from your laptop.
- ❌ Deploys **no** bankobs services, databases, Helm charts, Prometheus/Loki/Jaeger, or
  OTel. The cluster comes up empty.

## Use it on a fresh VM

```bash
# 1. tools (needs sudo; run once)
bash scripts/install-tools.sh
#    then log out/in — or `newgrp docker` — so docker works without sudo

# 2. prep the host + create the cluster
make up

# 3. confirm
kubectl get nodes
make status
```

That's it — you now have Kubernetes. Deploy whatever you like, e.g.:

```bash
kubectl create deployment hello --image=nginx
# ...or run a lab that expects an empty cluster.
```

## Reach it from your laptop (optional)

```bash
make expose > lab.kubeconfig          # publishes the API on the public IP (systemd + socat)
# on your laptop:
export KUBECONFIG=$PWD/lab.kubeconfig
kubectl get nodes
```
TLS verification stays on (the kubeconfig pins `tls-server-name: kubernetes`). Treat
`lab.kubeconfig` as a root credential and keep the instance's security group tight.

## Ports published on the host

`kind-config.yaml` maps these NodePorts to host ports so UIs are reachable without a
port-forward (matching the student-practice lab; add your own if a lab differs):

| Host port | NodePort | For |
|-----------|----------|-----|
| 80    | 30080 | generic web / portal |
| 443   | 30443 | generic TLS |
| 3000  | 30300 | Grafana (if you add one) |
| 9090  | 30909 | Prometheus (student-practice) |
| 16686 | 30686 | Jaeger (student-practice) |
| 3100  | 30310 | Loki (optional) |

## Targets

```
make tools      # install docker/kind/kubectl/helm/jq (sudo; once)
make up         # prep + create the cluster (the one-shot)
make prep       # host checks + sysctls only
make cluster-up # create the kind cluster only (idempotent)
make expose     # print a laptop-reachable kubeconfig to stdout
make status     # nodes + all pods
make down       # delete the cluster
```

## Requirements

- A Linux EC2 host (Amazon Linux 2023 or Ubuntu 22.04/24.04, **x86_64**), with sudo.
- Enough capacity for whatever you'll deploy. An empty cluster is tiny; the full bankobs
  platform wants ~8 vCPU / 16–32 GB.
