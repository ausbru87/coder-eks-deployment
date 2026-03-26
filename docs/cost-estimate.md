# Cost Estimate

Estimated monthly costs for the default deployment configuration.

## Base Infrastructure

| Component | Spec | Est. Cost |
|-----------|------|-----------|
| EKS Control Plane | 1 cluster | $72 |
| EKS Nodes (Auto Mode) | Variable | ~$200-500 |
| RDS | db.t3.small Multi-AZ | ~$50 |
| NAT Gateways | 3x (HA) | ~$100 |
| NLB | 2 (Coder + Grafana) | ~$40 |
| **Base Total** | | **~$500/mo** |

## Variable Costs

| Component | Spec | Est. Cost |
|-----------|------|-----------|
| Workspace Nodes | Variable (depends on user count) | +$100-2000 |

## Cost Notes

- **EKS Auto Mode** adds ~12% management fee on EC2 instance costs for managed nodes. See [EKS Auto Mode Considerations](eks-auto-mode.md#additional-considerations).
- **NAT Gateways** are the largest fixed cost after EKS. For dev/test environments, consider reducing to 1 NAT gateway.
- **RDS Multi-AZ** can be switched to single-AZ for non-production use (~50% savings).
- **Workspace costs** scale linearly with the number of concurrent developers and the instance sizes they use.
