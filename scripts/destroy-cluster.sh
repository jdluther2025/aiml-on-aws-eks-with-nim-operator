#!/usr/bin/env bash
# destroy-cluster.sh — Delete all resources in reverse creation order.
# Run from the repo root: ./scripts/destroy-cluster.sh
#
# Order matters:
#   1. K8s apps + NIM resources (chatbot, NIMService, NIMCache, NodePool)
#   2. OpenSearch data access policy (created outside CDK)
#   3. EKS cluster (eksctl — also deletes chatbot IAM role)
#   4. EFS mount targets (CDK-managed but may need manual cleanup before CDK destroy)
#   5. CDK stack (VPC, EFS, OpenSearch collection + policies + VPC endpoint)
#   6. Verify nothing is left running

set -euo pipefail

CLUSTER_NAME="eks-nim-platform"
REGION="${AWS_DEFAULT_REGION:-us-east-1}"
STACK_NAME="EksNimStack"
AOSS_COLLECTION_NAME="nim-rag-store"
DATA_POLICY_NAME="nim-rag-data"
IAM_CHATBOT_ROLE="${IAM_CHATBOT_ROLE:-nim-chatbot-role}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

get_output() {
    aws cloudformation describe-stacks \
        --stack-name "${STACK_NAME}" \
        --region "${REGION}" \
        --query "Stacks[0].Outputs[?OutputKey=='${1}'].OutputValue" \
        --output text 2>/dev/null || echo ""
}

echo "── STEP 1: Delete chatbot and NIM Kubernetes resources ─────────────────"
kubectl delete deployment nim-rag-chatbot --ignore-not-found || true
kubectl delete service nim-rag-chatbot --ignore-not-found || true
kubectl delete -f "${REPO_ROOT}/nim/nimservices.yaml" --ignore-not-found || true
kubectl delete -f "${REPO_ROOT}/nim/nimcaches.yaml" --ignore-not-found || true
kubectl delete -f "${REPO_ROOT}/nim/gpu-nodepool.yaml" --ignore-not-found || true
kubectl delete storageclass efs-sc --ignore-not-found || true
kubectl delete namespace nim-service --ignore-not-found || true
echo "Kubernetes resources deleted."

echo ""
echo "── STEP 2: Delete OpenSearch data access policy ─────────────────────────"
aws opensearchserverless delete-access-policy \
    --name "${DATA_POLICY_NAME}" \
    --type data \
    --region "${REGION}" 2>/dev/null \
    && echo "Data access policy deleted." \
    || echo "Data access policy not found — skipping."

echo ""
echo "── STEP 3: Delete EKS cluster with eksctl ──────────────────────────────"
eksctl delete cluster --name "${CLUSTER_NAME}" --region "${REGION}" --wait

echo ""
echo "── STEP 4: Delete EFS mount targets ─────────────────────────────────────"
# Mount targets must be deleted before CloudFormation can delete the EFS filesystem.
# CDK attempts this automatically, but manual deletion here prevents timeouts.
EFS_FS_ID=$(get_output "EfsFileSystemId")
if [[ -n "${EFS_FS_ID}" ]]; then
    MT_IDS=$(aws efs describe-mount-targets \
        --file-system-id "${EFS_FS_ID}" \
        --query 'MountTargets[*].MountTargetId' \
        --output text \
        --region "${REGION}" 2>/dev/null || echo "")
    if [[ -n "${MT_IDS}" ]]; then
        for mt_id in ${MT_IDS}; do
            aws efs delete-mount-target --mount-target-id "${mt_id}" --region "${REGION}"
            echo "  Deleted mount target: ${mt_id}"
        done
        echo "Waiting 30s for mount targets to finish deleting..."
        sleep 30
    else
        echo "No mount targets found for ${EFS_FS_ID}."
    fi
fi

echo ""
echo "── STEP 5: Destroy VPC, EFS, and OpenSearch with CDK ──────────────────"
cd "${REPO_ROOT}/infra"
source .venv/bin/activate
cdk destroy --force
deactivate

echo ""
echo "── STEP 6: Verify everything is gone ───────────────────────────────────"
PASS=0
FAIL=0

check() {
    local label="$1"; local cmd="$2"; local expect_empty="$3"
    local result
    result=$(eval "${cmd}" 2>&1)
    if [[ "${expect_empty}" == "true" && -z "${result}" ]] || \
       [[ "${expect_empty}" == "false" && -n "$(echo "${result}" | grep -i 'does not exist\|not found\|NoSuchEntity\|cannot list\|error')" ]]; then
        echo "  ✓ ${label}"
        PASS=$((PASS + 1))
    else
        echo "  ✗ ${label} — may still exist"
        echo "    ${result}" | head -3
        FAIL=$((FAIL + 1))
    fi
}

check "EKS cluster deleted" \
    "aws eks describe-cluster --name ${CLUSTER_NAME} --region ${REGION} 2>&1 | grep -i 'not found\|does not exist'" \
    "false"

check "eksctl CloudFormation stack deleted" \
    "aws cloudformation describe-stacks --stack-name eksctl-${CLUSTER_NAME}-cluster --region ${REGION} 2>&1 | grep -i 'does not exist\|not found'" \
    "false"

check "CDK CloudFormation stack deleted" \
    "aws cloudformation describe-stacks --stack-name ${STACK_NAME} --region ${REGION} 2>&1 | grep -i 'does not exist\|not found'" \
    "false"

check "No EC2 GPU nodes still running" \
    "aws ec2 describe-instances \
        --filters Name=tag:eks:cluster-name,Values=${CLUSTER_NAME} Name=instance-state-name,Values=running,pending \
        --query 'Reservations[].Instances[].InstanceId' \
        --output text --region ${REGION}" \
    "true"

echo ""
if [[ "${FAIL}" -eq 0 ]]; then
    echo "All ${PASS} checks passed. No idle costs."
else
    echo "${FAIL} check(s) failed — review above."
    echo "Re-check manually:"
    echo "  aws eks describe-cluster --name ${CLUSTER_NAME} --region ${REGION}"
    echo "  aws cloudformation list-stacks --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE --region ${REGION}"
fi
