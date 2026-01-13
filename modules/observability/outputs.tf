# Observability Module Outputs

output "grafana_url" {
  description = "Grafana URL (if external access enabled)"
  value       = var.grafana_domain != "" ? "https://${var.grafana_domain}" : ""
}

output "namespace" {
  description = "Kubernetes namespace for observability stack"
  value       = "coder-observability"
}
