#!/usr/bin/env bash
# deploy-nim.sh — Deploy GPU NodePool, NIMCaches, and NIMServices on EKS.
# Run after install-nim-operator.sh completes.
#
# What this does:
#   1. EFS StorageClass (ReadWriteMany — required for NIMCache PVCs)
#   2. GPU NodePool (Karpenter provisions G5 instances on demand)
#   3. NIMCache — download LLM + embedding weights to EFS (~10-15 min first run)
#   4. NIMService — launch inference pods from cached weights (~5 min)
#   5. Smoke test both endpoints
#
# After this script completes, both NIMs are reachable at cluster-internal DNS:
#   LLM:       http://meta-llama-3-2-1b-instruct.nim-service.svc.cluster.local:8000/v1
#   Embedding: http://nv-embedqa-e5-v5.nim-service.svc.cluster.local:8000/v1

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
STACK_NAME="EksNimStack"
REGION="${AWS_DEFAULT_REGION:-us-east-1}"
NAMESPACE="nim-service"

get_output() {
    aws cloudformation describe-stacks \
        --stack-name "${STACK_NAME}" \
        --region "${REGION}" \
        --query "Stacks[0].Outputs[?OutputKey=='${1}'].OutputValue" \
        --output text
}

export EFS_FS_ID=$(get_output "EfsFileSystemId")

echo "── STEP 1: Apply EFS StorageClass ─────────────────────────────────────"
envsubst < "${REPO_ROOT}/nim/efs-storageclass.yaml.template" | kubectl apply -f -

echo ""
echo "── STEP 2: Apply GPU NodePool ──────────────────────────────────────────"
kubectl apply -f "${REPO_ROOT}/nim/gpu-nodepool.yaml"
echo "GPU NodePool declared. Karpenter will provision G5 nodes when NIMCache"
echo "jobs and NIMService pods are scheduled."

echo ""
echo "── STEP 3: Apply NIMCaches ─────────────────────────────────────────────"
kubectl apply -f "${REPO_ROOT}/nim/nimcaches.yaml"
echo "NIMCache resources created. The NIM Operator is now downloading model"
echo "weights from NVIDIA NGC to EFS."

echo ""
echo "── STEP 4: Wait for NIMCaches to be ready ──────────────────────────────"
echo "  First-run download: 10-15 minutes per model."
echo "  Subsequent runs use the EFS cache: ~5 minutes."
echo "  Monitor progress:"
echo "    kubectl get nimcache -n ${NAMESPACE} -w"
echo "    kubectl get pods -n ${NAMESPACE}"
echo ""

wait_for_nimcache() {
    local name="$1"
    local timeout=1200
    local elapsed=0
    echo "  Waiting for NIMCache/${name}..."
    while true; do
        STATE=$(kubectl get nimcache "${name}" -n "${NAMESPACE}" \
            -o jsonpath='{.status.state}' 2>/dev/null || echo "")
        if [[ "${STATE}" == "Ready" ]]; then
            echo "  NIMCache/${name} is ready."
            return 0
        fi
        if [[ ${elapsed} -ge ${timeout} ]]; then
            echo "  Timed out waiting for NIMCache/${name} (state: ${STATE})"
            return 1
        fi
        sleep 15
        elapsed=$((elapsed + 15))
    done
}

wait_for_nimcache "meta-llama-3-2-1b-instruct"
wait_for_nimcache "nv-embedqa-e5-v5"

echo ""
echo "── STEP 5: Apply NIMServices ───────────────────────────────────────────"
kubectl apply -f "${REPO_ROOT}/nim/nimservices.yaml"

echo ""
echo "── STEP 6: Wait for NIMServices to be ready ────────────────────────────"
kubectl rollout status deployment/meta-llama-3-2-1b-instruct \
    -n "${NAMESPACE}" --timeout=300s
kubectl rollout status deployment/nv-embedqa-e5-v5 \
    -n "${NAMESPACE}" --timeout=300s

echo ""
echo "── STEP 7: Smoke test — LLM endpoint ──────────────────────────────────"
kubectl run nim-test --rm -it --restart=Never \
    --image=curlimages/curl:8.9.0 \
    --namespace default \
    -- curl -s \
       -H "Content-Type: application/json" \
       -d '{"model":"meta/llama-3.2-1b-instruct","messages":[{"role":"user","content":"Hello from NIM"}],"max_tokens":20}' \
       http://meta-llama-3-2-1b-instruct.nim-service.svc.cluster.local:8000/v1/chat/completions

echo ""
echo "── STEP 8: Smoke test — Embedding endpoint ─────────────────────────────"
kubectl run nim-embed-test --rm -it --restart=Never \
    --image=curlimages/curl:8.9.0 \
    --namespace default \
    -- curl -s \
       -H "Content-Type: application/json" \
       -d '{"input":"test sentence for embedding","model":"nvidia/llama-3.2-nv-embedqa-1b-v2","input_type":"query"}' \
       http://nv-embedqa-e5-v5.nim-service.svc.cluster.local:8000/v1/embeddings

echo ""
echo "Both NIMs are deployed and responding."
echo "Next: ./scripts/deploy-chatbot.sh"
