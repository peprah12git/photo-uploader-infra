#!/usr/bin/env bash
#
# teardown.sh — Photo-uploader FULL clean teardown
# Handles every blocker discovered the hard way:
#   - versioned buckets (objects + versions + delete markers)
#   - ECR images blocking repo deletion
#   - in-progress CodeDeploy deployments
#   - the RETAINED artifact bucket (deleted so redeploy never collides)
# Leaves in place (bootstrap layer, needed for redeploy):
#   - CFN templates bucket, secret, OIDC provider, SLRs, GitSync role & config
#
set -uo pipefail
export AWS_PAGER=""

REGION="eu-central-1"
STACK="photo-uploader-stack"
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)

PHOTOS_BUCKET="photo-uploader-photos-${ACCOUNT}"
ARTIFACT_BUCKET="photo-uploader-artifacts-${ACCOUNT}"

CLUSTER="photo-uploader-cluster"
SERVICE="photo-uploader-service"
CD_APP="photo-uploader-codedeploy"
CD_GROUP="photo-uploader-deployment-group"
ECR_REPO="photo-uploader"

echo "=================================================================="
echo " TEARDOWN  |  account ${ACCOUNT}  |  region ${REGION}"
echo "=================================================================="

# ---------- helper: purge a versioned bucket completely ----------
purge_bucket () {
  local B="$1"
  if ! aws s3api head-bucket --bucket "${B}" --region "${REGION}" 2>/dev/null; then
    echo "   ${B}: does not exist (ok)"
    return 0
  fi
  echo "   ${B}: purging objects, versions, delete markers..."
  aws s3 rm "s3://${B}" --recursive --region "${REGION}" >/dev/null 2>&1 || true
  local V M
  V=$(aws s3api list-object-versions --bucket "${B}" --region "${REGION}" \
      --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}}' --output json 2>/dev/null)
  if echo "${V}" | grep -q '"Key"'; then
    aws s3api delete-objects --bucket "${B}" --region "${REGION}" --delete "${V}" >/dev/null 2>&1 || true
  fi
  M=$(aws s3api list-object-versions --bucket "${B}" --region "${REGION}" \
      --query '{Objects: DeleteMarkers[].{Key:Key,VersionId:VersionId}}' --output json 2>/dev/null)
  if echo "${M}" | grep -q '"Key"'; then
    aws s3api delete-objects --bucket "${B}" --region "${REGION}" --delete "${M}" >/dev/null 2>&1 || true
  fi
  echo "   ${B}: purged."
}

# ---------- 1. stop in-flight CodeDeploy deployments ----------
echo
echo "[1/7] Stopping in-progress CodeDeploy deployments..."
DEPLOYMENTS=$(aws deploy list-deployments --application-name "${CD_APP}" \
  --deployment-group-name "${CD_GROUP}" \
  --include-only-statuses InProgress Created Queued Ready \
  --region "${REGION}" --query "deployments" --output text 2>/dev/null)
if [ -n "${DEPLOYMENTS:-}" ] && [ "${DEPLOYMENTS}" != "None" ]; then
  for D in ${DEPLOYMENTS}; do
    echo "   stopping ${D}"
    aws deploy stop-deployment --deployment-id "${D}" --auto-rollback-enabled \
      --region "${REGION}" >/dev/null 2>&1 || true
  done
else
  echo "   none."
fi

# ---------- 2. drain ECS ----------
echo
echo "[2/7] Scaling ECS service to 0 and waiting for drain..."
if aws ecs update-service --cluster "${CLUSTER}" --service "${SERVICE}" \
     --desired-count 0 --region "${REGION}" >/dev/null 2>&1; then
  aws ecs wait services-stable --cluster "${CLUSTER}" --services "${SERVICE}" \
    --region "${REGION}" 2>/dev/null && echo "   drained." || echo "   wait skipped (ok)."
else
  echo "   service not found (ok)."
