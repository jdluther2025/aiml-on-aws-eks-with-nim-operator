# EKS Auto Mode + NVIDIA NIM Operator + RAG

Infrastructure-as-Code for deploying NVIDIA NIMs on Amazon EKS Auto Mode and building a RAG pipeline on top. Companion code for the AI-ML on AWS blog series.

## What This Builds

```
User → Gradio UI (localhost:7860)
           ↓
        LangChain
           ↓ ─────────────────────────────────
           ↓                                   ↓
  NIM: nv-embedqa-e5-v5          NIM: meta-llama-3.2-1b-instruct
  (embedding, CPU pod)           (LLM, GPU pod — G5 / A10G)
           ↓
  OpenSearch Serverless (vector search, VPC PrivateLink)
```

All services run inside EKS. NIM pods communicate via cluster-internal DNS — no external inference API traffic, no exposed keys.

## Infrastructure

| Component | Service | Role |
|---|---|---|
| Kubernetes | EKS Auto Mode | Automated GPU node provisioning (Karpenter built in) |
| GPU nodes | G5 instances (A10G) | On-demand, provisioned by NIM Operator |
| Model storage | Amazon EFS | ReadWriteMany — required for NIMCache |
| Vector DB | OpenSearch Serverless | Private access via VPC PrivateLink endpoint |
| Model registry | NVIDIA NGC | NIM container images + model weights |
| IaC | AWS CDK + eksctl | VPC/EFS/OpenSearch via CDK; cluster via eksctl |

## Prerequisites

- AWS CLI configured (`aws sts get-caller-identity`)
- CDK bootstrapped (`cdk bootstrap`)
- Tools: `eksctl`, `kubectl`, `helm`, `envsubst`
- NVIDIA NGC API key — free account at [build.nvidia.com](https://build.nvidia.com)
- Sufficient EC2 quota for G5 instances in your region

## Repository Layout

```
infra/          CDK stack — VPC, EFS, OpenSearch Serverless
cluster/        eksctl cluster template (Auto Mode + Pod Identity)
nim/            NIM Operator manifests — NodePool, StorageClass, NIMCache, NIMService
chatbot/        Gradio RAG chatbot Kubernetes manifests
scripts/        Automation scripts (run in order)
```

## How to Run

Run scripts in order from the repo root.

### Step 1 — Cluster + infrastructure

```bash
./scripts/create-cluster.sh
```

Creates VPC, EFS, and OpenSearch Serverless with CDK, then creates the EKS cluster with eksctl (Auto Mode). Also creates the chatbot IAM role and wires it to the OpenSearch data access policy.

### Step 2 — NIM Operator

```bash
export NGC_API_KEY=your_ngc_api_key
./scripts/install-nim-operator.sh
```

Installs NVIDIA NFD and NIM Operator via Helm. Creates the `nim-service` namespace and the NGC registry secret for pulling from `nvcr.io`.

### Step 3 — Deploy NIMs

```bash
./scripts/deploy-nim.sh
```

Applies the GPU NodePool, NIMCache resources (model download, ~10-15 min first run), and NIMService resources. Smoke-tests both inference endpoints before finishing.

### Step 4 — Deploy chatbot

```bash
export CHATBOT_IMAGE=your-registry/nim-rag-chatbot:latest
./scripts/deploy-chatbot.sh
```

Deploys the Gradio RAG chatbot and port-forwards to `http://localhost:7860`.

Build the chatbot image from the AWS sample code:
[aws-samples/eks-auto-mode-nvidia-nim-rag](https://github.com/aws-samples/eks-auto-mode-nvidia-nim-rag)

## Teardown

```bash
./scripts/destroy-cluster.sh
```

Deletes K8s resources, OpenSearch data access policy, EKS cluster, EFS mount targets, and the CDK stack. Verifies nothing is left running.

## Cost Notes

- **G5 instances**: billed per second. The GPU NodePool is configured with `consolidateAfter: 30s` to terminate empty nodes quickly.
- **EFS**: Elastic throughput — you pay per GB transferred, not provisioned.
- **OpenSearch Serverless**: billed per OCU (OpenSearch Compute Unit) consumed.
- **EKS Auto Mode**: control plane + managed nodes. No idle GPU cost when NIMService pods are not scheduled.

Always run `./scripts/destroy-cluster.sh` when done.

## Reference

- [Building a RAG Chat-Based Assistant on Amazon EKS Auto Mode and NVIDIA NIMs](https://aws.amazon.com/blogs/machine-learning/building-a-rag-chat-based-assistant-on-amazon-eks-auto-mode-and-nvidia-nims/) — AWS ML Blog
- [NVIDIA NIM for LLMs](https://docs.nvidia.com/nim/large-language-models/latest/index.html) — NIM documentation
- [NIM Operator](https://github.com/NVIDIA/k8s-nim-operator) — Kubernetes operator for NIMCache and NIMService CRDs
