# Stage 1: Infrastructure
# All AWS resources: Secrets, ACM, VPC, EKS, RDS, IAM
#
# Prerequisites: Run scripts/create-tfstate-backend.sh first

include "root" {
  path = find_in_parent_folders("root.hcl")
}

# No terraform.source block - run in place to preserve relative module paths
