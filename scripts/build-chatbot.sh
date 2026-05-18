#!/usr/bin/env bash
# build-chatbot.sh — Clone sample chatbot repo, build Docker image, push to ECR.
# Run this before deploy-chatbot.sh.
#
# What this does:
#   1. Clone aws-samples/sample-rag-chatbot-nim into build/sample-rag-chatbot-nim/
#   2. Build the Docker image from build/sample-rag-chatbot-nim/client/
#   3. Create the ECR repository if it doesn't exist
#   4. Login to ECR and push the image
#   5. Print the export command to use with deploy-chatbot.sh
#
# Prerequisites:
#   - Docker running locally (docker info)
#   - AWS CLI configured with ECR permissions
#   - git installed
#
# After this completes, run:
#   export CHATBOT_IMAGE=<printed value>
#   ./scripts/deploy-chatbot.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

AWS_ACCOUNT_ID=$(aws sts get-caller-identity --output text --query 'Account')
AWS_REGION="${AWS_DEFAULT_REGION:-us-east-1}"
ECR_REPO_NAME="${ECR_REPO_NAME:-nim-rag-chatbot}"
IMAGE_TAG="${IMAGE_TAG:-latest}"
SAMPLE_REPO_URL="https://github.com/aws-samples/sample-rag-chatbot-nim"
BUILD_DIR="${REPO_ROOT}/build/sample-rag-chatbot-nim"
ECR_REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
FULL_IMAGE="${ECR_REGISTRY}/${ECR_REPO_NAME}:${IMAGE_TAG}"

echo "── STEP 1: Verify Docker is running ────────────────────────────────────"
if ! docker info > /dev/null 2>&1; then
    echo "Docker is not running. Start Docker Desktop and re-run."
    exit 1
fi
echo "Docker is running."

echo ""
echo "── STEP 2: Clone sample chatbot repo ───────────────────────────────────"
if [[ -d "${BUILD_DIR}/.git" ]]; then
    echo "Repo already cloned at build/sample-rag-chatbot-nim — pulling latest."
    git -C "${BUILD_DIR}" pull --ff-only
else
    mkdir -p "${REPO_ROOT}/build"
    git clone "${SAMPLE_REPO_URL}" "${BUILD_DIR}"
fi


# Pin gradio>=5.0 — upstream requirements.txt has no version pin and installs
# an older version that doesn't support the type="messages" arg in ChatInterface.
sed -i '' 's/^gradio$/gradio>=5.0/' "${BUILD_DIR}/client/requirements.txt"
echo "Pinned gradio>=5.0 in requirements.txt"

echo ""
echo "── STEP 3: Build Docker image ──────────────────────────────────────────"
echo "  Context: build/sample-rag-chatbot-nim/client/"
docker build \
    --platform linux/amd64 \
    -t "${ECR_REPO_NAME}:${IMAGE_TAG}" \
    "${BUILD_DIR}/client"
echo "Image built: ${ECR_REPO_NAME}:${IMAGE_TAG}"

echo ""
echo "── STEP 4: Create ECR repository (if it doesn't exist) ─────────────────"
aws ecr describe-repositories \
    --repository-names "${ECR_REPO_NAME}" \
    --region "${AWS_REGION}" > /dev/null 2>&1 \
    || aws ecr create-repository \
        --repository-name "${ECR_REPO_NAME}" \
        --region "${AWS_REGION}" \
        --image-scanning-configuration scanOnPush=true
echo "ECR repository: ${ECR_REGISTRY}/${ECR_REPO_NAME}"

echo ""
echo "── STEP 5: Login to ECR ────────────────────────────────────────────────"
aws ecr get-login-password --region "${AWS_REGION}" \
    | docker login --username AWS --password-stdin "${ECR_REGISTRY}"

echo ""
echo "── STEP 6: Tag and push image ──────────────────────────────────────────"
docker tag "${ECR_REPO_NAME}:${IMAGE_TAG}" "${FULL_IMAGE}"
docker push "${FULL_IMAGE}"
echo "Pushed: ${FULL_IMAGE}"

echo ""
echo "╔══════════════════════════════════════════════════════════════════════╗"
echo "║                  Chatbot image ready                                ║"
echo "╠══════════════════════════════════════════════════════════════════════╣"
printf "║  Image: %-61s║\n" "${FULL_IMAGE}"
echo "╠══════════════════════════════════════════════════════════════════════╣"
echo "║  Next — run these two commands:                                      ║"
printf "║    export CHATBOT_IMAGE=%s\n" "${FULL_IMAGE}"
echo "║    ./scripts/deploy-chatbot.sh                                       ║"
echo "╚══════════════════════════════════════════════════════════════════════╝"
