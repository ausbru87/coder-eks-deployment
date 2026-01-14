#!/bin/bash
# Creates or destroys S3 bucket and DynamoDB table for Terraform state
#
# Usage:
#   ./scripts/create-tfstate-backend.sh            # Create backend
#   ./scripts/create-tfstate-backend.sh --destroy  # Remove backend
#   ./scripts/create-tfstate-backend.sh --reset    # Clean orphaned resources + terraform caches
#   ./scripts/create-tfstate-backend.sh --full-reset  # Reset + recreate backend from scratch
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/../coder-deploy.env"

# Source env for region and env_name
if [ -f "$ENV_FILE" ]; then
  source "$ENV_FILE"
else
  echo "❌ Missing coder-deploy.env. Create from example first."
  exit 1
fi

REGION="${TF_VAR_region:-us-west-2}"
# Build name same as Terraform: env_name-coder or just coder
if [ -n "$TF_VAR_env_name" ]; then
  NAME_PREFIX="${TF_VAR_env_name}-coder"
else
  NAME_PREFIX="coder"
fi

# Cleanup function - removes orphaned AWS resources and terraform caches
cleanup_orphaned_resources() {
  echo "🧹 Cleaning up orphaned AWS resources..."

  # Clean up Secrets Manager secrets
  echo "  → Deleting Secrets Manager secrets"
  aws secretsmanager delete-secret \
    --secret-id "${NAME_PREFIX}/db-credentials" \
    --force-delete-without-recovery \
    --region "$REGION" 2>/dev/null || true

  aws secretsmanager delete-secret \
    --secret-id "${NAME_PREFIX}/github-oauth" \
    --force-delete-without-recovery \
    --region "$REGION" 2>/dev/null || true

  # Clean up IAM roles
  echo "  → Deleting IAM roles and policies"

  # EKS cluster role
  for policy in $(aws iam list-attached-role-policies --role-name "${NAME_PREFIX}-eks-cluster" --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null); do
    aws iam detach-role-policy --role-name "${NAME_PREFIX}-eks-cluster" --policy-arn "$policy" 2>/dev/null || true
  done
  aws iam delete-role --role-name "${NAME_PREFIX}-eks-cluster" 2>/dev/null || true

  # EKS node role
  for policy in $(aws iam list-attached-role-policies --role-name "${NAME_PREFIX}-eks-node" --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null); do
    aws iam detach-role-policy --role-name "${NAME_PREFIX}-eks-node" --policy-arn "$policy" 2>/dev/null || true
  done
  aws iam delete-role --role-name "${NAME_PREFIX}-eks-node" 2>/dev/null || true

  # Coder IRSA role
  for policy in $(aws iam list-attached-role-policies --role-name "${NAME_PREFIX}-coder" --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null); do
    aws iam detach-role-policy --role-name "${NAME_PREFIX}-coder" --policy-arn "$policy" 2>/dev/null || true
  done
  aws iam delete-role --role-name "${NAME_PREFIX}-coder" 2>/dev/null || true

  # External Secrets IRSA role
  for policy in $(aws iam list-attached-role-policies --role-name "${NAME_PREFIX}-external-secrets" --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null); do
    aws iam detach-role-policy --role-name "${NAME_PREFIX}-external-secrets" --policy-arn "$policy" 2>/dev/null || true
  done
  aws iam delete-role --role-name "${NAME_PREFIX}-external-secrets" 2>/dev/null || true

  # ALB controller policy
  ALB_POLICY_ARN=$(aws iam list-policies --scope Local --query "Policies[?PolicyName=='${NAME_PREFIX}-alb-controller'].Arn" --output text 2>/dev/null)
  if [ -n "$ALB_POLICY_ARN" ]; then
    aws iam delete-policy --policy-arn "$ALB_POLICY_ARN" 2>/dev/null || true
  fi

  # External Secrets policy
  ESO_POLICY_ARN=$(aws iam list-policies --scope Local --query "Policies[?PolicyName=='${NAME_PREFIX}-external-secrets'].Arn" --output text 2>/dev/null)
  if [ -n "$ESO_POLICY_ARN" ]; then
    aws iam delete-policy --policy-arn "$ESO_POLICY_ARN" 2>/dev/null || true
  fi

  # Clean up RDS resources
  echo "  → Deleting RDS parameter groups and subnet groups"

  # Delete parameter group
  aws rds delete-db-parameter-group \
    --db-parameter-group-name "${NAME_PREFIX}-postgres17" \
    --region "$REGION" 2>/dev/null || true

  # Delete DB subnet group
  aws rds delete-db-subnet-group \
    --db-subnet-group-name "${NAME_PREFIX}" \
    --region "$REGION" 2>/dev/null || true

  echo "✅ Orphaned AWS resources cleaned up"
}

