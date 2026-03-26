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
# Create environment file
cp coder-deploy.env.example coder-deploy.env

# Edit with your values
```

**coder-deploy.env:**
```bash
# Environment Name (optional - prefixes all resources)
# export TF_VAR_env_name="myenv"

# Domain Configuration (required)
export TF_VAR_domain="dev.example.com"
export TF_VAR_wildcard_domain="*.dev.example.com"
export TF_VAR_route53_zone_name="example.com"

# GitHub OAuth (required)
export TF_VAR_github_oauth_client_id="your-client-id"
export TF_VAR_github_oauth_client_secret="your-client-secret"
export TF_VAR_github_allowed_orgs="your-github-org"

# Config Phase (set after Coder is running)
export CODER_TOKEN=""

# Optional
export TF_VAR_grafana_domain=""      # e.g., grafana.dev.example.com
export TF_VAR_license_key=""         # Enterprise license
```

### 2. Create State Backend

```bash
./scripts/create-tfstate-backend.sh
source coder-deploy.env  # Re-source to get tfstate vars
```

The script is idempotent and has multiple modes:

| Command | Purpose |
|---------|---------|
| `./scripts/create-tfstate-backend.sh` | Create or validate backend (safe to re-run) |
| `./scripts/create-tfstate-backend.sh --reset` | Clean orphaned resources + empty state (keeps bucket/table) |
| `./scripts/create-tfstate-backend.sh --full-reset` | Reset + recreate backend from scratch (new bucket name) |
| `./scripts/create-tfstate-backend.sh --destroy` | Complete teardown of backend |

**When to use `--reset`:**
- Deployment interrupted (Ctrl+C)
- State corruption or conflicts
- Orphaned AWS resources causing errors

**What `--reset` does:**
- Deletes orphaned Secrets Manager secrets
- Deletes orphaned IAM roles and policies
- Deletes orphaned RDS parameter groups and subnet groups
- Cleans all terraform caches (`.terraform`, `.terragrunt-cache`)
- Empties S3 state bucket (including all versioned objects)
- Clears DynamoDB lock table (removes stale checksums)
- Preserves bucket and DynamoDB table for reuse

### 3. Deploy All

```bash
source coder-deploy.env
terragrunt run --all --non-interactive -- apply 2>&1 | tee terragrunt-$(date +%Y%m%d-%H%M%S).out
```

This logs output to both terminal and a timestamped file. Monitor progress in another terminal:

```bash
tail -f terragrunt-*.out
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

> **Note:** DNS propagation typically takes **2-5 minutes** after deployment. If you can't reach Coder immediately:
> - Wait 2-5 minutes and try again
> - Verify DNS propagation: `dig @8.8.8.8 dev.example.com +short`
> - Flush local DNS cache: `sudo dscacheutil -flushcache && sudo killall -HUP mDNSResponder` (macOS)
> - Access directly via NLB hostname: `kubectl get svc -n coder coder -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'`

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

## Deployment Stages

| Stage | Directory | Resources |
|-------|-----------|-----------|
| 01-infra | `01-infra/` | Secrets, ACM, VPC, EKS, RDS, IAM, ESO |
| 02-apps | `02-apps/` | Coder Helm, Observability |
| 03-day2 | `03-day2/` | License, provisioner key, external provisioners |

### Dependency Graph

```
01-infra → 02-apps → 03-day2
                                      ↑
                              (requires CODER_TOKEN)
```

## Directory Structure

```
.
├── terragrunt.hcl           # Root config: backend, common settings
├── scripts/
│   └── create-tfstate-backend.sh  # Creates S3 + DynamoDB for state
├── 01-infra/                # Stage 1: All infrastructure
│   ├── main.tf
│   └── terragrunt.hcl
├── 02-apps/                 # Stage 2: Applications
│   ├── main.tf
│   └── terragrunt.hcl
├── 03-day2/                 # Stage 3: Post-deployment config
│   ├── main.tf
│   └── terragrunt.hcl
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
└── coder-deploy.env.example
```

