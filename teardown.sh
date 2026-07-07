#!/usr/bin/env bash
#
# Photo-uploader teardown script  (account 825765391206, region eu-central-1)
# Empties buckets + stops deployments so the CloudFormation stack deletes cleanly.
#
set -uo pipefail
export AWS_PAGER=""

REGION="eu-central-1"
STACK="photo-uploader-stack"
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)

PHOTOS_BUCKET="photo-uploader-photos-${ACCOUNT}"
ARTIFACT_BUCKET="photo-uploader-artifacts-${ACCOUNT}"
TEMPLATES_BUCKET="photo-uploader-cfn-templates-${ACCOUNT}"

CLUSTER="photo-uploader-cluster"
SERVICE="photo-uploader-service"
CD_APP="photo-uploader-codedeploy"
CD_GROUP="photo-uploader-deployment-group"

echo "=================================================="
echo " Photo-uploader teardown"
echo " Account: ${ACCOUNT}   Region: ${REGION}"
echo "=================================================="

# ---- 1. Stop any in-progress CodeDeploy deployment -------------------------
echo
echo "[1/6] Checking for in-progress CodeDeploy deployments..."
DEPLOYMENTS=$(aws deploy list-deployments \
  --application-name "${CD_APP}" \
  --deployment-group-name "${CD_GROUP}" \
  --include-only-statuses InProgress Created Queued Ready \
  --region "${REGION}" \
  --query "deployments" --output text 2>/dev/null)

if [ -n "${DEPLOYMENTS}" ] && [ "${DEPLOYMENTS}" != "None" ]; then
  for D in ${DEPLOYMENTS}; do
    echo "   Stopping deployment ${D}..."
    aws deploy stop-deployment --deployment-id "${D}" \
      --auto-rollback-enabled --region "${REGION}" 2>/dev/null || true
  done
else
  echo "   None in progress."
fi

# ---- 2. Scale ECS service to 0 ---------------------------------------------
echo
echo "[2/6] Scaling ECS service to 0 tasks..."
aws ecs update-service \
  --cluster "${CLUSTER}" \
  --service "${SERVICE}" \
  --desired-count 0 \
  --region "${REGION}" >/dev/null 2>&1 \
  && echo "   Desired count set to 0." \
  || echo "   Service not found or already gone (fine)."

echo "   Waiting for tasks to drain..."
aws ecs wait services-stable \
  --cluster "${CLUSTER}" \
  --services "${SERVICE}" \
  --region "${REGION}" 2>/dev/null \
  && echo "   Tasks drained." \
  || echo "   Service already gone or wait skipped (fine)."

# ---- 3. Empty the photo bucket (objects + versions + delete markers) -------
empty_bucket () {
  local B="$1"
  echo "   Emptying ${B}..."
  # current objects
  aws s3 rm "s3://${B}" --recursive --region "${REGION}" >/dev/null 2>&1 || true
  # versions
  local V
  V=$(aws s3api list-object-versions --bucket "${B}" --region "${REGION}" \
      --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}}' --output json 2>/dev/null)
  if [ -n "${V}" ] && echo "${V}" | grep -q '"Key"'; then
    aws s3api delete-objects --bucket "${B}" --region "${REGION}" --delete "${V}" >/dev/null 2>&1 || true
  fi
  # delete markers
  local M
  M=$(aws s3api list-object-versions --bucket "${B}" --region "${REGION}" \
      --query '{Objects: DeleteMarkers[].{Key:Key,VersionId:VersionId}}' --output json 2>/dev/null)
  if [ -n "${M}" ] && echo "${M}" | grep -q '"Key"'; then
    aws s3api delete-objects --bucket "${B}" --region "${REGION}" --delete "${M}" >/dev/null 2>&1 || true
  fi
}

echo
echo "[3/6] Emptying S3 buckets (objects + versions)..."
empty_bucket "${PHOTOS_BUCKET}"
empty_bucket "${ARTIFACT_BUCKET}"

# ---- 4. Delete the stack ---------------------------------------------------
echo
echo "[4/6] Deleting CloudFormation stack ${STACK}..."
aws cloudformation delete-stack --stack-name "${STACK}" --region "${REGION}"

echo
echo "[5/6] Waiting for stack deletion to complete (this can take 15-25 min,"
echo "      mostly CloudFront + RDS final snapshot)..."
if aws cloudformation wait stack-delete-complete --stack-name "${STACK}" --region "${REGION}"; then
  echo "   Stack deleted successfully."
else
  echo "   !! Stack delete did not complete cleanly. Check the console Events tab"
  echo "      for the resource that failed, then re-run after resolving it."
  exit 1
fi

# ---- 6. Report on retained resources ---------------------------------------
echo
echo "[6/6] Done. The following are RETAINED by design (not deleted):"
echo "   - Artifact bucket  : ${ARTIFACT_BUCKET}  (DeletionPolicy: Retain)"
echo "   - Templates bucket : ${TEMPLATES_BUCKET} (created manually)"
echo "   - OIDC provider    : token.actions.githubusercontent.com (DeletionPolicy: Retain)"
echo "   - Secret           : /photo-uploader/db/password (standalone)"
echo "   - RDS final snapshot (from DeletionPolicy: Snapshot)"
echo
echo "If you want these fully gone too, delete them manually:"
echo "   aws s3 rb s3://${ARTIFACT_BUCKET} --force --region ${REGION}"
echo "   aws s3 rb s3://${TEMPLATES_BUCKET} --force --region ${REGION}"
echo "   (leave the OIDC provider + secret if the account is shared / reused)"
echo "=================================================="