# Cleanup terraform caches
cleanup_terraform_caches() {
  echo "🧹 Cleaning up Terraform caches..."

  cd "$SCRIPT_DIR/.."

  # Remove root level terraform artifacts
  rm -rf .terraform .terraform.lock.hcl backend.tf provider.tf 2>/dev/null || true

  # Remove stage-specific terraform artifacts
  for stage in 01-infra 02-apps 03-day2; do
    if [ -d "$stage" ]; then
      echo "  → Cleaning $stage"
      rm -rf "$stage/.terraform" "$stage/.terraform.lock.hcl" "$stage/.terragrunt-cache" \
             "$stage/backend.tf" "$stage/provider.tf" 2>/dev/null || true
    fi
  done

  echo "✅ Terraform caches cleaned up"
}

# Empty S3 state bucket
empty_state_bucket() {
  local bucket_name="$1"

  echo "🗑️  Emptying S3 state bucket: $bucket_name"

  # Delete all objects
  aws s3 rm "s3://$bucket_name" --recursive --region "$REGION" 2>/dev/null || true

  # Delete versioned objects
  aws s3api list-object-versions --bucket "$bucket_name" --region "$REGION" \
    --query 'Versions[].{Key:Key,VersionId:VersionId}' --output json 2>/dev/null | \
    jq -r '.[] | "--key \"\(.Key)\" --version-id \(.VersionId)"' | \
    xargs -L1 -I{} sh -c "aws s3api delete-object --bucket $bucket_name --region $REGION {} 2>/dev/null" || true

  # Delete markers
  aws s3api list-object-versions --bucket "$bucket_name" --region "$REGION" \
    --query 'DeleteMarkers[].{Key:Key,VersionId:VersionId}' --output json 2>/dev/null | \
    jq -r '.[] | "--key \"\(.Key)\" --version-id \(.VersionId)"' | \
    xargs -L1 -I{} sh -c "aws s3api delete-object --bucket $bucket_name --region $REGION {} 2>/dev/null" || true

  echo "✅ State bucket emptied"
}

# Clear DynamoDB lock table entries
clear_dynamodb_locks() {
  local table_name="$1"

  echo "🗑️  Clearing DynamoDB lock table: $table_name"

  # Get all lock IDs and delete them
  aws dynamodb scan --table-name "$table_name" --region "$REGION" \
    --query 'Items[*].LockID.S' --output text 2>/dev/null | \
    tr '\t' '\n' | while read lockid; do
      if [ -n "$lockid" ]; then
        aws dynamodb delete-item \
          --table-name "$table_name" \
          --key "{\"LockID\":{\"S\":\"$lockid\"}}" \
          --region "$REGION" 2>/dev/null || true
      fi
    done

  echo "✅ DynamoDB lock table cleared"
}

# Configure existing S3 bucket with proper settings
configure_bucket() {
  local bucket_name="$1"

  echo "⚙️  Configuring S3 bucket: $bucket_name"

  aws s3api put-bucket-versioning \
    --bucket "$bucket_name" \
    --versioning-configuration Status=Enabled \
    --region "$REGION" 2>/dev/null || true

  aws s3api put-bucket-encryption \
    --bucket "$bucket_name" \
    --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}' \
    --region "$REGION" 2>/dev/null || true

  aws s3api put-public-access-block \
    --bucket "$bucket_name" \
    --public-access-block-configuration "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true" \
    --region "$REGION" 2>/dev/null || true

  echo "✅ Bucket configured"
}

# Handle --reset flag
if [[ "$1" == "--reset" ]]; then
  echo "🔄 Resetting environment..."
  echo ""

  cleanup_orphaned_resources
  cleanup_terraform_caches

  # Empty state bucket if it exists
  if [ -n "${TF_VAR_tfstate_bucket}" ]; then
    if aws s3api head-bucket --bucket "${TF_VAR_tfstate_bucket}" --region "$REGION" 2>/dev/null; then
      empty_state_bucket "${TF_VAR_tfstate_bucket}"
    fi
  fi

  # Clear DynamoDB lock table if it exists
  if [ -n "${TF_VAR_tfstate_lock_table}" ]; then
    if aws dynamodb describe-table --table-name "${TF_VAR_tfstate_lock_table}" --region "$REGION" 2>/dev/null >/dev/null; then
      clear_dynamodb_locks "${TF_VAR_tfstate_lock_table}"
    fi
  fi

  echo ""
  echo "✅ Environment reset complete"
  echo ""
  echo "Next steps:"
  echo "  source coder-deploy.env"
  echo "  terragrunt run --all --non-interactive -- apply"
  exit 0