fi

# ---------- 3. purge versioned buckets ----------
echo
echo "[3/7] Purging S3 buckets..."
purge_bucket "${PHOTOS_BUCKET}"
purge_bucket "${ARTIFACT_BUCKET}"

# ---------- 4. empty ECR ----------
echo
echo "[4/7] Emptying ECR repository..."
IMAGES=$(aws ecr list-images --repository-name "${ECR_REPO}" --region "${REGION}" \
  --query 'imageIds[*]' --output json 2>/dev/null)
if [ -n "${IMAGES:-}" ] && [ "${IMAGES}" != "[]" ] && [ "${IMAGES}" != "null" ]; then
  aws ecr batch-delete-image --repository-name "${ECR_REPO}" --region "${REGION}" \
    --image-ids "${IMAGES}" >/dev/null 2>&1 && echo "   images deleted." || echo "   delete skipped."
else
  echo "   repo empty or absent (ok)."
fi

# ---------- 5. delete stack (retry loop handles stragglers) ----------
echo
echo "[5/7] Deleting stack (up to 3 attempts; CloudFront/RDS make this slow)..."
ATTEMPT=1
while [ ${ATTEMPT} -le 3 ]; do
  echo "   attempt ${ATTEMPT}..."
  aws cloudformation delete-stack --stack-name "${STACK}" --region "${REGION}" 2>/dev/null
  if aws cloudformation wait stack-delete-complete --stack-name "${STACK}" --region "${REGION}" 2>/dev/null; then
    echo "   stack deleted."
    break
  fi
  STATUS=$(aws cloudformation describe-stacks --stack-name "${STACK}" --region "${REGION}" \
    --query "Stacks[0].StackStatus" --output text 2>/dev/null)
  if [ -z "${STATUS:-}" ]; then echo "   stack gone."; break; fi
  echo "   status ${STATUS}; re-purging buckets/ECR and retrying..."
  purge_bucket "${PHOTOS_BUCKET}"; purge_bucket "${ARTIFACT_BUCKET}"
  IMAGES=$(aws ecr list-images --repository-name "${ECR_REPO}" --region "${REGION}" \
    --query 'imageIds[*]' --output json 2>/dev/null)
  [ -n "${IMAGES:-}" ] && [ "${IMAGES}" != "[]" ] && \
    aws ecr batch-delete-image --repository-name "${ECR_REPO}" --region "${REGION}" \
      --image-ids "${IMAGES}" >/dev/null 2>&1
  ATTEMPT=$((ATTEMPT+1))
done

# ---------- 6. remove the RETAINED artifact bucket ----------
# pipeline.yml has DeletionPolicy: Retain on it; if left behind it COLLIDES
# with the next deploy (the exact PipelineStack validation failure we hit).
echo
echo "[6/7] Removing retained artifact bucket (prevents redeploy collision)..."
purge_bucket "${ARTIFACT_BUCKET}"
aws s3 rb "s3://${ARTIFACT_BUCKET}" --region "${REGION}" 2>/dev/null \
  && echo "   removed." || echo "   already gone (ok)."

# ---------- 7. final state ----------
echo
echo "[7/7] Final check..."
FINAL=$(aws cloudformation describe-stacks --stack-name "${STACK}" --region "${REGION}" \
  --query "Stacks[0].StackStatus" --output text 2>&1)
echo "   stack status: ${FINAL}"
echo
echo "RETAINED on purpose (bootstrap layer for redeploy):"
echo "   - photo-uploader-cfn-templates-${ACCOUNT} (templates bucket)"
echo "   - /photo-uploader/db/password (secret)"
echo "   - OIDC provider, service-linked roles, GitSync role + sync config"
echo
echo "NOTE: an RDS final snapshot was created (DeletionPolicy: Snapshot)."
echo "Delete it in RDS console -> Snapshots if you don't want the small cost."
echo "=================================================================="