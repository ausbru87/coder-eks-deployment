# Stage 2: Application Outputs
# Consumed by 03-day2 via Terragrunt dependency

output "coder_url" {
  description = "Coder access URL"
  value       = module.coder.coder_url
}

output "coder_namespace" {
  description = "Kubernetes namespace for Coder"
  value       = module.coder.namespace
}

output "cluster_name" {
  description = "EKS cluster name (passthrough for day2)"
  value       = var.cluster_name
}

output "grafana_url" {
  description = "Grafana URL (if external access enabled)"
  value       = module.observability.grafana_url
}
