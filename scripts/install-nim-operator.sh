#!/usr/bin/env bash
# install-nim-operator.sh — Install NVIDIA NFD and NIM Operator on EKS.
# Run after create-cluster.sh completes.
#
# What this does:
#   1. NVIDIA Node Feature Discovery (NFD) — labels GPU nodes for scheduling
#   2. NIM Operator (Helm) — manages NIMCache and NIMService custom resources
#   3. nim-service namespace
#   4. NGC registry secret — authenticates pulls from nvcr.io
#
# Prerequisite: NGC API key from https://build.nvidia.com (free account)
# Set: export NGC_API_KEY=your_key  (or enter interactively)

set -euo pipefail

NIM_OPERATOR_VERSION="${NIM_OPERATOR_VERSION:-v2.0.0}"
NFD_VERSION="${NFD_VERSION:-0.17.3}"
NAMESPACE_NIM="nim-service"
NAMESPACE_OPERATOR="nim-operator"
NAMESPACE_NFD="nfd"

echo "── STEP 1: Add Helm repos ──────────────────────────────────────────────"
helm repo add nvidia https://helm.ngc.nvidia.com/nvidia
helm repo add nfd https://kubernetes-sigs.github.io/node-feature-discovery/charts
helm repo update

echo ""
echo "── STEP 2: Install NVIDIA Node Feature Discovery (NFD) ─────────────────"
# NFD detects GPU hardware capabilities and labels nodes.
# The NIM Operator uses these labels to schedule NIMCache jobs
# and NIMService pods on nodes with the right GPU type.
helm install nfd nfd/node-feature-discovery \
    --namespace "${NAMESPACE_NFD}" \
    --create-namespace \
    --version "${NFD_VERSION}" \
    --wait

echo ""
echo "── STEP 3: Install NIM Operator ────────────────────────────────────────"
helm install nim-operator nvidia/k8s-nim-operator \
    --namespace "${NAMESPACE_OPERATOR}" \
    --create-namespace \
    --version "${NIM_OPERATOR_VERSION}" \
    --wait

echo ""
echo "── STEP 4: Create nim-service namespace ────────────────────────────────"
kubectl create namespace "${NAMESPACE_NIM}" 2>/dev/null \
    || echo "Namespace ${NAMESPACE_NIM} already exists."

echo ""
echo "── STEP 5: Create NGC secrets ──────────────────────────────────────────"
# Two secrets are required by NIMCache and NIMService:
#   ngc-secret     — Docker registry secret for pulling NIM container images from nvcr.io
#   ngc-api-secret — Generic secret with NGC_API_KEY for model weight download auth
if [[ -z "${NGC_API_KEY:-}" ]]; then
    echo "NGC API key required. Get yours at: https://build.nvidia.com"
    read -r -s -p "Enter NGC API key: " NGC_API_KEY
    echo ""
fi

kubectl create secret docker-registry ngc-secret \
    --namespace "${NAMESPACE_NIM}" \
    --docker-server=nvcr.io \
    --docker-username='$oauthtoken' \
    --docker-password="${NGC_API_KEY}" \
    2>/dev/null \
    || echo "Secret ngc-secret already exists in ${NAMESPACE_NIM}."

kubectl create secret generic ngc-api-secret \
    --namespace "${NAMESPACE_NIM}" \
    --from-literal=NGC_API_KEY="${NGC_API_KEY}" \
    2>/dev/null \
    || echo "Secret ngc-api-secret already exists in ${NAMESPACE_NIM}."

echo ""
echo "── STEP 6: Verify NFD is running ───────────────────────────────────────"
kubectl get pods -n "${NAMESPACE_NFD}"

echo ""
echo "── STEP 7: Verify NIM Operator is running ──────────────────────────────"
kubectl get pods -n "${NAMESPACE_OPERATOR}"

echo ""
echo "── STEP 8: Verify NIM CRDs are registered ──────────────────────────────"
kubectl get crd | grep nvidia

echo ""
echo "NIM Operator is ready. CRDs: NIMCache, NIMService, NIMPipeline."
echo "Next: ./scripts/deploy-nim.sh"
