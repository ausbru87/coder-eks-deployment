# Observability

This deployment includes a pre-configured observability stack in the `coder-observability` namespace.

## Components

| Component | Purpose |
|-----------|---------|
| **Grafana** | Dashboards and visualization |
| **Prometheus** | Metrics collection and alerting |
| **Loki** | Log aggregation |

## Accessing Grafana

If a Grafana domain is configured (`TF_VAR_grafana_domain`), Grafana is accessible via NLB at that domain.

Otherwise, use port-forwarding:

```bash
kubectl port-forward -n coder-observability svc/grafana 3000:80
```

## Grafana GitHub SSO (Optional)

To secure Grafana with GitHub OAuth (recommended for production):

### 1. Create a GitHub OAuth App

- Go to [GitHub Developer Settings](https://github.com/settings/developers) → "New OAuth App"
- **Application name:** `Grafana - <environment>`
- **Homepage URL:** `https://<grafana_domain>`
- **Authorization callback URL:** `https://<grafana_domain>/login/github`

### 2. Configure Credentials

Add to `coder-deploy.env`:

```bash
export TF_VAR_grafana_github_oauth_client_id="Ov23li..."
export TF_VAR_grafana_github_oauth_client_secret="..."
export TF_VAR_grafana_github_allowed_orgs="coder"  # restrict to org members
```

### 3. Deploy (or Re-deploy)

```bash
source coder-deploy.env
cd 02-apps && terragrunt apply
```

Users must be members of the specified GitHub organization(s) to access Grafana.

> **Note:** If `TF_VAR_grafana_github_oauth_client_id` is empty, Grafana defaults to
> anonymous access (not recommended for production).

## Checking Status

```bash
kubectl get pods -n coder-observability
```
