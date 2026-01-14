# EC2 Workspace Template
# This is a Coder template for EC2 VM workspaces

terraform {
  required_providers {
    coder = {
      source = "coder/coder"
    }
    aws = {
      source = "hashicorp/aws"
    }
    cloudinit = {
      source = "hashicorp/cloudinit"
    }
  }
}

variable "region" {
  type        = string
  description = "AWS region"
  default     = "us-west-2"
}

variable "env_name" {
  type        = string
  description = "Environment name for tagging"
  default     = ""
}

data "coder_workspace" "me" {}
data "coder_workspace_owner" "me" {}

# =============================================================================
# Parameters
# =============================================================================
data "coder_parameter" "instance_type" {
  name         = "instance_type"
  display_name = "Instance Type"
  description  = "EC2 instance type"
  default      = "t3.xlarge"
  mutable      = true
  icon         = "/icon/aws.svg"

  option {
    name  = "t3.large (2 vCPU, 8 GB)"
    value = "t3.large"
  }
  option {
    name  = "t3.xlarge (4 vCPU, 16 GB) - Standard"
    value = "t3.xlarge"
  }
  option {
    name  = "t3.2xlarge (8 vCPU, 32 GB) - Large"
    value = "t3.2xlarge"
  }
  option {
    name  = "m6i.4xlarge (16 vCPU, 64 GB) - Burst"
    value = "m6i.4xlarge"
  }
}

data "coder_parameter" "disk_size" {
  name         = "disk_size"
  display_name = "Root Disk Size (GB)"
  description  = "Size of root EBS volume"
  default      = "50"
  type         = "number"
  mutable      = false
  icon         = "/icon/database.svg"

  validation {
    min = 20
    max = 500
  }
}

# =============================================================================
# Data Sources
# =============================================================================
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

data "aws_vpc" "selected" {
  tags = {
    Name = "coder-demo"
  }
}

data "aws_subnets" "private" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.selected.id]
  }
  filter {
    name   = "tag:Name"
    values = ["*private*"]
  }
}

# =============================================================================
# Coder Agent
# =============================================================================
resource "coder_agent" "main" {
  count = data.coder_workspace.me.start_count
  os    = "linux"
  arch  = "amd64"
  dir   = "/home/coder"
  auth  = "aws-instance-identity"

  startup_script = <<-EOT
    #!/bin/bash
    set -e
    
    # Wait for cloud-init to complete
    cloud-init status --wait
    
    # Install development tools if not present
    if ! command -v git &> /dev/null; then
      sudo apt-get update
      sudo apt-get install -y git curl wget jq
    fi
    
    # Run user startup script if exists
    if [ -f ~/.coder-startup.sh ]; then
      bash ~/.coder-startup.sh
    fi
  EOT

  metadata {
    display_name = "CPU Usage"
    key          = "cpu_usage"
    script       = "coder stat cpu"
    interval     = 10
    timeout      = 1
  }

  metadata {
    display_name = "RAM Usage"
    key          = "ram_usage"
    script       = "coder stat mem"
    interval     = 10
    timeout      = 1
  }

  metadata {
    display_name = "Disk Usage"
    key          = "disk_usage"
    script       = "coder stat disk --path $HOME"
    interval     = 60
    timeout      = 30
  }
}

# =============================================================================
# IDE Apps
# =============================================================================
module "code-server" {
  count    = data.coder_workspace.me.start_count
  source   = "registry.coder.com/modules/code-server/coder"
  version  = "~> 1.0"
  agent_id = coder_agent.main[0].id
  order    = 1
}

module "jetbrains_gateway" {
  count    = data.coder_workspace.me.start_count
  source   = "registry.coder.com/modules/jetbrains-gateway/coder"
  version  = "~> 1.0"
  agent_id = coder_agent.main[0].id
  folder   = "/home/coder"

  jetbrains_ides = ["IU", "GO", "PY", "WS"]
  default        = "IU"
}

