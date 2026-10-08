#!/usr/bin/env bash
# Install everything needed to run a kind cluster on a fresh EC2 host:
#   docker · kind · kubectl · helm · jq · git · socat · make
# Supports Amazon Linux 2023 and Ubuntu 22.04/24.04 (x86_64). Run as a user with
# sudo (ec2-user / ubuntu). Idempotent — safe to re-run.
set -euo pipefail

labauto k9s

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

# ── grow the disk ───────────────────────────────────────────────────────────────
# Some RHEL AMIs ship a tiny LVM layout (e.g. /var = 2G) that does NOT fill the EBS
# volume, so docker/kind run out of space ("no space left on device") pulling the
# node image. If we're on that layout (a RootVG volume group), grow the partition to
# fill the disk and hand the freed space to /var (where /var/lib/docker lives).
if command -v vgs >/dev/null 2>&1 && sudo vgs RootVG >/dev/null 2>&1; then
  say "expanding LVM to fill the disk (/var holds docker images)"
  command -v growpart >/dev/null 2>&1 || sudo dnf install -y cloud-utils-growpart >/dev/null 2>&1 || true
  PVPART="$(sudo pvs --noheadings -o pv_name 2>/dev/null | awk 'NR==1{$1=$1;print}')"
  ROOTDEV="$(lsblk -ndo pkname "$PVPART" 2>/dev/null)"
  PARTNUM="$(echo "$PVPART" | grep -oE '[0-9]+$')"
  if [ -n "$ROOTDEV" ] && [ -n "$PARTNUM" ]; then
    sudo growpart "/dev/$ROOTDEV" "$PARTNUM" || true    # grow the partition to the disk
    sudo pvresize "$PVPART" || true                      # grow the PV into it
    sudo lvextend -r -L 12G /dev/mapper/RootVG-rootVol 2>/dev/null || true
    sudo lvextend -r -l +100%FREE /dev/mapper/RootVG-varVol 2>/dev/null || true
    df -h /var 2>/dev/null | tail -1
  fi
fi

# ── docker (REAL docker/moby — NOT podman) ──────────────────────────────────────
# kind needs a real Docker daemon driving the node containers. The trap: on
# RHEL/CentOS, `dnf install docker` installs the **podman-docker** shim (podman
# pretending to be docker), and kind then falls back to the rootless-podman
# provider and fails with "requires Delegate=yes". So on RHEL we install Docker CE
# from Docker's own repo. Amazon Linux's `docker` package IS real moby; Ubuntu's
# docker.io is real moby.
. /etc/os-release 2>/dev/null || true
have_real_docker=0
if command -v docker >/dev/null 2>&1 && ! docker --version 2>/dev/null | grep -qi podman; then
  have_real_docker=1
fi
if [ "$have_real_docker" = 0 ]; then
  say "installing Docker (real moby/docker-ce, not podman)  [os: ${ID:-unknown}]"
  case "${ID:-}" in
    amzn)
      sudo dnf install -y docker ;;
    rhel|centos|rocky|almalinux)
      sudo dnf remove -y podman-docker 2>/dev/null || true          # drop the fake 'docker'
      sudo dnf -y install dnf-plugins-core 2>/dev/null || true
      sudo dnf config-manager --add-repo https://download.docker.com/linux/rhel/docker-ce.repo 2>/dev/null \
        || sudo dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
      sudo dnf install -y --allowerasing docker-ce docker-ce-cli containerd.io ;;
    ubuntu|debian)
      sudo apt-get update -qq
      sudo DEBIAN_FRONTEND=noninteractive apt-get install -y docker.io ;;
    *)
      sudo "$PKG" install -y docker || true ;;
  esac
fi
sudo systemctl enable --now docker 2>/dev/null || true
# Add the LOGIN user to the docker group so they can run docker without sudo. Use
# $SUDO_USER when this script is run via `sudo bash …` (as Terraform does) — otherwise
# $USER is "root" and we'd grant the wrong account. Takes effect on next login
# (or immediately via `sg docker -c '…'`, which reads /etc/group).
DOCKER_USER="${SUDO_USER:-$USER}"
sudo usermod -aG docker "$DOCKER_USER" 2>/dev/null || true
echo "  (added '$DOCKER_USER' to the docker group)"
# prove it's real docker, not the podman shim
docker --version 2>/dev/null | grep -qi podman && \
  echo "  ⚠ 'docker' still resolves to podman — kind needs real Docker; see the docker section above" || true

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
