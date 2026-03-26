# Environment Variables Reference

All configuration is via `coder-deploy.env` using `TF_VAR_*` exports.

See [`coder-deploy.env.example`](../coder-deploy.env.example) for a starting point.

## Required Variables

| Variable | Description |
|----------|-------------|
| `TF_VAR_domain` | Coder URL (e.g., `dev.example.com`) |
| `TF_VAR_wildcard_domain` | Workspace apps (e.g., `*.dev.example.com`) |
| `TF_VAR_route53_zone_name` | Route53 zone (e.g., `example.com`) |
| `TF_VAR_github_oauth_client_id` | GitHub OAuth client ID |
| `TF_VAR_github_oauth_client_secret` | GitHub OAuth client secret |
| `TF_VAR_github_allowed_orgs` | GitHub org for login |

## Day 2 Variables

| Variable | Description |
|----------|-------------|
| `CODER_TOKEN` | API token for provisioner setup (set after creating admin user) |

## Optional Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `TF_VAR_env_name` | `""` | Environment prefix for all resources (e.g., `myenv`) |
| `TF_VAR_region` | `us-west-2` | AWS region |
| `TF_VAR_auto_mode` | `true` | EKS Auto Mode. Set `false` for managed node groups (required for envbox/Sysbox). |
| `TF_VAR_grafana_domain` | `""` | External Grafana URL (empty = no external access) |
| `TF_VAR_license_key` | `""` | Enterprise license key |
| `TF_VAR_grafana_github_oauth_client_id` | `""` | GitHub OAuth client ID for Grafana SSO |
| `TF_VAR_grafana_github_oauth_client_secret` | `""` | GitHub OAuth client secret for Grafana SSO |
| `TF_VAR_grafana_github_allowed_orgs` | `""` | GitHub orgs allowed to access Grafana |
