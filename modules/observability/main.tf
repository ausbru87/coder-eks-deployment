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

resource "helm_release" "coder_observability" {
  name       = "coder-observability"
  repository = "https://helm.coder.com/observability"
  chart      = "coder-observability"
  namespace  = kubernetes_namespace.observability.metadata[0].name
  timeout    = 900

  depends_on = [
    kubernetes_namespace.observability,
    helm_release.postgres_external_secret
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
