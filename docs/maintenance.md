# Maintenance

## Upgrade Coder

```bash
# Update coder_version in 02-apps/main.tf, then:
source coder-deploy.env
cd 02-apps && terragrunt apply
```

## Backup Before Upgrade

```bash
aws rds create-db-snapshot \
  --db-instance-identifier coder-demo-postgres \
  --db-snapshot-identifier coder-pre-upgrade-$(date +%Y%m%d)
```

## Destroy Everything

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

> **Note:** Secrets Manager secrets use a 7-day recovery window. After `terraform destroy`,
> secrets enter a "pending deletion" state for 7 days. If you re-deploy with the same
> `env_name` within that window, Terraform will fail because the secret names are still
> reserved. To force immediate deletion, use:
> ```bash
> aws secretsmanager delete-secret --secret-id "<secret-name>" --force-delete-without-recovery
> ```
