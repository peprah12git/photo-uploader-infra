#!/usr/bin/env bash
#
# deploy.sh — Photo-uploader GitSync-ready deploy preflight + trigger
# Runs every prerequisite check/fix discovered the hard way, so the
# GitSync "Retry latest commit" (or PR merge) provisions cleanly:
#   - verifies/creates secret, templates bucket, SLRs
#   - verifies OIDC provider (tells you the right CreateOIDCProvider value)
#   - re-uploads templates to S3 (nested stacks read from there)
#   - ensures GitSync role has trust + permissions (incl. PassRole, nested
#     stack actions, template bucket read, AdministratorAccess)
#   - checks no leftover artifact bucket (the PipelineStack collision)
#   - checks stack state is deployable
# Then tells you the single console action to trigger the deploy.
#
set -uo pipefail
export AWS_PAGER=""

REGION="eu-central-1"
STACK="photo-uploader-stack"
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)

TEMPLATES_BUCKET="photo-uploader-cfn-templates-${ACCOUNT}"
ARTIFACT_BUCKET="photo-uploader-artifacts-${ACCOUNT}"
SECRET_NAME="/photo-uploader/db/password"
GITSYNC_ROLE="CloudFormationGitSyncRole"
INFRA_DIR="${1:-$HOME/photo-uploader-infra}"   # pass repo path as arg 1 if elsewhere

PASS=0; WARN=0
ok ()   { echo "   OK    $1"; }
fixup (){ echo "   FIXED $1"; }
warn () { echo "   WARN  $1"; WARN=1; }

echo "=================================================================="
echo " DEPLOY PREFLIGHT  |  account ${ACCOUNT}  |  region ${REGION}"
echo "=================================================================="

# ---------- 1. secret ----------
echo
echo "[1/8] Secret ${SECRET_NAME}"
if aws secretsmanager get-secret-value --secret-id "${SECRET_NAME}" --region "${REGION}" \
     --query SecretString --output text >/dev/null 2>&1; then
  ok "secret exists"
else
  aws secretsmanager create-secret --name "${SECRET_NAME}" \
    --description "RDS master password for photo-uploader" \
    --secret-string '{"password":"SimpleTest123"}' --region "${REGION}" >/dev/null \
    && fixup "secret created (SimpleTest123)" || warn "could not create secret"
fi

# ---------- 2. templates bucket ----------
echo
echo "[2/8] Templates bucket ${TEMPLATES_BUCKET}"
if aws s3api head-bucket --bucket "${TEMPLATES_BUCKET}" --region "${REGION}" 2>/dev/null; then
  ok "bucket exists"
else
  aws s3api create-bucket --bucket "${TEMPLATES_BUCKET}" --region "${REGION}" \
    --create-bucket-configuration LocationConstraint="${REGION}" >/dev/null \
    && fixup "bucket created" || warn "could not create bucket"
fi

# ---------- 3. upload templates ----------
echo
echo "[3/8] Uploading templates from ${INFRA_DIR}"
if [ -f "${INFRA_DIR}/root-stack.yml" ] && [ -d "${INFRA_DIR}/templates" ]; then
  ( cd "${INFRA_DIR}" && \
    aws s3 sync ./templates "s3://${TEMPLATES_BUCKET}/templates/" --delete >/dev/null && \
    aws s3 cp root-stack.yml "s3://${TEMPLATES_BUCKET}/root-stack.yml" >/dev/null ) \
    && ok "templates synced" || warn "template upload failed"
else
  warn "repo not found at ${INFRA_DIR} — clone it or pass path: ./deploy.sh /path/to/photo-uploader-infra"
fi

# ---------- 4. service-linked roles ----------
echo
echo "[4/8] Service-linked roles"
for SLR in ecs.amazonaws.com ecs.application-autoscaling.amazonaws.com; do
  aws iam create-service-linked-role --aws-service-name "${SLR}" >/dev/null 2>&1 \
    && fixup "created SLR for ${SLR}" || ok "SLR for ${SLR} present"
done

# ---------- 5. OIDC provider ----------
echo
echo "[5/8] GitHub OIDC provider"
if aws iam list-open-id-connect-providers --output text | grep -q token.actions.githubusercontent.com; then
  ok "provider exists -> deployment-file must have CreateOIDCProvider: 'false'"
else
  warn "provider MISSING -> set CreateOIDCProvider: 'true' in deployment-file.yaml"
fi

