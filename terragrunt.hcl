# Root Terragrunt Configuration
# Provides common settings inherited by all stages
#
# Usage:
#   source coder-deploy.env
#   terragrunt run --all -- apply
#
# Environment prefix (optional):
#   export TF_VAR_env_name="myenv"   # Resources prefixed as myenv-coder-demo
#
# Stages execute in dependency order:
#   01-infra -> 02-apps -> 03-day2
#
# Note: 03-day2 requires CODER_TOKEN (auto-skipped if not set)

locals {
  # Common tags applied to all resources
  common_tags = {
    ManagedBy   = "terragrunt"
    Environment = get_env("TF_VAR_env_name", "demo")
  }
}

# Generate provider configuration for child modules
generate "provider" {
  path      = "provider.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<EOF
provider "aws" {
  region = var.region

  default_tags {
    tags = {
      ManagedBy   = "terragrunt"
      Environment = var.env_name
    }
  }
}
EOF
}

# Remote state configuration - stages use their own state files
remote_state {
  backend = "s3"
  generate = {
    path      = "backend.tf"
    if_exists = "overwrite_terragrunt"
  }
  config = {
    bucket         = get_env("TF_VAR_tfstate_bucket", "")
    key            = "${path_relative_to_include()}/terraform.tfstate"
    region         = get_env("TF_VAR_region", "us-west-2")
    encrypt        = true
    dynamodb_table = get_env("TF_VAR_tfstate_lock_table", "")
  }
}

# Inputs available to all child modules
inputs = {
  region   = get_env("TF_VAR_region", "us-west-2")
  env_name = get_env("TF_VAR_env_name", "demo")
}
