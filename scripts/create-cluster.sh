#!/usr/bin/env bash
# create-cluster.sh — Deploy VPC/EFS/OpenSearch with CDK, then create EKS cluster with eksctl.
# Run from the repo root: ./scripts/create-cluster.sh
#
# What this does:
#   Step 1: CDK deploys VPC, EFS (ReadWriteMany for NIMCache), OpenSearch Serverless
#   Step 2: Read CDK outputs (subnet IDs, EFS ID, OpenSearch endpoint)
#   Step 3: envsubst fills cluster.yaml.template → cluster/cluster.yaml
#   Step 4: eksctl creates EKS cluster (Auto Mode) + chatbot IAM role + Pod Identity
#   Step 5: Wire chatbot IAM role to OpenSearch data access policy

set -euo pipefail

_SCRIPT="${BASH_SOURCE[0]}"
case "${_SCRIPT}" in
    /*)  ;;
    */*) _SCRIPT="${PWD}/${_SCRIPT}" ;;
    *)   _SCRIPT="$(command -v "${_SCRIPT}")" ;;
esac
REPO_ROOT="$(cd "$(dirname "${_SCRIPT}")/.." && pwd)"
STACK_NAME="EksNimStack"

# ── Cluster parameters (override via env vars) ─────────────────────────────

export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --output text --query 'Account')
export AWS_REGION="${AWS_DEFAULT_REGION:-us-east-1}"
export EKS_CLUSTER_NAME="eks-nim-platform"
export K8S_VERSION="${K8S_VERSION:-1.35}"
export CHATBOT_SA_NAME="${CHATBOT_SA_NAME:-nim-chatbot}"
export IAM_CHATBOT_ROLE="${IAM_CHATBOT_ROLE:-nim-chatbot-role}"
export AOSS_COLLECTION_NAME="nim-rag-store"
export DATA_POLICY_NAME="nim-rag-data"

echo ""
echo "── STEP 1: Deploy VPC, EFS, and OpenSearch with CDK ──────────────────"
cd "${REPO_ROOT}/infra"
python3 -m venv .venv 2>/dev/null || true
source .venv/bin/activate
pip install -q -r requirements.txt
cdk deploy --require-approval never
deactivate

echo ""
echo "── STEP 2: Read CDK outputs ────────────────────────────────────────────"

get_output() {
    aws cloudformation describe-stacks \
        --stack-name "${STACK_NAME}" \
        --region "${AWS_REGION}" \
        --query "Stacks[0].Outputs[?OutputKey=='${1}'].OutputValue" \
        --output text
}

export VPC_ID=$(get_output "VpcId")
PRIVATE_SUBNETS=$(get_output "PrivateSubnetIds")
PUBLIC_SUBNETS=$(get_output "PublicSubnetIds")
export EFS_FS_ID=$(get_output "EfsFileSystemId")
export AOSS_ENDPOINT=$(get_output "AossCollectionEndpoint")
export AOSS_COLLECTION_ARN=$(get_output "AossCollectionArn")
export AOSS_COLLECTION_ID=$(get_output "AossCollectionId")

export PRIVATE_SUBNET_1=$(echo "${PRIVATE_SUBNETS}" | cut -d',' -f1)
export PRIVATE_SUBNET_2=$(echo "${PRIVATE_SUBNETS}" | cut -d',' -f2)
export PUBLIC_SUBNET_1=$(echo "${PUBLIC_SUBNETS}" | cut -d',' -f1)
export PUBLIC_SUBNET_2=$(echo "${PUBLIC_SUBNETS}" | cut -d',' -f2)

export AZ_1=$(aws ec2 describe-subnets --subnet-ids "${PRIVATE_SUBNET_1}" --region "${AWS_REGION}" \
    --query "Subnets[0].AvailabilityZone" --output text)
export AZ_2=$(aws ec2 describe-subnets --subnet-ids "${PRIVATE_SUBNET_2}" --region "${AWS_REGION}" \
    --query "Subnets[0].AvailabilityZone" --output text)

