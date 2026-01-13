# Coder Module: Helm deployment with HA config, External Secrets, NLB

variable "name" {
  type    = string
  default = "coder-demo"
}

variable "cluster_name" {
  type = string
}

variable "cluster_endpoint" {
  type = string
}

variable "cluster_ca_certificate" {
  type = string
}

variable "coder_namespace" {
  type    = string
  default = "coder"
}

variable "domain" {
  type        = string
  description = "Coder access URL domain (e.g., dev.fed.demo.coder.com)"
}

variable "coder_version" {
  type        = string
  description = "Coder Helm chart version"
  default     = "2.28.6"
}

variable "wildcard_domain" {
  type        = string
  description = "Wildcard domain for workspace apps (e.g., *.dev.fed.demo.coder.com)"
}

variable "acm_certificate_arn" {
  type        = string
  description = "ARN of ACM certificate for TLS"
}

variable "coder_role_arn" {
  type        = string
  description = "IAM role ARN for Coder service account"
}

# ALB controller role not needed with Auto Mode
# variable "alb_controller_role_arn" {}

variable "external_secrets_role_arn" {
  type = string
}

# Cluster autoscaler role not needed with Auto Mode
# variable "cluster_autoscaler_role_arn" {}

variable "db_connection_url" {
  type      = string
  sensitive = true
}

variable "github_oauth_secret_arn" {
  type = string
}



variable "vpc_id" {
  type = string
}

variable "public_subnet_ids" {
  type = list(string)
}

variable "route53_zone_id" {
  type        = string
  description = "Route53 hosted zone ID for DNS records"
}



variable "github_allowed_orgs" {
  type        = string
  description = "GitHub organization(s) allowed for OAuth login (comma-separated)"
}

# Note: kubernetes and helm providers are configured in root module

# =============================================================================
# Namespaces
# =============================================================================
resource "kubernetes_namespace" "coder" {
  metadata {
    name = var.coder_namespace
  }
}

resource "kubernetes_namespace" "external_secrets" {
  metadata {
    name = "external-secrets"
  }
}

resource "kubernetes_namespace" "coder_workspaces" {
  metadata {
    name = "coder-workspaces"
    labels = {
      "app.kubernetes.io/managed-by" = "coder"
    }
  }
}

# =============================================================================
# RBAC for Provisioners (K8s workspace creation)
# =============================================================================
resource "kubernetes_cluster_role" "coder_provisioner" {
  metadata {
    name = "coder-provisioner"
  }

  # Pod management for workspaces
  rule {
    api_groups = [""]
    resources  = ["pods", "pods/log", "pods/exec"]
    verbs      = ["create", "get", "list", "watch", "update", "patch", "delete"]
  }

  # PVC for workspace storage
  rule {
    api_groups = [""]
    resources  = ["persistentvolumeclaims"]
    verbs      = ["create", "get", "list", "watch", "update", "patch", "delete"]
  }

  # Secrets for workspace credentials
  rule {
    api_groups = [""]
    resources  = ["secrets"]
    verbs      = ["create", "get", "list", "watch", "update", "patch", "delete"]
  }

  # Services for workspace networking
  rule {
    api_groups = [""]
    resources  = ["services"]
    verbs      = ["create", "get", "list", "watch", "update", "patch", "delete"]
  }

  # ConfigMaps for workspace config
  rule {
    api_groups = [""]
    resources  = ["configmaps"]
    verbs      = ["create", "get", "list", "watch", "update", "patch", "delete"]
  }

  # Events for debugging
  rule {
    api_groups = [""]
    resources  = ["events"]
    verbs      = ["get", "list", "watch"]
  }

  # Deployments/StatefulSets if templates use them
  rule {
    api_groups = ["apps"]
    resources  = ["deployments", "statefulsets"]
    verbs      = ["create", "get", "list", "watch", "update", "patch", "delete"]
  }

  # ServiceAccounts for workspace pods
  rule {
    api_groups = [""]
    resources  = ["serviceaccounts"]
    verbs      = ["create", "get", "list", "watch", "update", "patch", "delete"]
  }

  # Roles/RoleBindings for workspace RBAC
  rule {
    api_groups = ["rbac.authorization.k8s.io"]
    resources  = ["roles", "rolebindings"]
    verbs      = ["create", "get", "list", "watch", "update", "patch", "delete"]
  }
}