fi

# Handle --full-reset flag
if [[ "$1" == "--full-reset" ]]; then
  echo "🔄 Full reset: cleaning up everything and recreating backend..."
  echo ""

  cleanup_orphaned_resources
  cleanup_terraform_caches

  # Destroy and recreate backend
  if [ -n "${TF_VAR_tfstate_bucket}" ] && [ -n "${TF_VAR_tfstate_lock_table}" ]; then
    echo "🗑️  Removing old backend..."

    # Empty and delete S3 bucket
    if aws s3api head-bucket --bucket "${TF_VAR_tfstate_bucket}" --region "$REGION" 2>/dev/null; then
      empty_state_bucket "${TF_VAR_tfstate_bucket}"
      aws s3api delete-bucket --bucket "${TF_VAR_tfstate_bucket}" --region "$REGION" 2>/dev/null || true
    fi

    # Delete DynamoDB table
    aws dynamodb delete-table --table-name "${TF_VAR_tfstate_lock_table}" --region "$REGION" 2>/dev/null || true

    # Wait for table to be deleted
    echo "⏳ Waiting for DynamoDB table deletion..."
    aws dynamodb wait table-not-exists --table-name "${TF_VAR_tfstate_lock_table}" --region "$REGION" 2>/dev/null || true

    # Remove from env file
    if [ -f "$ENV_FILE" ]; then
      sed -i.bak '/TF_VAR_tfstate_bucket=/d' "$ENV_FILE"
      sed -i.bak '/TF_VAR_tfstate_lock_table=/d' "$ENV_FILE"
      sed -i.bak '/# Terraform State Backend (auto-generated)/d' "$ENV_FILE"
      rm -f "$ENV_FILE.bak"
    fi
  fi

  echo "✅ Old backend removed"
  echo ""

  # Create new backend (fall through to create mode)
  # Re-source env to get updated values
  source "$ENV_FILE"

  # Rebuild name prefix
  if [ -n "$TF_VAR_env_name" ]; then
    NAME_PREFIX="${TF_VAR_env_name}-coder"
  else
    NAME_PREFIX="coder"
  fi
fi

# Handle --destroy flag
if [[ "$1" == "--destroy" || "$1" == "--remove" ]]; then
  BUCKET_NAME="${TF_VAR_tfstate_bucket}"
  TABLE_NAME="${TF_VAR_tfstate_lock_table}"

  if [ -z "$BUCKET_NAME" ] || [ -z "$TABLE_NAME" ]; then
    echo "❌ TF_VAR_tfstate_bucket and TF_VAR_tfstate_lock_table must be set in coder-deploy.env"
    exit 1
  fi

  echo "⚠️  This will permanently delete:"
  echo "   Bucket: $BUCKET_NAME"
  echo "   Table:  $TABLE_NAME"
  echo ""
  read -p "Are you sure? (yes/no): " CONFIRM
  if [ "$CONFIRM" != "yes" ]; then
    echo "Aborted."
    exit 0
  fi

  empty_state_bucket "$BUCKET_NAME"
  aws s3api delete-bucket --bucket "$BUCKET_NAME" --region "$REGION" 2>/dev/null || true

  echo "🗑️  Deleting DynamoDB table: $TABLE_NAME"
  aws dynamodb delete-table --table-name "$TABLE_NAME" --region "$REGION" --output text > /dev/null 2>/dev/null || true

  # Remove from env file
  if [ -f "$ENV_FILE" ]; then
    sed -i.bak '/TF_VAR_tfstate_bucket=/d' "$ENV_FILE"
    sed -i.bak '/TF_VAR_tfstate_lock_table=/d' "$ENV_FILE"
    sed -i.bak '/# Terraform State Backend (auto-generated)/d' "$ENV_FILE"
    rm -f "$ENV_FILE.bak"
  fi

  echo "✅ State backend removed"
  exit 0
fi

