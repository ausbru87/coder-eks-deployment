# Stage 3: Day 2 Operations
# Post-deployment configuration requiring CODER_TOKEN
#
# Resources:
#   - Coder license
#   - Provisioner key
#   - External provisioner Helm release
#
# Depends on: 02-apps (Coder must be running)
# Requires: CODER_TOKEN environment variable

include "root" {
  path = find_in_parent_folders()
}

# Skip if CODER_TOKEN not set - user must create admin user first
# Note: skip directive commented out to allow destroy operations
# skip = get_env("CODER_TOKEN", "") == ""

dependency "infra" {
  config_path = "../01-infra"

  mock_outputs = {
    provisioner_role_arn = "arn:aws:iam::123456789012:role/mock-provisioner"
    cluster_name         = "mock-cluster"
  }
}

dependency "apps" {
  config_path = "../02-apps"

  mock_outputs = {
    coder_url       = "https://mock.coder.example.com"
    coder_namespace = "coder"
    cluster_name    = "mock-cluster"
  }
}

# No terraform.source block - run in place

inputs = {
  provisioner_role_arn = dependency.infra.outputs.provisioner_role_arn
  coder_url            = dependency.apps.outputs.coder_url
  coder_namespace      = dependency.apps.outputs.coder_namespace
  cluster_name         = dependency.apps.outputs.cluster_name
  coder_token          = get_env("CODER_TOKEN", "")
  license_key          = get_env("TF_VAR_license_key", "")
}
