# EKS Module: Cluster with Auto Mode
# Auto Mode automatically manages compute, networking (ALB), and storage (EBS)

variable "name" {
  type    = string
  default = "coder-demo"
}

variable "vpc_id" {
  type = string
}

variable "private_subnet_ids" {
  type = list(string)
}

variable "public_subnet_ids" {
  type        = list(string)
  description = "Public subnet IDs for internet-facing load balancers"
}

variable "kubernetes_version" {
  type    = string
  default = "1.34"
}

variable "auto_mode" {
  description = "Enable EKS Auto Mode (recommended)"
  type        = bool
  default     = true
}

# Data sources
data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

# EKS Cluster IAM Role
resource "aws_iam_role" "cluster" {
  name = "${var.name}-eks-cluster"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = ["sts:AssumeRole", "sts:TagSession"]
      Effect = "Allow"
      Principal = {
        Service = "eks.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "cluster_policy" {
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = aws_iam_role.cluster.name
}

# Additional policies required for Auto Mode
resource "aws_iam_role_policy_attachment" "cluster_compute_policy" {
  count      = var.auto_mode ? 1 : 0
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKSComputePolicy"
  role       = aws_iam_role.cluster.name
}

resource "aws_iam_role_policy_attachment" "cluster_storage_policy" {
  count      = var.auto_mode ? 1 : 0
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKSBlockStoragePolicy"
  role       = aws_iam_role.cluster.name
}

resource "aws_iam_role_policy_attachment" "cluster_lb_policy" {
  count      = var.auto_mode ? 1 : 0
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKSLoadBalancingPolicy"
  role       = aws_iam_role.cluster.name
}

resource "aws_iam_role_policy_attachment" "cluster_networking_policy" {
  count      = var.auto_mode ? 1 : 0
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKSNetworkingPolicy"
  role       = aws_iam_role.cluster.name
}

# EKS Cluster Security Group
resource "aws_security_group" "cluster" {
  name_prefix = "${var.name}-cluster-"
  vpc_id      = var.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.name}-cluster-sg"
  }
}

# EKS Cluster with Auto Mode
resource "aws_eks_cluster" "main" {
  name     = var.name
  role_arn = aws_iam_role.cluster.arn
  version  = var.kubernetes_version

  # Required for Auto Mode
  bootstrap_self_managed_addons = var.auto_mode ? false : true

  vpc_config {
    # Include both public and private subnets - EKS Auto Mode uses tags to identify
    # public subnets (kubernetes.io/role/elb) for internet-facing load balancers
    subnet_ids              = concat(var.private_subnet_ids, var.public_subnet_ids)
    endpoint_private_access = true
    endpoint_public_access  = true
    security_group_ids      = [aws_security_group.cluster.id]
  }

  # Auto Mode configuration
  dynamic "compute_config" {
    for_each = var.auto_mode ? [1] : []
    content {
      enabled       = true
      node_pools    = ["general-purpose", "system"]
      node_role_arn = aws_iam_role.node.arn
    }
  }

  dynamic "storage_config" {
    for_each = var.auto_mode ? [1] : []
    content {
      block_storage {
        enabled = true
      }
    }
  }

  dynamic "kubernetes_network_config" {
    for_each = var.auto_mode ? [1] : []
    content {
      elastic_load_balancing {
        enabled = true
      }
    }
  }

  enabled_cluster_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  # Allow cluster creator admin access
  access_config {
    authentication_mode                         = "API_AND_CONFIG_MAP"
    bootstrap_cluster_creator_admin_permissions = true
  }

  depends_on = [
    aws_iam_role_policy_attachment.cluster_policy,
    aws_iam_role_policy_attachment.cluster_compute_policy,
    aws_iam_role_policy_attachment.cluster_storage_policy,
    aws_iam_role_policy_attachment.cluster_lb_policy,
    aws_iam_role_policy_attachment.cluster_networking_policy,
  ]
}

# OIDC Provider for IRSA
data "tls_certificate" "eks" {
  url = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "eks" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks.certificates[0].sha1_fingerprint]
  url             = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

# Node IAM Role (used by Auto Mode for provisioned nodes)
resource "aws_iam_role" "node" {
  name = "${var.name}-eks-node"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "node_worker" {
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  role       = aws_iam_role.node.name
}

resource "aws_iam_role_policy_attachment" "node_cni" {
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = aws_iam_role.node.name
}

resource "aws_iam_role_policy_attachment" "node_ecr" {
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  role       = aws_iam_role.node.name
}
