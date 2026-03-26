# =============================================================================
# Storage Classes
# =============================================================================

# EKS Auto Mode storage class (uses eks-managed EBS CSI)
resource "kubernetes_storage_class" "ebs_auto" {
  count = var.auto_mode ? 1 : 0

  metadata {
    name = "ebs-auto"
    annotations = {
      "storageclass.kubernetes.io/is-default-class" = "true"
    }
  }
  storage_provisioner    = "ebs.csi.eks.amazonaws.com"
  volume_binding_mode    = "WaitForFirstConsumer"
  allow_volume_expansion = true
  parameters = {
    type      = "gp3"
    encrypted = "true"
  }

  depends_on = [aws_eks_cluster.main]
}

# Standard mode storage class (uses self-managed EBS CSI driver)
resource "kubernetes_storage_class" "ebs_standard" {
  count = var.auto_mode ? 0 : 1

  metadata {
    name = "gp3"
    annotations = {
      "storageclass.kubernetes.io/is-default-class" = "true"
    }
  }
  storage_provisioner    = "ebs.csi.aws.com"
  volume_binding_mode    = "WaitForFirstConsumer"
  allow_volume_expansion = true
  parameters = {
    type      = "gp3"
    encrypted = "true"
  }

  depends_on = [aws_eks_cluster.main]
}