module "dotfiles" {
  count    = data.coder_workspace.me.start_count
  source   = "registry.coder.com/modules/dotfiles/coder"
  version  = "~> 1.0"
  agent_id = coder_agent.main[0].id
}

# =============================================================================
# Cloud-Init
# =============================================================================
data "cloudinit_config" "user_data" {
  gzip          = false
  base64_encode = false
  boundary      = "//"

  part {
    filename     = "cloud-config.yaml"
    content_type = "text/cloud-config"
    content      = <<-EOT
      #cloud-config
      hostname: ${lower(data.coder_workspace.me.name)}
      users:
        - name: coder
          sudo: ALL=(ALL) NOPASSWD:ALL
          shell: /bin/bash
          groups: docker
      packages:
        - git
        - curl
        - wget
        - jq
        - vim
        - htop
        - docker.io
      runcmd:
        - systemctl enable docker
        - systemctl start docker
        - usermod -aG docker coder
    EOT
  }

  part {
    filename     = "userdata.sh"
    content_type = "text/x-shellscript"
    content      = <<-EOT
      #!/bin/bash
      # Run Coder agent as the coder user
      sudo -u coder sh -c '${try(coder_agent.main[0].init_script, "")}'
    EOT
  }
}

# =============================================================================
# Security Group
# =============================================================================
resource "aws_security_group" "workspace" {
  name_prefix = "coder-workspace-${data.coder_workspace.me.id}-"
  vpc_id      = data.aws_vpc.selected.id

  # Agent → Coderd (REQUIRED)
  egress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Coder agent communication"
  }

  # STUN for P2P (RECOMMENDED)
  egress {
    from_port   = 3478
    to_port     = 3478
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "STUN NAT traversal"
  }

  # All UDP for WireGuard P2P
  egress {
    from_port   = 0
    to_port     = 65535
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "WireGuard P2P"
  }

  # HTTP/HTTPS for package downloads
  egress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "HTTP"
  }

  tags = {
    Name              = "coder-workspace-${data.coder_workspace.me.name}"
    Coder_Provisioned = "true"
    env-name          = var.env_name
  }

  lifecycle {
    create_before_destroy = true
  }
}

# =============================================================================
# EC2 Instance
# =============================================================================
resource "aws_instance" "dev" {
  ami           = data.aws_ami.ubuntu.id
  instance_type = data.coder_parameter.instance_type.value
  subnet_id     = data.aws_subnets.private.ids[0]
  user_data     = data.cloudinit_config.user_data.rendered

  vpc_security_group_ids = [aws_security_group.workspace.id]

  root_block_device {
    volume_size           = data.coder_parameter.disk_size.value
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  tags = {
    Name              = "coder-${data.coder_workspace_owner.me.name}-${data.coder_workspace.me.name}"
    Coder_Provisioned = "true"
    env-name          = var.env_name
  }

  lifecycle {
    ignore_changes = [ami, user_data]
  }
}

# =============================================================================
# Instance State Control (start/stop without destroy)
# =============================================================================
resource "aws_ec2_instance_state" "dev" {
  instance_id = aws_instance.dev.id
  state       = data.coder_workspace.me.transition == "start" ? "running" : "stopped"
}

# =============================================================================
# Outputs
# =============================================================================
resource "coder_metadata" "workspace_info" {
  count       = data.coder_workspace.me.start_count
  resource_id = aws_instance.dev.id

  item {
    key   = "Instance Type"
    value = data.coder_parameter.instance_type.value
  }
  item {
    key   = "Disk Size"
    value = "${data.coder_parameter.disk_size.value} GB"
  }
  item {
    key   = "Region"
    value = var.region
  }
  item {
    key   = "Instance ID"
    value = aws_instance.dev.id
  }
  item {
    key   = "Private IP"
    value = aws_instance.dev.private_ip
  }
}
