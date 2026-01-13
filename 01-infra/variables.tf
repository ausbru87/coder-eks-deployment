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
