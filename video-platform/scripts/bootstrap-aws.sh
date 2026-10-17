#!/usr/bin/env bash
# One-command cloud setup. Prerequisites:
#   aws configure      (access key for an IAM user with AdministratorAccess)
#   gh auth login      (GitHub CLI)
# Then run:  ./scripts/bootstrap-aws.sh
#
# Safe to re-run: every step skips work that is already done.
# Env overrides: AWS_REGION (default ap-south-1), GITHUB_REPO (default kartikadhonde/video-platform)
set -euo pipefail

REGION="${AWS_REGION:-ap-south-1}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TF_DIR="$ROOT/infra/terraform"
# The git repo may live above this folder (e.g. a course repo containing video-platform/).
GIT_ROOT="$(git -C "$ROOT" rev-parse --show-toplevel 2>/dev/null || echo "$ROOT")"
ORIGIN_REPO="$(git -C "$GIT_ROOT" remote get-url origin 2>/dev/null \
  | sed -E 's#^(git@github\.com:|https://github\.com/)##; s#\.git$##' || true)"
REPO="${GITHUB_REPO:-${ORIGIN_REPO:-kartikadhonde/cc-proj}}"

step() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
die() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

step "Checking tools and logins"
for tool in aws terraform gh git; do
  command -v "$tool" >/dev/null || die "$tool is not installed (brew install $tool)"
done
ACCOUNT=$(aws sts get-caller-identity --query Account --output text 2>/dev/null) \
  || die "AWS credentials not configured. Run: aws configure"
gh auth status >/dev/null 2>&1 || die "GitHub CLI not logged in. Run: gh auth login"
echo "AWS account: $ACCOUNT | region: $REGION | GitHub repo: $REPO"

STATE_BUCKET="video-platform-tfstate-$ACCOUNT"
step "Terraform state bucket: $STATE_BUCKET"
if aws s3api head-bucket --bucket "$STATE_BUCKET" 2>/dev/null; then
  echo "already exists"
else
  if [ "$REGION" = "us-east-1" ]; then
    aws s3api create-bucket --bucket "$STATE_BUCKET" --region "$REGION" >/dev/null
  else
    aws s3api create-bucket --bucket "$STATE_BUCKET" --region "$REGION" \
      --create-bucket-configuration LocationConstraint="$REGION" >/dev/null
  fi
  aws s3api put-bucket-versioning --bucket "$STATE_BUCKET" \
    --versioning-configuration Status=Enabled
  aws s3api put-public-access-block --bucket "$STATE_BUCKET" --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
  echo "created"
fi

step "terraform.tfvars"
if [ -f "$TF_DIR/terraform.tfvars" ]; then
  echo "already exists, leaving it unchanged"
else
  cat > "$TF_DIR/terraform.tfvars" <<EOF
aws_region      = "$REGION"
github_repo     = "$REPO"
tf_state_bucket = "$STATE_BUCKET"
EOF
  echo "written"
fi

step "Git repository and GitHub remote"
cd "$GIT_ROOT"
[ -d .git ] || { git init -q -b main && git add -A && git commit -qm "Initial commit"; }
gh repo view "$REPO" >/dev/null 2>&1 || gh repo create "$REPO" --private
git remote get-url origin >/dev/null 2>&1 || git remote add origin "https://github.com/$REPO.git"

step "terraform apply (about 5-10 minutes; type 'yes' when asked)"
cd "$TF_DIR"
terraform init -input=false -reconfigure \
  -backend-config="bucket=$STATE_BUCKET" -backend-config="region=$REGION" >/dev/null
terraform apply

step "Setting GitHub repository variables"
gh variable set AWS_REGION --repo "$REPO" --body "$REGION"
gh variable set TF_STATE_BUCKET --repo "$REPO" --body "$STATE_BUCKET"
ROLE_ARN=$(terraform output -raw github_actions_role_arn 2>/dev/null || true)
if [ -n "$ROLE_ARN" ] && [ "$ROLE_ARN" != "null" ]; then
  gh variable set AWS_ROLE_ARN --repo "$REPO" --body "$ROLE_ARN"
else
  echo "Learner Lab mode: add AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY / AWS_SESSION_TOKEN as repo secrets"
fi
APP_URL=$(terraform output -raw cloudfront_url)

step "Pushing code and starting the first deploy"
cd "$GIT_ROOT"
git push -u origin main
# Right after the first push GitHub may need a few seconds to register the workflow.
for attempt in 1 2 3 4 5 6; do
  gh workflow run ci-deploy.yml --repo "$REPO" --ref main 2>/dev/null && break
  [ "$attempt" = 6 ] && die "could not start the workflow; run it from the GitHub Actions tab"
  sleep 10
done

step "Done"
cat <<EOF
The deploy is running now (about 5-8 minutes). Watch it with:
  gh run watch --repo $REPO

Then open the app:  $APP_URL

When you finish for the day, stop all costs with:
  ./scripts/teardown-aws.sh
EOF
