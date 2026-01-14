# Observability Module: Coder Observability Stack (Grafana, Prometheus, Loki)
# Deployed as a separate module for clean separation of concerns

variable "name" {
  type        = string
  description = "Resource name prefix"
}

variable "coder_namespace" {
  type        = string
  default     = "coder"
  description = "Kubernetes namespace where Coder is deployed"
}

variable "db_host" {
  type        = string
  description = "RDS endpoint hostname (for postgres-exporter)"
}

variable "db_password" {
  type        = string
  sensitive   = true
  description = "Database password (for postgres-exporter)"
}

variable "grafana_domain" {
  type        = string
  description = "Domain for Grafana external access. Empty = no external access."
  default     = ""
}

variable "acm_certificate_arn" {
  type        = string
  description = "ARN of ACM certificate for TLS"
}

variable "route53_zone_id" {
  type        = string
  description = "Route53 hosted zone ID for DNS records"
}

variable "grafana_github_oauth_enabled" {
  type        = bool
  default     = false
  description = "Enable GitHub OAuth for Grafana"
}

variable "grafana_github_allowed_orgs" {
  type        = string
  default     = ""
  description = "Comma-separated list of GitHub orgs allowed to access Grafana"
}

variable "grafana_root_url" {
  type        = string
  default     = ""
  description = "Root URL for Grafana (required for OAuth callbacks)"
}

# =============================================================================
# Namespace
# =============================================================================
resource "kubernetes_namespace" "observability" {
  metadata {
    name = "coder-observability"
  }
}

# =============================================================================
# Coder Observability Stack (Grafana, Prometheus, Loki)
# =============================================================================

# PostgreSQL exporter secret for observability stack
resource "helm_release" "postgres_external_secret" {
  name       = "observability-postgres-secret"
  namespace  = kubernetes_namespace.observability.metadata[0].name
  repository = "https://bedag.github.io/helm-charts"
  chart      = "raw"
  version    = "2.0.0"

  depends_on = [kubernetes_namespace.observability]

  values = [yamlencode({
    resources = [
      {
        apiVersion = "external-secrets.io/v1beta1"
        kind       = "ExternalSecret"
        metadata = {
          name      = "secret-postgres"
          namespace = "coder-observability"
        }
        spec = {
          refreshInterval = "1h"
          secretStoreRef = {
            name = "aws-secrets-manager"
            kind = "ClusterSecretStore"
          }
          target = {
            name = "secret-postgres"
          }
          data = [
            {
              secretKey = "PGPASSWORD"
              remoteRef = {
                key      = "${var.name}/db-credentials"
                property = "password"
              }
            },
          ]
        }
      }
    ]
  })]
}

# Grafana GitHub OAuth secret (optional)
resource "helm_release" "grafana_github_oauth_secret" {
  count      = var.grafana_github_oauth_enabled ? 1 : 0
  name       = "grafana-github-oauth-secret"
  namespace  = kubernetes_namespace.observability.metadata[0].name
  repository = "https://bedag.github.io/helm-charts"
  chart      = "raw"
  version    = "2.0.0"

  depends_on = [kubernetes_namespace.observability]

  values = [yamlencode({
    resources = [
      {
        apiVersion = "external-secrets.io/v1beta1"
        kind       = "ExternalSecret"
        metadata = {
          name      = "grafana-github-oauth"
          namespace = "coder-observability"
        }
        spec = {
          refreshInterval = "1h"
          secretStoreRef = {
            name = "aws-secrets-manager"
            kind = "ClusterSecretStore"
          }
          target = {
            name = "grafana-github-oauth"
          }
          data = [
            {
              secretKey = "GF_AUTH_GITHUB_CLIENT_ID"
              remoteRef = {
                key      = "${var.name}/grafana-github-oauth"
                property = "client_id"
              }
            },
            {
              secretKey = "GF_AUTH_GITHUB_CLIENT_SECRET"
              remoteRef = {
                key      = "${var.name}/grafana-github-oauth"
                property = "client_secret"
              }
            },
          ]
        }
      }
    ]
  })]
}

