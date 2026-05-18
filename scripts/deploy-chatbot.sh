#!/usr/bin/env bash
# deploy-chatbot.sh — Deploy the Gradio RAG chatbot connecting NIMs + OpenSearch.
# Run after deploy-nim.sh completes.
#
# The chatbot pod:
#   - Calls the LLM NIM for response generation
#   - Calls the embedding NIM for document/query vectorization
#   - Reads/writes vectors in OpenSearch Serverless via Pod Identity (no keys)
#
# Build the chatbot image from:
#   https://github.com/aws-samples/eks-auto-mode-nvidia-nim-rag
# Then set: export CHATBOT_IMAGE=your-registry/nim-rag-chatbot:latest

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
STACK_NAME="EksNimStack"
REGION="${AWS_DEFAULT_REGION:-us-east-1}"

get_output() {
    aws cloudformation describe-stacks \
        --stack-name "${STACK_NAME}" \
        --region "${REGION}" \
        --query "Stacks[0].Outputs[?OutputKey=='${1}'].OutputValue" \
        --output text
}

export AOSS_ENDPOINT=$(get_output "AossCollectionEndpoint")
export AWS_REGION="${REGION}"
export CHATBOT_SA_NAME="${CHATBOT_SA_NAME:-nim-chatbot}"

if [[ -z "${CHATBOT_IMAGE:-}" ]]; then
    echo "CHATBOT_IMAGE is not set."
    echo "Build the chatbot image from: https://github.com/aws-samples/eks-auto-mode-nvidia-nim-rag"
    echo "Then: export CHATBOT_IMAGE=your-registry/nim-rag-chatbot:latest"
    exit 1
fi

echo "── STEP 1: Deploy chatbot ───────────────────────────────────────────────"
envsubst < "${REPO_ROOT}/chatbot/deployment.yaml.template" | kubectl apply -f -
kubectl apply -f "${REPO_ROOT}/chatbot/service.yaml"

echo ""
echo "── STEP 2: Wait for chatbot to be ready ────────────────────────────────"
echo "  Waiting for chatbot pod to start..."
ELAPSED=0
TIMEOUT=300
while true; do
    STATUS=$(kubectl get deployment nim-rag-chatbot \
        -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    if [[ "${STATUS}" == "1" ]]; then
        echo "  Chatbot is ready."
        break
    fi
    if [[ ${ELAPSED} -ge ${TIMEOUT} ]]; then
        echo "  Timed out waiting for chatbot (check: kubectl logs -l app=nim-rag-chatbot)"
        exit 1
    fi
    sleep 10
    ELAPSED=$((ELAPSED + 10))
done

echo ""
echo "── STEP 3: Port-forward for local access ───────────────────────────────"
echo "  Chatbot UI available at: http://localhost:7860"
echo "  Upload a PDF, ask questions, get RAG-grounded answers."
echo "  Press Ctrl+C to stop."
echo ""
kubectl port-forward service/nim-rag-chatbot 7860:7860