# Bind ClusterRole to coder SA in coder-workspaces namespace
resource "kubernetes_role_binding" "coder_workspaces" {
  metadata {
    name      = "coder-provisioner"
    namespace = kubernetes_namespace.coder_workspaces.metadata[0].name
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role.coder_provisioner.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = "coder"
    namespace = var.coder_namespace
  }
}

# Note: Using NLB via Service type LoadBalancer - EKS Auto Mode handles provisioning

# =============================================================================
# External Secrets Operator
# =============================================================================
resource "helm_release" "external_secrets" {
  name       = "external-secrets"
  repository = "https://charts.external-secrets.io"
  chart      = "external-secrets"
  namespace  = "external-secrets"
  version    = "0.10.0" # Stable - v1.2.1 has CRD timing issues

  set {
    name  = "serviceAccount.create"
    value = "true"
  }

  set {
    name  = "serviceAccount.name"
    value = "external-secrets"
  }

  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = var.external_secrets_role_arn
  }

  wait    = true
  timeout = 900

  depends_on = [kubernetes_namespace.external_secrets]
}

# Note: Cluster Autoscaler not needed - EKS Auto Mode handles node scaling automatically

data "aws_region" "current" {}

# =============================================================================
# External Secrets - Applied via Helm to avoid plan-time K8s connection issues
# =============================================================================
resource "helm_release" "external_secrets_config" {
  name       = "external-secrets-config"
  namespace  = var.coder_namespace
  repository = "https://bedag.github.io/helm-charts"
  chart      = "raw"
  version    = "2.0.0"

  values = [yamlencode({
    resources = [
      {
        apiVersion = "external-secrets.io/v1beta1"
        kind       = "ClusterSecretStore"
        metadata = {
          name = "aws-secrets-manager"
        }
        spec = {
          provider = {
            aws = {
              service = "SecretsManager"
              region  = data.aws_region.current.name
              auth = {
                jwt = {
                  serviceAccountRef = {
                    name      = "external-secrets"
                    namespace = "external-secrets"
                  }
                }
              }
            }
          }
        }
      },
      {
        apiVersion = "external-secrets.io/v1beta1"
        kind       = "ExternalSecret"
        metadata = {
          name      = "coder-github-oauth"
          namespace = var.coder_namespace
        }
        spec = {
          refreshInterval = "1h"
          secretStoreRef = {
            name = "aws-secrets-manager"
            kind = "ClusterSecretStore"
          }
          target = {
            name = "coder-github-oauth"
          }
          data = [
            {
              secretKey = "client-id"
              remoteRef = {
                key      = "${var.name}/github-oauth"
                property = "client_id"
              }
            },
            {
              secretKey = "client-secret"
              remoteRef = {
                key      = "${var.name}/github-oauth"
                property = "client_secret"
              }
            },
          ]
        }
      }
    ]
  })]

  depends_on = [
    kubernetes_namespace.coder,
    helm_release.external_secrets,
  ]
}

# =============================================================================
# Store DB URL directly as K8s secret (simpler than External Secrets for URL)
# =============================================================================
resource "kubernetes_secret" "coder_postgres" {
  metadata {
    name      = "coder-postgres-url"
    namespace = var.coder_namespace
  }

  data = {
    url = var.db_connection_url
  }

  depends_on = [kubernetes_namespace.coder]
}

