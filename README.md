# AWS Deployment

Production-ready Coder deployment on AWS with EKS, RDS, and full observability.

## Features

- **EKS Auto Mode** - Automatic compute, storage, and networking
- **HA Coder** - 3 replicas with external provisioners
- **NLB + TLS** - ACM certificate with automatic DNS validation
- **RDS PostgreSQL 17** - Multi-AZ for high availability
- **Observability** - Grafana, Prometheus, Loki pre-configured
- **Workspaces** - Kubernetes pods + EC2 instances
- **IRSA** - Secure AWS API access via IAM Roles for Service Accounts
- **Terragrunt** - Dependency-managed multi-stage deployment

## Prerequisites

- AWS CLI configured with appropriate permissions
- Terraform >= 1.5.0
- **Terragrunt >= 0.50.0**
- Route53 hosted zone for your domain
- GitHub OAuth App (for authentication)

## Quick Start

### 1. Configure Environment

```bash
cp coder-deploy.env.example coder-deploy.env
# Edit coder-deploy.env with your values
```

See [Environment Variables Reference](docs/environment-variables.md) for all options.

### 2. Create State Backend

```bash
./scripts/create-tfstate-backend.sh
source coder-deploy.env  # Re-source to get tfstate vars
```

The script is idempotent. Use `--reset` to recover from interrupted deployments, or `--destroy` to tear down the backend. See [Troubleshooting](docs/troubleshooting.md) for details.

### 3. Deploy All

```bash
source coder-deploy.env
terragrunt run --all --non-interactive -- apply 2>&1 | tee terragrunt-$(date +%Y%m%d-%H%M%S).out
```

> **Timeline:** Full deployment takes ~20-40 minutes. EKS cluster creation (8-12 min) and ACM certificate validation (5-30 min) are the longest steps.

<details>
<summary>Deploy stages individually (alternative)</summary>

```bash
cd 01-infra && terragrunt apply -auto-approve
cd 02-apps && terragrunt apply -auto-approve
# 03-day2 auto-skipped without CODER_TOKEN
```

</details>

<details>
<summary>Terragrunt CLI Reference</summary>

This repo uses the new Terragrunt CLI syntax (v0.50+):

| Old | New |
|-----|-----|
| `terragrunt run-all apply` | `terragrunt run --all -- apply` |
| `--terragrunt-non-interactive` | `--non-interactive` |

Key points:
- `run --all` automatically adds `-auto-approve` (stdin unavailable for per-module prompts)
- `--non-interactive` suppresses external dependency prompts
- Set `TF_INPUT=false` in your env to prevent Terraform input prompts

See: [CLI Redesign](https://terragrunt.gruntwork.io/docs/migrate/cli-redesign/) | [run command](https://terragrunt.gruntwork.io/docs/reference/cli/commands/run)

</details>

### 4. Create Admin User

After 02-apps completes, Coder is running:

```bash
# Configure kubectl
aws eks update-kubeconfig --region us-west-2 --name coder-demo

# Open Coder and create first user via GitHub OAuth
open https://dev.example.com

# Login via CLI
coder login https://dev.example.com
```

> **Note:** DNS propagation typically takes **2-5 minutes** after deployment. If you can't reach Coder immediately, wait and retry. Check with: `dig @8.8.8.8 dev.example.com +short`

### 5. Deploy Day 2 (Provisioners)

After creating admin user, generate token and deploy provisioners:

```bash
# Generate API token
coder tokens create --lifetime 8760h

# Set token and re-run (now includes 03-day2)
export CODER_TOKEN="<your-token>"
terragrunt run --all --non-interactive -- apply
```

### 6. Push Templates

```bash
cd templates/kubernetes
coder templates push kubernetes

cd ../ec2
coder templates push ec2
```

## Architecture

### Deployment Stages

| Stage | Directory | Resources |
|-------|-----------|-----------|
| 01-infra | `01-infra/` | Secrets, ACM, VPC, EKS, RDS, IAM, ESO |
| 02-apps | `02-apps/` | Coder Helm, Observability |
| 03-day2 | `03-day2/` | License, provisioner key, external provisioners |

```
01-infra → 02-apps → 03-day2
                        ↑
                (requires CODER_TOKEN)
```

### Directory Structure

```
.
├── terragrunt.hcl           # Root config: backend, common settings
├── scripts/
│   └── create-tfstate-backend.sh  # Creates S3 + DynamoDB for state
├── 01-infra/                # Stage 1: All infrastructure
├── 02-apps/                 # Stage 2: Applications
├── 03-day2/                 # Stage 3: Post-deployment config
├── modules/
│   ├── vpc/                 # VPC, subnets, NAT gateways
│   ├── eks/                 # EKS cluster with Auto Mode
│   ├── rds/                 # PostgreSQL Multi-AZ
│   ├── iam/                 # IRSA roles
│   ├── coder/               # Coder Helm + supporting resources
│   └── observability/       # Grafana, Prometheus, Loki
├── templates/               # Workspace templates
│   ├── kubernetes/
│   └── ec2/
├── docs/                    # Detailed documentation
└── coder-deploy.env.example
```

### Namespaces

| Namespace | Contents |
|-----------|----------|
| `coder` | Coder server, provisioners |
| `coder-workspaces` | Kubernetes workspace pods |
| `coder-observability` | Grafana, Prometheus, Loki |
| `external-secrets` | External Secrets Operator |

## Documentation

| Topic | Link |
|-------|------|
| EKS Auto Mode trade-offs, DinD, isolation, latency | [docs/eks-auto-mode.md](docs/eks-auto-mode.md) |
| Observability stack and Grafana SSO | [docs/observability.md](docs/observability.md) |
| Cost breakdown | [docs/cost-estimate.md](docs/cost-estimate.md) |
| Upgrades, backups, teardown | [docs/maintenance.md](docs/maintenance.md) |
| Recovery and diagnostics | [docs/troubleshooting.md](docs/troubleshooting.md) |
| All configuration variables | [docs/environment-variables.md](docs/environment-variables.md) |