# Create mode
# Check if backend already exists in env file
if [ -n "${TF_VAR_tfstate_bucket}" ] && [ -n "${TF_VAR_tfstate_lock_table}" ]; then
  echo "ℹ️  Backend already configured in coder-deploy.env"
  echo "   Bucket: ${TF_VAR_tfstate_bucket}"
  echo "   Table:  ${TF_VAR_tfstate_lock_table}"
  echo ""

  # Check if bucket exists
  if aws s3api head-bucket --bucket "${TF_VAR_tfstate_bucket}" --region "$REGION" 2>/dev/null; then
    echo "✅ S3 bucket exists"
    configure_bucket "${TF_VAR_tfstate_bucket}"
  else
    echo "⚠️  Bucket does not exist. Creating..."
    aws s3api create-bucket \
      --bucket "${TF_VAR_tfstate_bucket}" \
      --region "$REGION" \
      --create-bucket-configuration LocationConstraint="$REGION" \
      --output text > /dev/null
    configure_bucket "${TF_VAR_tfstate_bucket}"
  fi

  # Check if table exists
  if aws dynamodb describe-table --table-name "${TF_VAR_tfstate_lock_table}" --region "$REGION" 2>/dev/null >/dev/null; then
    echo "✅ DynamoDB table exists"
  else
    echo "⚠️  Table does not exist. Creating..."
    ENV_TAG="${TF_VAR_env_name:-default}"
    aws dynamodb create-table \
      --table-name "${TF_VAR_tfstate_lock_table}" \
      --attribute-definitions AttributeName=LockID,AttributeType=S \
      --key-schema AttributeName=LockID,KeyType=HASH \
      --billing-mode PAY_PER_REQUEST \
      --tags Key=ManagedBy,Value=terragrunt Key=Environment,Value="${ENV_TAG}" \
      --region "$REGION" \
      --output text > /dev/null

    echo "⏳ Waiting for table to be active..."
    aws dynamodb wait table-exists --table-name "${TF_VAR_tfstate_lock_table}" --region "$REGION"
    echo "✅ DynamoDB table created"
  fi

  echo ""
  echo "✅ Backend ready"
  exit 0
fi

# Create new backend from scratch
BUCKET_NAME="${NAME_PREFIX}-tfstate-$(openssl rand -hex 4)"
TABLE_NAME="${NAME_PREFIX}-tfstate-lock"

ENV_TAG="${TF_VAR_env_name:-default}"

echo "🪣 Creating S3 bucket: $BUCKET_NAME"
if aws s3api create-bucket \
  --bucket "$BUCKET_NAME" \
  --region "$REGION" \
  --create-bucket-configuration LocationConstraint="$REGION" \
  --output text > /dev/null 2>&1; then
  echo "✅ S3 bucket created"
else
  echo "⚠️  Bucket may already exist, configuring..."
fi

aws s3api put-bucket-tagging \
  --bucket "$BUCKET_NAME" \
  --tagging "TagSet=[{Key=ManagedBy,Value=terragrunt},{Key=Environment,Value=${ENV_TAG}}]" \
  --region "$REGION" 2>/dev/null || true

configure_bucket "$BUCKET_NAME"

echo "🔒 Creating DynamoDB table: $TABLE_NAME"
if aws dynamodb create-table \
  --table-name "$TABLE_NAME" \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --tags Key=ManagedBy,Value=terragrunt Key=Environment,Value="${ENV_TAG}" \
  --region "$REGION" \
  --output text > /dev/null 2>&1; then

  echo "⏳ Waiting for table to be active..."
  aws dynamodb wait table-exists --table-name "$TABLE_NAME" --region "$REGION"
  echo "✅ DynamoDB table created"
else
  echo "⚠️  Table may already exist, continuing..."
fi

# Append to env file if not already there (only match uncommented export lines)
if ! grep -q "^export TF_VAR_tfstate_bucket=" "$ENV_FILE" 2>/dev/null; then
  echo "" >> "$ENV_FILE"
  echo "# Terraform State Backend (auto-generated)" >> "$ENV_FILE"
  echo "export TF_VAR_tfstate_bucket=\"$BUCKET_NAME\"" >> "$ENV_FILE"
  echo "export TF_VAR_tfstate_lock_table=\"$TABLE_NAME\"" >> "$ENV_FILE"
fi

echo ""
echo "✅ State backend created and added to coder-deploy.env"
echo ""
echo "   Bucket: $BUCKET_NAME"
echo "   Table:  $TABLE_NAME"
echo ""
echo "Re-source your env file:"
echo "   source coder-deploy.env"