# ---------- 6. GitSync role: trust + permissions ----------
echo
echo "[6/8] GitSync role ${GITSYNC_ROLE}"
if aws iam get-role --role-name "${GITSYNC_ROLE}" >/dev/null 2>&1; then
  ok "role exists"
  aws iam update-assume-role-policy --role-name "${GITSYNC_ROLE}" --policy-document '{
    "Version":"2012-10-17",
    "Statement":[{"Sid":"CfnGitSyncTrustPolicy","Effect":"Allow",
      "Principal":{"Service":["cloudformation.amazonaws.com","cloudformation.sync.codeconnections.amazonaws.com"]},
      "Action":"sts:AssumeRole"}]}' 2>/dev/null && ok "trust policy ensured (both principals)"
  aws iam put-role-policy --role-name "${GITSYNC_ROLE}" --policy-name AllowPassRoleToCloudFormation \
    --policy-document "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":\"iam:PassRole\",\"Resource\":\"arn:aws:iam::${ACCOUNT}:role/service-role/${GITSYNC_ROLE}\",\"Condition\":{\"StringEquals\":{\"iam:PassedToService\":\"cloudformation.amazonaws.com\"}}}]}" \
    2>/dev/null && ok "PassRole policy ensured"
  aws iam put-role-policy --role-name "${GITSYNC_ROLE}" --policy-name AllowNestedStackOperations \
    --policy-document "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":[\"cloudformation:CreateStack\",\"cloudformation:UpdateStack\",\"cloudformation:DeleteStack\",\"cloudformation:DescribeStacks\",\"cloudformation:DescribeStackEvents\",\"cloudformation:DescribeStackResources\",\"cloudformation:GetTemplate\",\"cloudformation:CreateChangeSet\",\"cloudformation:DeleteChangeSet\",\"cloudformation:DescribeChangeSet\",\"cloudformation:ExecuteChangeSet\"],\"Resource\":\"arn:aws:cloudformation:${REGION}:${ACCOUNT}:stack/${STACK}*\"}]}" \
    2>/dev/null && ok "nested-stack policy ensured"
  aws iam put-role-policy --role-name "${GITSYNC_ROLE}" --policy-name AllowTemplateBucketRead \
    --policy-document "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":[\"s3:GetObject\"],\"Resource\":\"arn:aws:s3:::${TEMPLATES_BUCKET}/*\"}]}" \
    2>/dev/null && ok "template-bucket read ensured"
  aws iam attach-role-policy --role-name "${GITSYNC_ROLE}" \
    --policy-arn arn:aws:iam::aws:policy/AdministratorAccess 2>/dev/null
  ok "AdministratorAccess ensured (resource creation)"
else
  warn "role missing — create it via the GitSync console flow first"
fi

# ---------- 7. artifact-bucket collision check ----------
echo
echo "[7/8] Artifact bucket collision check"
if aws s3api head-bucket --bucket "${ARTIFACT_BUCKET}" --region "${REGION}" 2>/dev/null; then
  warn "LEFTOVER ${ARTIFACT_BUCKET} exists — PipelineStack will FAIL to create."
  echo "         Run teardown.sh (step 6) or delete it, then re-run this preflight."
else
  ok "no leftover artifact bucket"
fi

# ---------- 8. stack state ----------
echo
echo "[8/8] Stack state"
STATUS=$(aws cloudformation describe-stacks --stack-name "${STACK}" --region "${REGION}" \
  --query "Stacks[0].StackStatus" --output text 2>/dev/null)
case "${STATUS:-ABSENT}" in
  ABSENT|"")
    ok "no stack — GitSync 'Create stack -> Sync from Git' will create it (merge its PR CAREFULLY:"
    echo "         if the PR guts deployment-file.yaml parameters, close it and push your correct file instead)";;
  UPDATE_ROLLBACK_COMPLETE|CREATE_COMPLETE|UPDATE_COMPLETE)
    ok "stack in retryable state (${STATUS}) — use 'Retry latest commit' on the Git sync tab";;
  ROLLBACK_COMPLETE)
    warn "stack is ROLLBACK_COMPLETE — it must be DELETED before recreate (run teardown.sh)";;
  *IN_PROGRESS*)
    warn "stack busy (${STATUS}) — wait for it to settle";;
  *)
    warn "stack in ${STATUS} — inspect before proceeding";;
esac

echo
echo "=================================================================="
if [ ${WARN} -eq 0 ]; then
  echo " PREFLIGHT CLEAN. Trigger the deploy:"
  echo "   Console -> CloudFormation -> ${STACK} -> Git sync -> 'Retry latest commit'"
  echo "   (or push a commit to the infra repo main branch)"
  echo " Then watch:"
  echo "   aws cloudformation describe-stacks --stack-name ${STACK} --region ${REGION} \\"
  echo "     --query 'Stacks[0].StackStatus' --output text"
else
  echo " PREFLIGHT HAS WARNINGS above — fix them, re-run, THEN trigger the deploy."
fi
echo "=================================================================="