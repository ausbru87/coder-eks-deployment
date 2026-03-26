# Troubleshooting

## Recovery from Interrupted Deployment

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

## Check Coder Status

```bash
kubectl get pods -n coder
kubectl logs -n coder deployment/coder --tail=100
curl https://dev.example.com/healthz
```

## Check Provisioners

```bash
kubectl get pods -n coder -l app.kubernetes.io/name=coder-provisioner
kubectl logs -n coder deployment/coder-provisioner --tail=100
```

## Check Observability

```bash
kubectl get pods -n coder-observability

# Port-forward if NLB not configured
kubectl port-forward -n coder-observability svc/grafana 3000:80
```

## Certificate Issues

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