# =============================================================================
# Coder Helm Release
# =============================================================================
resource "helm_release" "coder" {
  name       = "coder"
  repository = "https://helm.coder.com/v2"
  chart      = "coder"
  namespace  = var.coder_namespace
  version    = var.coder_version

  values = [yamlencode({
    coder = {
      replicaCount = 3

      annotations = {
        "cluster-autoscaler.kubernetes.io/safe-to-evict" = "false"
      }

      affinity = {
        podAntiAffinity = {
          preferredDuringSchedulingIgnoredDuringExecution = [{
            weight = 100
            podAffinityTerm = {
              topologyKey = "topology.kubernetes.io/zone"
              labelSelector = {
                matchLabels = {
                  "app.kubernetes.io/name" = "coder"
                }
              }
            }
          }]
        }
      }

      serviceAccount = {
        create = true
        name   = "coder"
        annotations = {
          "eks.amazonaws.com/role-arn" = var.coder_role_arn
        }
      }

      # Disable default service - using custom via extraTemplates
      service = {
        enable = false
      }

      # TLS terminates at NLB, not Coder
      tls = {
        secretNames = []
      }

      # Ingress disabled - using NLB Service instead
      ingress = {
        enable = false
      }

      env = [
        {
          name  = "CODER_ACCESS_URL"
          value = "https://${var.domain}"
        },
        {
          name  = "CODER_WILDCARD_ACCESS_URL"
          value = var.wildcard_domain
        },
        # Proxy trust for client IP preservation
        {
          name  = "CODER_PROXY_TRUSTED_HEADERS"
          value = "X-Forwarded-For"
        },
        {
          name  = "CODER_PROXY_TRUSTED_ORIGINS"
          value = "10.0.0.0/8"
        },
        {
          name  = "CODER_DISABLE_PATH_APPS"
          value = "true"
        },
        {
          name  = "CODER_PROMETHEUS_ENABLE"
          value = "true"
        },
        {
          name  = "CODER_PROVISIONER_DAEMONS"
          value = "0"
        },
        # GitHub OAuth
        {
          name  = "CODER_OAUTH2_GITHUB_ALLOW_SIGNUPS"
          value = "true"
        },
        {
          name  = "CODER_OAUTH2_GITHUB_ALLOWED_ORGS"
          value = var.github_allowed_orgs
        },
        {
          name = "CODER_OAUTH2_GITHUB_CLIENT_ID"
          valueFrom = {
            secretKeyRef = {
              name = "coder-github-oauth"
              key  = "client-id"
            }
          }
        },
        {
          name = "CODER_OAUTH2_GITHUB_CLIENT_SECRET"
          valueFrom = {
            secretKeyRef = {
              name = "coder-github-oauth"
              key  = "client-secret"
            }
          }
        },
        # Database
        {
          name = "CODER_PG_CONNECTION_URL"
          valueFrom = {
            secretKeyRef = {
              name = "coder-postgres-url"
              key  = "url"
            }
          }
        },
      ]

      podAnnotations = {
        "prometheus.io/scrape" = "true"
        "prometheus.io/port"   = "2112"
      }
    }
  })]

  wait    = true
  timeout = 900

  depends_on = [
    kubernetes_namespace.coder,
    kubernetes_secret.coder_postgres,
    helm_release.external_secrets_config,
  ]
}

# =============================================================================
# Coder Service (NLB with TLS on port 443)
# =============================================================================
resource "kubernetes_service" "coder" {
  metadata {
    name      = "coder"
    namespace = var.coder_namespace
    labels = {
      "app.kubernetes.io/name"     = "coder"
      "app.kubernetes.io/instance" = "coder"
    }
    annotations = {
      "service.beta.kubernetes.io/aws-load-balancer-scheme"                 = "internet-facing"
      "service.beta.kubernetes.io/aws-load-balancer-nlb-target-type"        = "ip"
      "service.beta.kubernetes.io/aws-load-balancer-ssl-cert"               = var.acm_certificate_arn
      "service.beta.kubernetes.io/aws-load-balancer-ssl-ports"              = "443"
      "service.beta.kubernetes.io/aws-load-balancer-ssl-negotiation-policy" = "ELBSecurityPolicy-TLS13-1-2-2021-06"
      "service.beta.kubernetes.io/aws-load-balancer-healthcheck-protocol"   = "HTTP"
      "service.beta.kubernetes.io/aws-load-balancer-healthcheck-path"       = "/healthz"
      "service.beta.kubernetes.io/aws-load-balancer-healthcheck-port"       = "8080"
    }
  }

  spec {
    type                    = "LoadBalancer"
    load_balancer_class     = "eks.amazonaws.com/nlb"
    session_affinity        = "None"
    external_traffic_policy = "Local"

    selector = {
      "app.kubernetes.io/name"     = "coder"
      "app.kubernetes.io/instance" = "coder"
    }

    port {
      name        = "https"
      port        = 443
      target_port = 8080
      protocol    = "TCP"
    }
  }

  depends_on = [helm_release.coder]
}

# =============================================================================
# Note: Provisioners are deployed separately via coder-config/
# This allows using coderd_provisioner_key instead of static PSK
# =============================================================================
# Route53 DNS Records
# =============================================================================

# Main domain record
resource "aws_route53_record" "coder" {
  zone_id = var.route53_zone_id
  name    = var.domain
  type    = "CNAME"
  ttl     = 300
  records = [kubernetes_service.coder.status[0].load_balancer[0].ingress[0].hostname]
}

# Wildcard record for workspace apps
resource "aws_route53_record" "coder_wildcard" {
  zone_id = var.route53_zone_id
  name    = var.wildcard_domain
  type    = "CNAME"
  ttl     = 300
  records = [kubernetes_service.coder.status[0].load_balancer[0].ingress[0].hostname]
}
