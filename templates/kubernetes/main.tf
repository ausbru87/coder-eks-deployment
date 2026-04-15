# Kubernetes Workspace Template
# This is a Coder template for K8s pod workspaces

terraform {
  required_providers {
    coder = {
      source = "coder/coder"
    }
    kubernetes = {
      source = "hashicorp/kubernetes"
    }
  }
}

variable "namespace" {
  type        = string
  description = "Kubernetes namespace for workspaces"
  default     = "coder-workspaces"
}

variable "cluster_name" {
  type        = string
  description = "Name of the EKS cluster (used for VPC lookup in EC2 templates)"
  default     = "coder"
}

variable "auto_mode" {
  type        = bool
  description = "Whether the cluster uses EKS Auto Mode (affects storage class selection)"
  default     = true
}

data "coder_workspace" "me" {}
data "coder_workspace_owner" "me" {}

# =============================================================================
# Parameters
# =============================================================================
data "coder_parameter" "cpu" {
  name         = "cpu"
  display_name = "CPU Cores"
  description  = "Number of CPU cores"
  default      = "4"
  mutable      = true
  icon         = "/icon/memory.svg"

  option {
    name  = "2 Cores"
    value = "2"
  }
  option {
    name  = "4 Cores (Standard)"
    value = "4"
  }
  option {
    name  = "8 Cores (Large)"
    value = "8"
  }
  option {
    name  = "16 Cores (Burst)"
    value = "16"
  }
}

data "coder_parameter" "memory" {
  name         = "memory"
  display_name = "Memory (GB)"
  description  = "Memory in GB"
  default      = "8"
  mutable      = true
  icon         = "/icon/memory.svg"

  option {
    name  = "4 GB"
    value = "4"
  }
  option {
    name  = "8 GB (Standard)"
    value = "8"
  }
  option {
    name  = "16 GB (Large)"
    value = "16"
  }
  option {
    name  = "32 GB (Burst)"
    value = "32"
  }
}

data "coder_parameter" "home_disk_size" {
  name         = "home_disk_size"
  display_name = "Home Disk Size (GB)"
  description  = "Size of persistent home directory"
  default      = "20"
  type         = "number"
  mutable      = false
  icon         = "/icon/database.svg"

  validation {
    min = 10
    max = 100
  }
}

data "coder_parameter" "image" {
  name         = "image"
  display_name = "Container Image"
  description  = "Development container image"
  default      = "codercom/enterprise-base:ubuntu"
  mutable      = true
  icon         = "/icon/docker.svg"

  option {
    name  = "Ubuntu (Base)"
    value = "codercom/enterprise-base:ubuntu"
  }
  option {
    name  = "Go Development"
    value = "codercom/enterprise-golang:ubuntu"
  }
  option {
    name  = "Node.js Development"
    value = "codercom/enterprise-node:ubuntu"
  }
}

# =============================================================================
# Coder Agent
# =============================================================================
resource "coder_agent" "main" {
  os   = "linux"
  arch = "amd64"
  dir  = "/home/coder"

  startup_script = <<-EOT
    #!/bin/bash
    set -e
    
    # Install any user-specific dependencies
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
  agent_id = coder_agent.main.id
  order    = 1
}

module "jetbrains_gateway" {
  count    = data.coder_workspace.me.start_count
  source   = "registry.coder.com/modules/jetbrains-gateway/coder"
  version  = "~> 1.0"
  agent_id = coder_agent.main.id
  folder   = "/home/coder"

  jetbrains_ides = ["IU", "GO", "PY", "WS"]
  default        = "IU"
}

module "dotfiles" {
  source   = "registry.coder.com/modules/dotfiles/coder"
  version  = "~> 1.0"
  agent_id = coder_agent.main.id
}

# =============================================================================
# Persistent Volume Claim
# =============================================================================
resource "kubernetes_persistent_volume_claim_v1" "home" {
  metadata {
    name      = "coder-${data.coder_workspace.me.id}-home"
    namespace = var.namespace
    labels = {
      "app.kubernetes.io/name"     = "coder-pvc"
      "app.kubernetes.io/instance" = "coder-pvc-${data.coder_workspace.me.id}"
      "com.coder.resource"         = "true"
      "com.coder.workspace.id"     = data.coder_workspace.me.id
      "com.coder.workspace.name"   = data.coder_workspace.me.name
      "com.coder.user.id"          = data.coder_workspace_owner.me.id
      "com.coder.user.username"    = data.coder_workspace_owner.me.name
    }
  }
  wait_until_bound = false
  spec {
    access_modes = ["ReadWriteOnce"]
    # Use ebs-auto for EKS Auto Mode, gp3 for standard managed node groups
    storage_class_name = var.auto_mode ? "ebs-auto" : "gp3"
    resources {
      requests = {
        storage = "${data.coder_parameter.home_disk_size.value}Gi"
      }
    }
  }
  lifecycle {
    ignore_changes = all
  }
}

# =============================================================================
# Kubernetes Deployment
# =============================================================================
resource "kubernetes_deployment_v1" "main" {
  count = data.coder_workspace.me.start_count

  metadata {
    name      = "coder-${data.coder_workspace.me.id}"
    namespace = var.namespace
    labels = {
      "app.kubernetes.io/name"     = "coder-workspace"
      "app.kubernetes.io/instance" = "coder-${data.coder_workspace.me.id}"
      "com.coder.resource"         = "true"
      "com.coder.workspace.id"     = data.coder_workspace.me.id
      "com.coder.workspace.name"   = data.coder_workspace.me.name
      "com.coder.user.id"          = data.coder_workspace_owner.me.id
      "com.coder.user.username"    = data.coder_workspace_owner.me.name
    }
  }

  spec {
    replicas = 1
    selector {
      match_labels = {
        "app.kubernetes.io/instance" = "coder-${data.coder_workspace.me.id}"
      }
    }

    template {
      metadata {
        labels = {
          "app.kubernetes.io/name"     = "coder-workspace"
          "app.kubernetes.io/instance" = "coder-${data.coder_workspace.me.id}"
        }
      }

      spec {
        security_context {
          run_as_user     = 1000
          fs_group        = 1000
          run_as_non_root = true
        }

        container {
          name  = "dev"
          image = data.coder_parameter.image.value

          command = ["sh", "-c", coder_agent.main.init_script]

          env {
            name  = "CODER_AGENT_TOKEN"
            value = coder_agent.main.token
          }

          resources {
            requests = {
              cpu    = "${data.coder_parameter.cpu.value}"
              memory = "${data.coder_parameter.memory.value}Gi"
            }
            limits = {
              cpu    = "${data.coder_parameter.cpu.value}"
              memory = "${data.coder_parameter.memory.value}Gi"
            }
          }

          volume_mount {
            mount_path = "/home/coder"
            name       = "home"
            read_only  = false
          }

          security_context {
            allow_privilege_escalation = false
          }
        }

        volume {
          name = "home"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.home.metadata[0].name
          }
        }
      }
    }
  }
}

# =============================================================================
# Outputs
# =============================================================================
resource "coder_metadata" "workspace_info" {
  count       = data.coder_workspace.me.start_count
  resource_id = kubernetes_deployment_v1.main[0].id

  item {
    key   = "CPU"
    value = "${data.coder_parameter.cpu.value} cores"
  }
  item {
    key   = "Memory"
    value = "${data.coder_parameter.memory.value} GB"
  }
  item {
    key   = "Disk"
    value = "${data.coder_parameter.home_disk_size.value} GB"
  }
  item {
    key   = "Image"
    value = data.coder_parameter.image.value
  }
}
