# Stage 1: Infrastructure Variables

variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-west-2"
}

variable "env_name" {
  description = "Environment name used as resource prefix (e.g., 'myenv'). Leave empty for no prefix."
  type        = string
  default     = ""

  validation {
    condition     = can(regex("^[a-zA-Z0-9-]*$", var.env_name))
    error_message = "env_name can only contain alphanumeric characters and hyphens"
  }
}

locals {
  name = var.env_name != "" ? "${var.env_name}-coder" : "coder"
}

variable "domain" {
  description = "Domain for Coder (e.g., dev.example.com)"
  type        = string
}

variable "wildcard_domain" {
  description = "Wildcard domain for workspace apps (e.g., *.dev.example.com)"
  type        = string
}

variable "route53_zone_name" {
  description = "Route53 hosted zone name (e.g., example.com)"
  type        = string
}

variable "github_oauth_client_id" {
  description = "GitHub OAuth App Client ID"
  type        = string
  sensitive   = true
}

variable "github_oauth_client_secret" {
  description = "GitHub OAuth App Client Secret"
  type        = string
  sensitive   = true
}

variable "github_allowed_orgs" {
  description = "GitHub organization(s) allowed for OAuth login (comma-separated)"
  type        = string
}

# =============================================================================
# Grafana GitHub OAuth (optional - enables SSO for Grafana)
# =============================================================================
variable "grafana_github_oauth_client_id" {
  type        = string
  description = "GitHub OAuth App client ID for Grafana (create at github.com/settings/developers)"
  default     = ""
}

variable "grafana_github_oauth_client_secret" {
  type        = string
  sensitive   = true
  description = "GitHub OAuth App client secret for Grafana"
  default     = ""
}

variable "grafana_github_allowed_orgs" {
  type        = string
  description = "Comma-separated list of GitHub organizations allowed to access Grafana"
  default     = ""
}

# =============================================================================
# EKS Mode
# =============================================================================
variable "auto_mode" {
  description = "Enable EKS Auto Mode. Set to false for managed node groups (required for envbox/Sysbox/DinD)."
  type        = bool
  default     = true
}