## Namespaces

| Namespace | Contents |
|-----------|----------|
| `coder` | Coder server, provisioners |
| `coder-workspaces` | Kubernetes workspace pods |
| `coder-observability` | Grafana, Prometheus, Loki |
| `external-secrets` | External Secrets Operator |

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

## EKS Auto Mode Considerations

This deployment uses [EKS Auto Mode](https://docs.aws.amazon.com/eks/latest/userguide/automode.html) by default, which automates compute, storage, and networking management. While this significantly reduces operational overhead, there are trade-offs to understand.

### Docker-in-Docker (envbox / Sysbox)

**Status: Not supported on Auto Mode nodes.**

EKS Auto Mode exclusively uses [Bottlerocket](https://bottlerocket.dev/) AMIs, which are locked-down, immutable, container-optimized OS images. This creates incompatibilities with [envbox](https://github.com/coder/envbox) and the [Sysbox](https://github.com/nestybox/sysbox) container runtime:

- **No custom AMIs**: Auto Mode does not allow custom AMI selection. Sysbox requires installation on the host OS, which is not possible on Bottlerocket's read-only root filesystem.
- **SELinux enforcing**: Bottlerocket runs SELinux in enforcing mode, which may block the privileged operations Sysbox requires.
- **No SSH/SSM access**: Auto Mode nodes are fully managed appliances with no shell or SSH access for installing host-level software.
- **User namespaces disabled**: Bottlerocket sets `user.max_user_namespaces = 0` by default, which breaks rootless container runtimes like Podman and Sysbox.

**Workarounds:**

| Approach | Description |
|----------|-------------|
| **Managed Node Group** (recommended) | Set `auto_mode = false` and deploy a managed node group with Amazon Linux 2023 or Ubuntu AMIs where Sysbox can be installed. See [Standard Nodes](#standard-nodes-alternative). |
| **EC2 workspaces** | Use the included `ec2` template for workspaces that need Docker, keeping Kubernetes workspaces for lighter use cases. |
| **Privileged DinD sidecar** | Run a privileged Docker-in-Docker sidecar container. **Not recommended** — this grants root access to the host. |

### Control Plane Isolation

**Status: Supported via NodePools.**

EKS Auto Mode provides workload isolation through [NodePools](https://docs.aws.amazon.com/eks/latest/userguide/create-node-pool.html):

- The built-in **`system`** NodePool runs with a `CriticalAddonsOnly` taint, ensuring only essential add-ons (CoreDNS, metrics-server) are scheduled there.
- The built-in **`general-purpose`** NodePool handles regular workloads including Coder server pods and workspace pods.

To isolate workspaces from the Coder control plane (`coderd`), create a **custom NodePool** dedicated to workspaces:

```yaml
# workspace-nodepool.yaml
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: coder-workspaces
spec:
  template:
    metadata:
      labels:
        coder.com/workspaces: "true"
    spec:
      nodeClassRef:
        group: eks.amazonaws.com
        kind: NodeClass
        name: default
      taints:
        - key: "coder.com/workspaces"
          value: "true"
          effect: NoSchedule
      requirements:
        - key: "eks.amazonaws.com/instance-category"
          operator: In
          values: ["c", "m", "r"]
        - key: "eks.amazonaws.com/instance-cpu"
          operator: In
          values: ["4", "8", "16", "32"]
        - key: "kubernetes.io/arch"
          operator: In
          values: ["amd64"]
  limits:
    cpu: "512"
    memory: "1024Gi"
  disruption:
    consolidationPolicy: WhenEmptyOrUnderutilized
    consolidateAfter: 60s
```

Then update your Kubernetes workspace template to target these nodes:

```hcl
node_selector = {
  "coder.com/workspaces" = "true"
}
toleration {
  key      = "coder.com/workspaces"
  operator = "Equal"
  value    = "true"
  effect   = "NoSchedule"
}
```

This ensures a workspace pod cannot starve or disrupt the Coder server, and vice versa.

### Node Provisioning Latency

**Status: Expect 1–3 minutes for cold starts.**

EKS Auto Mode starts with zero data-plane nodes and provisions EC2 instances on demand via Karpenter. When a workspace pod is created and no suitable node exists, the sequence is:

1. Karpenter detects the unschedulable pod (~seconds)
2. EC2 instance is launched (~30–60s)
3. Bottlerocket boots and joins the cluster (~30–60s)
4. Pod is scheduled and container image is pulled

**Total cold-start time: ~1–3 minutes** (longer if a large container image needs pulling).

**Mitigation strategies:**

| Strategy | Description |
|----------|-------------|
| **Warm pool with placeholder pods** | Deploy low-priority "pause" pods that hold nodes warm. When a real workspace arrives, Kubernetes preempts the placeholder. |
| **Pre-cache images** | Use a DaemonSet to pre-pull workspace images on nodes, reducing image pull time. |
| **Reduce `consolidateAfter`** | Increase the delay before empty nodes are terminated (default: 60s) so nodes from recently stopped workspaces remain available. |
| **Larger instance types** | Fewer, larger nodes can host multiple workspaces, reducing the chance of needing a new node. |
| **EC2 capacity reservations** | Use [On-Demand Capacity Reservations](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-capacity-reservations.html) to guarantee instance availability during peak hours. |

Example warm-pool placeholder:

```yaml
# warm-pool.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: workspace-warm-pool
  namespace: coder-workspaces
spec:
  replicas: 2  # Keep 2 nodes warm
  selector:
    matchLabels:
      app: warm-pool
  template:
    metadata:
      labels:
        app: warm-pool
    spec:
      priorityClassName: low-priority
      nodeSelector:
        coder.com/workspaces: "true"
      tolerations:
        - key: "coder.com/workspaces"
          operator: "Equal"
          value: "true"
          effect: "NoSchedule"
      containers:
        - name: pause
          image: registry.k8s.io/pause:3.9
          resources:
            requests:
              cpu: "3500m"
              memory: "7Gi"
---
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: low-priority
value: -1
globalDefault: false
description: "Low priority for warm-pool placeholders"
```

### Additional Considerations

| Consideration | Detail |
|---------------|--------|
| **Cost premium** | Auto Mode adds ~12% management fee on EC2 instance costs. No Savings Plans, Reserved Instances, or Spot discounts apply to this fee. |
| **Max pod count** | Auto Mode nodes are capped at 110 pods per node (vs. ~234 on standard AL2 nodes), which may require more nodes for dense workloads. |
| **Node max lifetime** | Nodes are automatically replaced after 21 days. Workspace PVCs persist, but in-memory state is lost. Ensure workspaces use persistent storage. |
| **No node SSH** | You cannot SSH into Auto Mode nodes for debugging. Use `kubectl debug` or CloudWatch logs instead. |

## Standard Nodes Alternative

If your workloads require Docker-in-Docker (envbox/Sysbox), custom AMIs, or other features incompatible with Auto Mode, you can deploy with standard managed node groups instead.

Set in your `coder-deploy.env`:

```bash
export TF_VAR_auto_mode=false
```

When `auto_mode = false`, the EKS module deploys:
- A managed node group with Amazon Linux 2023 AMIs
- Cluster Autoscaler or Karpenter (self-managed) for scaling
- Standard EBS CSI driver and AWS Load Balancer Controller as add-ons

> **Note:** Standard nodes require additional operational effort for AMI updates, scaling configuration, and add-on management. See the [EKS Best Practices Guide](https://docs.aws.amazon.com/eks/latest/best-practices/) for recommendations.

## Cost Estimate (Monthly)

| Component | Spec | Est. Cost |
|-----------|------|-----------|
| EKS Control Plane | 1 cluster | $72 |
| EKS Nodes (Auto Mode) | Variable | ~$200-500 |
| RDS | db.t3.small Multi-AZ | ~$50 |
| NAT Gateways | 3x (HA) | ~$100 |
| NLB | 2 (Coder + Grafana) | ~$40 |
| **Base Total** | | **~$500/mo** |
| Workspace Nodes | Variable | +$100-2000 |

## Maintenance

### Upgrade Coder

```bash
# Update coder_version in 02-apps/main.tf, then:
source coder-deploy.env
cd 02-apps && terragrunt apply
```

### Backup Before Upgrade

```bash
aws rds create-db-snapshot \
  --db-instance-identifier coder-demo-postgres \
  --db-snapshot-identifier coder-pre-upgrade-$(date +%Y%m%d)
```

### Destroy Everything

```bash
source coder-deploy.env

# Destroy in reverse dependency order
terragrunt run --all --non-interactive -- destroy

# Or manually in reverse:
cd 03-day2 && terragrunt destroy
cd 02-apps && terragrunt destroy
cd 01-infra && terragrunt destroy

# Then remove state backend:
./scripts/create-tfstate-backend.sh --destroy
```

## Troubleshooting

### Recovery from Interrupted Deployment

If deployment fails or is interrupted (Ctrl+C):

```bash
# Option 1: Clean and retry (recommended)
./scripts/create-tfstate-backend.sh --reset
source coder-deploy.env
terragrunt run --all --non-interactive -- apply 2>&1 | tee terragrunt-$(date +%Y%m%d-%H%M%S).out

# Option 2: Nuclear reset (if option 1 doesn't work)
./scripts/create-tfstate-backend.sh --full-reset
source coder-deploy.env
terragrunt run --all --non-interactive -- apply 2>&1 | tee terragrunt-$(date +%Y%m%d-%H%M%S).out
```

**Common errors after interrupted deployments:**
- `ResourceExistsException: secret already exists` → Use `--reset`
- `EntityAlreadyExists: Role already exists` → Use `--reset`
- `BucketAlreadyOwnedByYou` → Backend script handles this automatically

### Check Coder Status

```bash
kubectl get pods -n coder
kubectl logs -n coder deployment/coder --tail=100
curl https://dev.example.com/healthz
```

### Check Provisioners

```bash
kubectl get pods -n coder -l app.kubernetes.io/name=coder-provisioner
kubectl logs -n coder deployment/coder-provisioner --tail=100
```

### Check Observability

```bash
kubectl get pods -n coder-observability

# Port-forward if NLB not configured
kubectl port-forward -n coder-observability svc/grafana 3000:80
```

### Certificate Issues

```bash
# Check ACM status
aws acm describe-certificate \
  --certificate-arn $(cd 01-infra && terragrunt output -raw acm_certificate_arn) \
  --query 'Certificate.Status'

# Check DNS validation records
aws route53 list-resource-record-sets \
  --hosted-zone-id $(cd 01-infra && terragrunt output -raw route53_zone_id) \
  --query "ResourceRecordSets[?Type=='CNAME']"
```

## Environment Variables Reference

All configuration is via `coder-deploy.env` using `TF_VAR_*` exports:

| Variable | Required | Description |
|----------|----------|-------------|
| `TF_VAR_domain` | Yes | Coder URL (e.g., `dev.example.com`) |
| `TF_VAR_wildcard_domain` | Yes | Workspace apps (e.g., `*.dev.example.com`) |
| `TF_VAR_route53_zone_name` | Yes | Route53 zone (e.g., `example.com`) |
| `TF_VAR_github_oauth_client_id` | Yes | GitHub OAuth client ID |
| `TF_VAR_github_oauth_client_secret` | Yes | GitHub OAuth client secret |
| `TF_VAR_github_allowed_orgs` | Yes | GitHub org for login |
| `CODER_TOKEN` | Stage 4 | API token for provisioner setup |
| `TF_VAR_grafana_domain` | No | External Grafana URL |
| `TF_VAR_license_key` | No | Enterprise license |


