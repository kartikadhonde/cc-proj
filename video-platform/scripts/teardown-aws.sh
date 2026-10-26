#!/usr/bin/env bash
# Destroys every AWS resource Terraform created, so nothing keeps running or using credits.
# Only the tiny Terraform state bucket is kept. Bring everything back with
# ./scripts/bootstrap-aws.sh (it re-runs terraform apply and the first deploy).
set -euo pipefail

if [ -d "/c/Program Files/Amazon/AWSCLIV2" ]; then
  export PATH="$PATH:/c/Program Files/Amazon/AWSCLIV2"
fi

TF_DIR="$(cd "$(dirname "$0")/.." && pwd)/infra/terraform"
cd "$TF_DIR"
if [ ! -d .terraform ]; then
  echo "Terraform is not initialised here yet. Run ./scripts/bootstrap-aws.sh first." >&2
  exit 1
fi
terraform destroy