resource "helm_release" "coder_observability" {
  name       = "coder-observability"
  repository = "https://helm.coder.com/observability"
  chart      = "coder-observability"
  namespace  = kubernetes_namespace.observability.metadata[0].name
  timeout    = 900

  depends_on = [
    kubernetes_namespace.observability,
    helm_release.postgres_external_secret,
    helm_release.grafana_github_oauth_secret,
  ]

  values = [yamlencode({
    global = {
      coder = {
        controlPlaneNamespace         = var.coder_namespace
        externalProvisionersNamespace = var.coder_namespace
        workspacesSelector            = "namespace=`coder-workspaces`"
      }
      postgres = {
        hostname    = var.db_host
        port        = 5432
        database    = "coder"
        username    = "coder"
        sslmode     = "require"
        mountSecret = "secret-postgres"
      }
    }
    # Storage class for EKS Auto Mode
    prometheus = {
      server = {
        persistentVolume = {
          storageClass = "ebs-auto"
        }
      }
      alertmanager = {
        persistentVolume = {
          storageClass = "ebs-auto"
        }
      }
    }
    grafana = {
      persistence = {
        enabled          = false # StatefulSet uses volumeClaimTemplates instead
        storageClassName = "ebs-auto"
      }
      # Disable default Grafana service when using custom NLB
      service = {
        enabled = var.grafana_domain == ""
      }
      # Inject GitHub OAuth secrets as environment variables (when enabled)
      envFromSecrets = var.grafana_github_oauth_enabled ? [{
        name     = "grafana-github-oauth"
        optional = false
      }] : []
      "grafana.ini" = merge(
        # Server config (required for OAuth callbacks)
        var.grafana_root_url != "" ? {
          server = {
            root_url = var.grafana_root_url
          }
        } : {},
        # Anonymous access disabled by default
        {
          "auth.anonymous" = {
            enabled = false
          }
        },
        # GitHub OAuth config (when enabled)
        var.grafana_github_oauth_enabled ? {
          "auth.github" = {
            enabled               = true
            allow_sign_up         = true
            auto_login            = false
            scopes                = "user:email,read:org"
            auth_url              = "https://github.com/login/oauth/authorize"
            token_url             = "https://github.com/login/oauth/access_token"
            api_url               = "https://api.github.com/user"
            allowed_organizations = var.grafana_github_allowed_orgs
            # client_id and client_secret come from GF_AUTH_GITHUB_* env vars
          }
        } : {}
      )
    }
    # Loki: SingleBinary mode for demo environments (no S3 required)
    # For production scale, switch to S3-backed distributed mode
    loki = {
      deploymentMode = "SingleBinary"
      loki = {
        auth_enabled = false
        commonConfig = {
          replication_factor = 1
        }
        storage = {
          type = "filesystem"
        }
      }
      singleBinary = {
        replicas = 1
        persistence = {
          storageClass = "ebs-auto"
        }
        extraVolumes = [{
          name     = "rules"
          emptyDir = {}
        }]
        extraVolumeMounts = [{
          name      = "rules"
          mountPath = "/rules"
        }]
      }
      # Disable distributed components
      backend = { replicas = 0 }
      read    = { replicas = 0 }
      write   = { replicas = 0 }
    }
  })]
}

# =============================================================================
# Grafana NLB Service (external access with TLS)
# =============================================================================
resource "kubernetes_service" "grafana" {
  count = var.grafana_domain != "" ? 1 : 0

  metadata {
    name      = "grafana-nlb"
    namespace = kubernetes_namespace.observability.metadata[0].name
    annotations = {
      "service.beta.kubernetes.io/aws-load-balancer-type"                 = "external"
      "service.beta.kubernetes.io/aws-load-balancer-nlb-target-type"      = "ip"
      "service.beta.kubernetes.io/aws-load-balancer-scheme"               = "internet-facing"
      "service.beta.kubernetes.io/aws-load-balancer-ssl-cert"             = var.acm_certificate_arn
      "service.beta.kubernetes.io/aws-load-balancer-ssl-ports"            = "443"
      "service.beta.kubernetes.io/aws-load-balancer-healthcheck-path"     = "/api/health"
      "service.beta.kubernetes.io/aws-load-balancer-healthcheck-port"     = "3000"
      "service.beta.kubernetes.io/aws-load-balancer-healthcheck-protocol" = "HTTP"
    }
  }

  spec {
    type                = "LoadBalancer"
    load_balancer_class = "eks.amazonaws.com/nlb"

    selector = {
      "app.kubernetes.io/name"     = "grafana"
      "app.kubernetes.io/instance" = "coder-observability"
    }

    port {
      name        = "https"
      port        = 443
      target_port = 3000
      protocol    = "TCP"
    }
  }

  depends_on = [
    kubernetes_namespace.observability,
    helm_release.coder_observability
  ]
}

# DNS record for Grafana
resource "aws_route53_record" "grafana" {
  count = var.grafana_domain != "" ? 1 : 0

  zone_id = var.route53_zone_id
  name    = var.grafana_domain
  type    = "CNAME"
  ttl     = 300
  records = [kubernetes_service.grafana[0].status[0].load_balancer[0].ingress[0].hostname]
}
