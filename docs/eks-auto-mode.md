# EKS Auto Mode Considerations

This deployment uses [EKS Auto Mode](https://docs.aws.amazon.com/eks/latest/userguide/automode.html) by default, which automates compute, storage, and networking management. While this significantly reduces operational overhead, there are trade-offs to understand.

## Docker-in-Docker (envbox / Sysbox)

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

## Control Plane Isolation

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

## Node Provisioning Latency

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

## Additional Considerations

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
