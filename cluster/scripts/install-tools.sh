#!/usr/bin/env bash
# Install everything needed to run a kind cluster on a fresh EC2 host:
#   docker · kind · kubectl · helm · jq · git · socat · make
# Supports Amazon Linux 2023 and Ubuntu 22.04/24.04 (x86_64). Run as a user with
# sudo (ec2-user / ubuntu). Idempotent — safe to re-run.
set -euo pipefail

export PATH="/usr/local/bin:$PATH"
KIND_VERSION="v0.32.0"
ARCH="$(uname -m)"
[ "${ARCH}" = "x86_64" ] || { echo "✗ x86_64 required (kind node image is amd64), got ${ARCH}"; exit 1; }

say() { echo -e "\n─── $* ───"; }

# ── detect the package manager ────────────────────────────────────────────────
if command -v dnf >/dev/null 2>&1;      then PKG=dnf
elif command -v yum >/dev/null 2>&1;    then PKG=yum
elif command -v apt-get >/dev/null 2>&1; then PKG=apt
else echo "✗ no supported package manager (dnf/yum/apt) found"; exit 1; fi

pkg_install() {
  if [ "$PKG" = apt ]; then sudo apt-get update -qq && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
  else sudo "$PKG" install -y "$@"; fi
}

# ── base packages ─────────────────────────────────────────────────────────────
say "base packages (git, jq, socat, make, curl, tar)"
pkg_install git jq socat make curl tar || true

# ── docker ─────────────────────────────────────────────────────────────────────
if ! command -v docker >/dev/null 2>&1; then
  say "installing docker"
  if [ "$PKG" = apt ]; then pkg_install docker.io
  else pkg_install docker; fi
fi
sudo systemctl enable --now docker 2>/dev/null || true
# let this user run docker without sudo (takes effect on next login / `newgrp docker`)
sudo usermod -aG docker "$USER" 2>/dev/null || true

# ── kubectl (latest stable) ─────────────────────────────────────────────────────
if ! command -v kubectl >/dev/null 2>&1; then
  say "installing kubectl"
  KUBECTL_VERSION="$(curl -sL https://dl.k8s.io/release/stable.txt)"
  curl -sLo /tmp/kubectl "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl"
  sudo install -m 0755 /tmp/kubectl /usr/local/bin/kubectl && rm -f /tmp/kubectl
fi

# ── kind ─────────────────────────────────────────────────────────────────────
if ! command -v kind >/dev/null 2>&1; then
  say "installing kind ${KIND_VERSION}"
  curl -sLo /tmp/kind "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-linux-amd64"
  sudo install -m 0755 /tmp/kind /usr/local/bin/kind && rm -f /tmp/kind
fi

# ── helm ─────────────────────────────────────────────────────────────────────
if ! command -v helm >/dev/null 2>&1; then
  say "installing helm"
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi

export PATH="/usr/local/bin:$PATH"
say "versions"
docker --version
kind --version
kubectl version --client 2>/dev/null | head -1 || true
helm version --short
jq --version

echo ""
echo "✓ tools installed."
echo "  ⚠ Log out and back in (or run 'newgrp docker') so your user can use docker"
echo "    without sudo, then:  make up"