echo ""
echo "╔══════════════════════════════════════════════════════════════════════╗"
echo "║            EKS NIM Platform — Architecture Summary                  ║"
echo "╠══════════════════════════════════════════════════════════════════════╣"
printf "║  Cluster name   : %-50s║\n" "${EKS_CLUSTER_NAME}"
printf "║  AWS account    : %-50s║\n" "${AWS_ACCOUNT_ID}"
printf "║  Region         : %-50s║\n" "${AWS_REGION}"
printf "║  Kubernetes     : %-50s║\n" "${K8S_VERSION}"
echo "╠══════════════════════════════════════════════════════════════════════╣"
printf "║  VPC            : %-50s║\n" "${VPC_ID}"
printf "║  Private subnet : %-50s║\n" "${PRIVATE_SUBNET_1} (${AZ_1})"
printf "║  Private subnet : %-50s║\n" "${PRIVATE_SUBNET_2} (${AZ_2})"
printf "║  Public subnet  : %-50s║\n" "${PUBLIC_SUBNET_1} (${AZ_1})"
printf "║  Public subnet  : %-50s║\n" "${PUBLIC_SUBNET_2} (${AZ_2})"
echo "╠══════════════════════════════════════════════════════════════════════╣"
printf "║  Node mode      : %-50s║\n" "EKS Auto Mode (Karpenter)"
printf "║  GPU nodes      : %-50s║\n" "G5 (A10G) — on demand via NIM Operator"
printf "║  EFS file sys   : %-50s║\n" "${EFS_FS_ID}"
echo "╠══════════════════════════════════════════════════════════════════════╣"
printf "║  OpenSearch     : %-50s║\n" "${AOSS_COLLECTION_NAME} (Serverless)"
printf "║  AOSS endpoint  : %-50s║\n" "${AOSS_ENDPOINT:0:50}"
printf "║  Add-ons        : %-50s║\n" "aws-efs-csi-driver (Pod Identity)"
echo "╚══════════════════════════════════════════════════════════════════════╝"
echo ""

read -r -p "Proceed with cluster creation? (y/n): " confirm
if [[ "${confirm}" != "y" ]]; then
    echo "Aborted. VPC, EFS, and OpenSearch remain deployed."
    echo "Run 'cdk destroy' in infra/ to remove them."
    exit 0
fi

echo ""
echo "── STEP 3: Generate eksctl cluster config ──────────────────────────────"
envsubst < "${REPO_ROOT}/cluster/cluster.yaml.template" > "${REPO_ROOT}/cluster/cluster.yaml"
echo "Written: cluster/cluster.yaml"

echo ""
echo "── STEP 4: Create EKS cluster with eksctl ──────────────────────────────"
echo "  This creates:"
echo "    - EKS Auto Mode cluster"
echo "    - aws-efs-csi-driver addon with Pod Identity"
echo "    - IAM role '${IAM_CHATBOT_ROLE}' + Pod Identity for chatbot"
echo ""
eksctl create cluster -f "${REPO_ROOT}/cluster/cluster.yaml"

echo ""
echo "── STEP 5: Create OpenSearch data access policy ────────────────────────"
# The chatbot IAM role was just created by eksctl.
# Retrieve its ARN and wire it to the OpenSearch Serverless collection.
CHATBOT_ROLE_ARN=$(aws iam get-role \
    --role-name "${IAM_CHATBOT_ROLE}" \
    --query 'Role.Arn' \
    --output text)
echo "  Chatbot role ARN: ${CHATBOT_ROLE_ARN}"

DATA_POLICY=$(printf '[{"Rules":[{"Resource":["collection/%s"],"Permission":["aoss:CreateCollectionItems","aoss:DeleteCollectionItems","aoss:UpdateCollectionItems","aoss:DescribeCollectionItems"],"ResourceType":"collection"},{"Resource":["index/%s/*"],"Permission":["aoss:CreateIndex","aoss:DeleteIndex","aoss:UpdateIndex","aoss:DescribeIndex","aoss:ReadDocument","aoss:WriteDocument"],"ResourceType":"index"}],"Principal":["%s"]}]' \
    "${AOSS_COLLECTION_NAME}" "${AOSS_COLLECTION_NAME}" "${CHATBOT_ROLE_ARN}")

aws opensearchserverless create-access-policy \
    --name "${DATA_POLICY_NAME}" \
    --type data \
    --policy "${DATA_POLICY}" \
    --region "${AWS_REGION}"
echo "  OpenSearch data access policy created: ${DATA_POLICY_NAME}"

echo ""
echo "── STEP 6: Verify ──────────────────────────────────────────────────────"
kubectl get nodes
echo ""
echo "EKS cluster ${EKS_CLUSTER_NAME} is ready."
echo ""
echo "Next steps:"
echo "  ./scripts/install-nim-operator.sh"
echo "  ./scripts/deploy-nim.sh"
echo "  ./scripts/deploy-chatbot.sh"
