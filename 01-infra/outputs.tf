# Stage 1: Infrastructure Outputs
# Consumed by 02-apps via Terragrunt dependency

output "cluster_name" {
  description = "EKS cluster name"
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "EKS cluster endpoint"
  value       = module.eks.cluster_endpoint
}

output "cluster_ca_certificate" {
  description = "EKS cluster CA certificate (base64)"
  value       = module.eks.cluster_ca_certificate
}

output "vpc_id" {
  description = "VPC ID"
  value       = module.vpc.vpc_id
}

output "public_subnet_ids" {
  description = "Public subnet IDs"
  value       = module.vpc.public_subnet_ids
}

output "private_subnet_ids" {
  description = "Private subnet IDs"
  value       = module.vpc.private_subnet_ids
}

output "db_connection_url" {
  description = "RDS connection URL for Coder"
  value       = module.rds.connection_url
  sensitive   = true
}

output "db_host" {
  description = "RDS endpoint hostname"
  value       = module.rds.address
}

output "db_password" {
  description = "RDS password"
  value       = module.rds.password
  sensitive   = true
}

output "coder_role_arn" {
  description = "IAM role ARN for Coder service account"
  value       = module.iam.coder_role_arn
}

output "external_secrets_role_arn" {
  description = "IAM role ARN for External Secrets Operator"
  value       = module.iam.external_secrets_role_arn
}

output "provisioner_role_arn" {
  description = "IAM role ARN for provisioner service account"
  value       = module.iam.provisioner_role_arn
}

output "route53_zone_id" {
  description = "Route53 hosted zone ID"
  value       = data.aws_route53_zone.main.zone_id
}

output "acm_certificate_arn" {
  description = "ACM certificate ARN"
  value       = aws_acm_certificate.coder.arn
}

output "github_oauth_secret_arn" {
  description = "Secrets Manager ARN for GitHub OAuth"
  value       = aws_secretsmanager_secret.github_oauth.arn
}

output "kubeconfig_command" {
  description = "Command to configure kubectl"
  value       = "aws eks update-kubeconfig --region ${var.region} --name ${module.eks.cluster_name}"
}
