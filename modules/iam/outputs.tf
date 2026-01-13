output "coder_role_arn" {
  value = aws_iam_role.coder.arn
}

output "alb_controller_role_arn" {
  value = aws_iam_role.alb_controller.arn
}

output "external_secrets_role_arn" {
  value = aws_iam_role.external_secrets.arn
}

output "cluster_autoscaler_role_arn" {
  value = aws_iam_role.cluster_autoscaler.arn
}

output "provisioner_role_arn" {
  value = aws_iam_role.coder_provisioner.arn
}
