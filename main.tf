# Provision an EC2 box and bring up an EMPTY kind cluster on it — the student-practice
# equivalent of student-bootcamp's main.tf, but with NO app deploy and NO license. It only
# makes Kubernetes available; you then run the lab's `make app / metrics / logs / traces`
# against it (locally on the box, or remotely via `make kubeconfig`).
#
#   make tf-apply     # create the box + kind cluster (run from your workstation)
#   make kubeconfig   # fetch a kubeconfig that reaches it
#   make tf-destroy   # tear the box down
#
# Mirrors the bootcamp's shape: a spot instance, SSH *password* auth (no key pair), two
# security groups (SSH + all-open), and two remote-exec phases so the docker group from
# install-tools applies to the second (cluster-up) SSH session.

terraform {
  required_version = ">= 1.3.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

variable "region" {
  description = "AWS region. If you change this, update `ami` to an Amazon Linux 2023 image in that region."
  default     = "us-east-1"
}

variable "ami" {
  description = "Base AMI (ec2-user, SSH password auth baked in). Default is the bootcamp's us-east-1 image — a RHEL 9 image; install-tools.sh handles RHEL (real Docker CE + LVM disk grow)."
  default     = "ami-0220d79f3f480ecf5"
}

variable "instance_type" {
  description = "An empty cluster is tiny; the full bankobs app (make app) wants ~8 vCPU / 32GB+. r5.4xlarge matches the bootcamp."
  default     = "r5.4xlarge"
}

variable "repo_url" {
  default = "https://github.com/obs-v1/student-practice.git"
}

provider "aws" {
  region = var.region
}

resource "aws_security_group" "ssh" {
  name        = "student-practice-ssh"
  description = "Allow SSH inbound"
  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "student-practice-ssh" }
}

# Opens all ports (incl. the mapped lab UIs: 80, 9090, 16686, and the kube API 6443).
resource "aws_security_group" "all_open" {
  name        = "student-practice-all-open"
  description = "Allow all inbound traffic from any IPv4"
  ingress {
    description = "All ports from any IPv4"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "student-practice-all-open" }
}

resource "aws_instance" "lab" {
  ami           = var.ami
  instance_type = var.instance_type

  vpc_security_group_ids = [aws_security_group.ssh.id, aws_security_group.all_open.id]

  instance_market_options {
    market_type = "spot"
    spot_options {
      spot_instance_type = "one-time"
    }
  }

  root_block_device {
    # 150 GB: the full bankobs platform (75 services + Oracle/Cassandra/Kafka images +
    # the kind node) needs it. install-tools.sh grows the LVM to hand most of this to
    # /var (where /var/lib/docker lives). 100 GB was tight (/var ~76 GB).
    volume_size = 150
    volume_type = "gp3"
  }

  tags = { Name = "student-practice" }
}

output "public_ip" {
  description = "Public IP of the instance"
  value       = aws_instance.lab.public_ip
}

# Phase 1 — clone the repo and install tooling (docker, kind, kubectl, helm, jq).
resource "null_resource" "install_tools" {
  depends_on = [aws_instance.lab]
  triggers   = { instance_id = timestamp() }

  provisioner "remote-exec" {
    inline = [
      "rm -rf student-practice",
      "git clone ${var.repo_url}",
      "cd student-practice",
      "sudo bash cluster/scripts/install-tools.sh",
    ]
    connection {
      type     = "ssh"
      host     = aws_instance.lab.public_ip
      user     = "ec2-user"
      password = "DevOps321"
    }
  }
}

# Phase 2 — a FRESH SSH session (so the docker group from phase 1 is in effect): create the
# empty kind cluster, then republish its API server on :6443 for `make kubeconfig`.
# No app, no license — just Kubernetes.
resource "null_resource" "cluster_up" {
  depends_on = [aws_instance.lab, null_resource.install_tools]
  triggers   = { instance_id = timestamp() }

  provisioner "remote-exec" {
    # usermod -aG docker (phase 1) does NOT take effect in this new SSH session, so a
    # plain `docker info` still fails ("docker not usable by this user"). Run under
    # `sg docker`, which activates the docker group from /etc/group for the command
    # without needing a re-login.
    inline = [
      "cd student-practice/cluster",
      "sg docker -c 'make up'",
      "sg docker -c 'bash scripts/expose-kube-api.sh >/dev/null'",
    ]
    connection {
      type     = "ssh"
      host     = aws_instance.lab.public_ip
      user     = "ec2-user"
      password = "DevOps321"
    }
  }
}
