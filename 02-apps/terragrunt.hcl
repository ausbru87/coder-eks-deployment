# Stage 2: Applications
# Deploys Coder and Observability stack to EKS
#
# Depends on: 01-infra

include "root" {
  path = find_in_parent_folders()
}

dependency "infra" {
  config_path = "../01-infra"

  mock_outputs = {
    cluster_name              = "mock-cluster"
    cluster_endpoint          = "https://mock.eks.amazonaws.com"
    cluster_ca_certificate    = "mock-ca-cert"
    vpc_id                    = "vpc-mock"
    public_subnet_ids         = ["subnet-mock1", "subnet-mock2"]
    db_connection_url         = "postgresql://mock:mock@mock:5432/coder"
    db_host                   = "mock.rds.amazonaws.com"
    db_password               = "mock-password"
    coder_role_arn            = "arn:aws:iam::123456789:role/mock"
    external_secrets_role_arn = "arn:aws:iam::123456789:role/mock"
    route53_zone_id           = "Z1234567890"
    acm_certificate_arn       = "arn:aws:acm:us-west-2:123456789:certificate/mock"
    github_oauth_secret_arn   = "arn:aws:secretsmanager:us-west-2:123456789:secret:mock"
  }
}

# No terraform.source block - run in place to preserve relative module paths

inputs = {
  cluster_name              = dependency.infra.outputs.cluster_name
  cluster_endpoint          = dependency.infra.outputs.cluster_endpoint
  cluster_ca_certificate    = dependency.infra.outputs.cluster_ca_certificate
  vpc_id                    = dependency.infra.outputs.vpc_id
  public_subnet_ids         = dependency.infra.outputs.public_subnet_ids
  db_connection_url         = dependency.infra.outputs.db_connection_url
  db_host                   = dependency.infra.outputs.db_host
  db_password               = dependency.infra.outputs.db_password
  coder_role_arn            = dependency.infra.outputs.coder_role_arn
  external_secrets_role_arn = dependency.infra.outputs.external_secrets_role_arn
  route53_zone_id           = dependency.infra.outputs.route53_zone_id
  acm_certificate_arn       = dependency.infra.outputs.acm_certificate_arn
  github_oauth_secret_arn   = dependency.infra.outputs.github_oauth_secret_arn

  # Grafana GitHub OAuth (optional - passed via environment variables)
  grafana_github_oauth_client_id     = get_env("TF_VAR_grafana_github_oauth_client_id", "")
  grafana_github_oauth_client_secret = get_env("TF_VAR_grafana_github_oauth_client_secret", "")
  grafana_github_allowed_orgs        = get_env("TF_VAR_grafana_github_allowed_orgs", "")
}
