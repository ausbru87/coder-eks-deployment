# Scaling

## Default Architecture: Up to ~500 Users

The default configuration is designed for **small to mid-size teams of up to ~500 users** (assuming ~30% daily active). It aligns roughly with [Coder's validated 1K-user architecture](https://coder.com/docs/admin/infrastructure/validated-architectures/1k-users), though with a smaller RDS instance and burstable workspace defaults that limit the practical ceiling.

The default `db.m6i.large` (2 vCPU, 8 GiB RAM, non-burstable) aligns with Coder's validated architecture for deployments under 1,000 users.

### Default Component Sizing

| Component | Default | Capacity Impact |
|-----------|---------|----------------|
| **Coder replicas** | 3 (zone-spread) | Handles API/dashboard/DERP proxy; ~1 vCPU per 250 users |
| **Provisioner replicas** | 5 (external) | 5 concurrent workspace builds |
| **RDS** | `db.m6i.large`, 20–100 GB, Multi-AZ | Non-burstable; consistent performance under load |
| **EKS** | Auto Mode (auto-scaling nodes) | No fixed node count; scales with pod demand |
| **VPC** | /16 CIDR, 3 AZs, 3 NAT GWs | Supports thousands of pod IPs |
| **Observability** | Loki SingleBinary (1 replica) | Demo-grade log storage; not distributed |
| **K8s workspaces** | 4 CPU, 8 GB RAM, 20 GB disk (default) | 2–16 CPU, 4–32 GB selectable |
| **EC2 workspaces** | `t3.xlarge` (4 vCPU/16 GB), 50 GB disk | `t3.large` through `m6i.4xlarge` selectable |

## Scaling Down (~50 Users or Less)

For small teams, evaluation, or cost-sensitive deployments:

| Setting | Default | Smaller Scale | Where to Change |
|---------|---------|--------------|----------------|
| Coder replicas | 3 | 1 | `modules/coder/main.tf` → `replicaCount` |
| Provisioner replicas | 5 | 2 | `03-day2/main.tf` → `var.provisioner_replicas` |
| RDS instance class | `db.m6i.large` | `db.t3.small` | `modules/rds/main.tf` → `var.instance_class` |
| RDS Multi-AZ | `true` | `false` | `modules/rds/main.tf` → `multi_az` |
| NAT Gateways | 3 (one per AZ) | 1 | `modules/vpc/main.tf` → use `single_nat_gateway` |
| K8s workspace CPU | 4 cores | 2 cores | `templates/kubernetes/main.tf` → default option |
| K8s workspace memory | 8 GB | 4 GB | `templates/kubernetes/main.tf` → default option |
| EC2 workspace type | `t3.xlarge` | `t3.large` | `templates/ec2/main.tf` → default option |

**Estimated monthly cost for a small-scale deployment: ~$250–350** (vs ~$500+ at default).

## Scaling Up (~1,000+ Users)

For larger teams, follow [Coder's validated architectures](https://coder.com/docs/admin/infrastructure/validated-architectures):

| Setting | Default | 1K Users | 2K+ Users | Where to Change |
|---------|---------|----------|-----------|----------------|
| Coder replicas | 3 | 3 | 4+ | `modules/coder/main.tf` → `replicaCount` |
| Provisioner replicas | 5 | 10 | 20+ | `03-day2/main.tf` → `var.provisioner_replicas` |
| RDS instance class | `db.m6i.large` | `db.m6i.large` | `db.m6i.xlarge` | `modules/rds/main.tf` → `var.instance_class` |
| RDS storage | 20 GB | 100 GB | 500 GB+ | `modules/rds/main.tf` → `var.allocated_storage` |
| Loki | SingleBinary | S3-backed distributed | S3-backed distributed | `modules/observability/main.tf` |
| Workspace types | `t3.*` (burstable) | `m6i.*` / `c6i.*` | `m6i.*` / `c6i.*` | `templates/ec2/main.tf` |

**Key recommendations at scale:**
- Use **non-burstable** instance types (`m6i`, `c6i`, `r6i`) for RDS and EC2 workspaces. Burstable `t3` instances can degrade significantly once CPU credits are exhausted.
- Each external provisioner handles **one concurrent workspace build**. Size the replica count to your expected peak concurrent builds (e.g., morning startup surge).
- Coder Server sizing rule of thumb: **1 vCPU + 2 GB RAM per 250 users**.
- Database sizing rule of thumb: **2 vCPU + 8 GB RAM** as baseline, then **+2 vCPU per 1,000 active users**.
- **Do not autoscale** Coder Server replicas — scale for peak weekly usage during a maintenance window instead.

See also: [Coder Scaling Best Practices](https://coder.com/docs/tutorials/best-practices/scale-coder) | [Scale Testing](https://coder.com/docs/admin/infrastructure/scale-testing)
