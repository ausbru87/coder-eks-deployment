# =============================================================================
# EKS Auto Mode Storage Class (RWO)
# =============================================================================
# EKS Auto Mode requires ebs.csi.eks.amazonaws.com provisioner
# (not kubernetes.io/aws-ebs or ebs.csi.aws.com)

resource "kubernetes_storage_class" "ebs_auto" {
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
