# NIM Live Run — Debugging Reference

Issues encountered during the live run of the blog, in sequence.
Includes root cause, fix, and commands used to investigate.

---

## ⚠️ Prerequisite — Request G Instance Quota BEFORE Starting

**Lesson learned from this run:** G instance (GPU) vCPU quota defaults to 0 in most
AWS accounts. NIMCache and NIMService pods require GPU nodes (G5 instances). Without
quota, Karpenter silently fails to provision nodes and pods stay Pending indefinitely
with no obvious error — you won't know why until you dig into nodeclaims.

**Do this before you create the cluster — not after:**

```bash
# Check current G instance quota
aws service-quotas get-service-quota \
  --service-code ec2 \
  --quota-code L-DB2E81BA

# If Value is 0.0, request an increase immediately
# 32 vCPUs = 2x g5.2xlarge (8 vCPU each) + headroom for retries
aws service-quotas request-service-quota-increase \
  --service-code ec2 \
  --quota-code L-DB2E81BA \
  --desired-value 32

# Monitor until APPROVED
aws service-quotas get-requested-service-quota-change \
  --request-id <id-from-above>
```

**What to expect:**
- Status goes: `PENDING` → `CASE_OPENED` → `APPROVED`
- `CASE_OPENED` means a human reviewer is involved — allow a few hours
- AWS sends an email update when the case moves
- Do not start the cluster until status is `APPROVED`

**Blog callout for STEP 1:**
> 👉 **G Instance vCPU Quota** — Check your quota before starting. The default is 0
> in most accounts. Request 32 vCPUs (`L-DB2E81BA`) and wait for `APPROVED` status
> before proceeding. A human reviewer handles it — allow a few hours. Starting the
> cluster before approval means NIMCache pods will be stuck Pending with no clear error.

---

## Issue 1: AOSS Encryption Policy — Array vs Object (STEP 2)

### What happened
`create-cluster.sh` failed on first run with:
```
CREATE_FAILED | AWS::OpenSearchServerless::SecurityPolicy | AossEncryptionPolicy
Policy json is invalid, error: [$: array found, object expected]
```

### Root cause
`infra/eks_nim/eks_nim_stack.py` had the encryption policy wrapped in a list `[{...}]`.
The OpenSearch Serverless API requires an object `{...}` for encryption policies.

### The AOSS API quirk
OpenSearch Serverless is inconsistent between policy types:
- **Encryption policy** → object `{...}`
- **Network policy** → array `[{...}]`

We initially fixed both to objects — correct for encryption, wrong for network.
Second run failed with the opposite error on the network policy.

### Fix
```python
# infra/eks_nim/eks_nim_stack.py

# Encryption policy — object
policy=json.dumps({
    "Rules": [...],
    "AWSOwnedKey": True,
})

# Network policy — array
policy=json.dumps([{
    "Rules": [...],
    "AllowFromPublic": False,
    "SourceVPCEs": [...],
}])
```

### Commands to clean up and retry
```bash
# Delete the rolled-back stack
aws cloudformation delete-stack --stack-name EksNimStack

# Wait for deletion (~1 min)
aws cloudformation wait stack-delete-complete --stack-name EksNimStack

# Re-run
./scripts/create-cluster.sh
```

---

## Issue 2: Missing Step — build-chatbot.sh Skipped (STEP 5)

### What happened
After `install-nim-operator.sh` completed, we jumped straight to `deploy-nim.sh` —
skipping `build-chatbot.sh`. The blog has five scripts in this order:

```
1. create-cluster.sh
2. install-nim-operator.sh
3. build-chatbot.sh       ← skipped
4. deploy-nim.sh
5. deploy-chatbot.sh
```

### Root cause (two contributors)
1. **The script itself** — `install-nim-operator.sh` ended with `Next: ./scripts/deploy-nim.sh`,
   pointing directly to deploy-nim and omitting build-chatbot entirely.
2. **Sequence not cross-checked** — we followed the script's "Next" guidance without
   verifying it against the blog's step order.

### Fix
Updated the `Next:` guidance at the end of `install-nim-operator.sh`:
```bash
echo "Next:"
echo "  ./scripts/build-chatbot.sh   # build and push chatbot image to ECR"
echo "  ./scripts/deploy-nim.sh      # deploy NIMCache + NIMService (run in parallel with build-chatbot.sh)"
```

### Key point for the blog
`build-chatbot.sh` and `deploy-nim.sh` are independent — they can run in parallel.
`deploy-nim.sh` takes 20–30 min for first-run NIMCache downloads. Start the chatbot
build in a second terminal while NIMCache runs.

---

## Issue 3: NIMCache Pods Stuck Pending — NodeSelector Label (STEP 6)

### What happened
After `deploy-nim.sh`, both NIMCache pods stayed `Pending` indefinitely.
GPU NodePool showed `NODES: 0` — Karpenter never provisioned a GPU node.

### Investigation commands (in sequence)
```bash
# Check NIMCache status — no STATUS, no PVC = not progressing
kubectl get nimcache -n nim-service

# Check pods — both Pending
kubectl get pods -n nim-service

# Check nodes — only 2 CPU nodes, no GPU nodes
kubectl get nodes

# Check NodePool — NODES: 0, Karpenter isn't provisioning
kubectl get nodepool gpu-node-pool

# Describe pod — see the scheduling error
kubectl describe pod meta-llama-3-2-1b-instruct-pod -n nim-service | tail -20

# Check Karpenter logs
kubectl logs -n kube-system -l app.kubernetes.io/name=karpenter --tail=30
```

### First error
```
Failed to schedule pod, did not tolerate taint (taint=CriticalAddonsOnly:NoSchedule);
incompatible requirements, label "NodeGroupType" does not have known values
```

### Root cause (first)
`nim/nimcaches.yaml` and `nim/nimservices.yaml` used `NodeGroupType: gpu-node-pool`
as a nodeSelector. EKS Auto Mode's Karpenter does not recognize `NodeGroupType` as
a well-known label and cannot satisfy the requirement.

### Fix (first)
Replace `NodeGroupType: gpu-node-pool` with `karpenter.sh/nodepool: gpu-node-pool` —
the label Karpenter natively applies to every node it provisions from a named NodePool.

```yaml
# Before
nodeSelector:
  NodeGroupType: gpu-node-pool
  type: karpenter

# After
nodeSelector:
  karpenter.sh/nodepool: gpu-node-pool
```

Applied to both `nim/nimcaches.yaml` and `nim/nimservices.yaml`.

### Re-apply after fix
```bash
kubectl delete nimcache --all -n nim-service
git pull
kubectl apply -f nim/nimcaches.yaml
kubectl get pods -n nim-service -w
```

---

## Issue 4: NIMCache Pods Still Pending — G Instance Quota = 0 (STEP 6)

### What happened
After the nodeSelector fix, pods were still Pending.
Karpenter was creating nodeclaims (`gpu-node-pool-*`) but they kept disappearing —
Karpenter provisioned, EC2 rejected, Karpenter retried in a loop.

### Investigation commands
```bash
# See all nodeclaims — GPU nodeclaims missing, only CPU nodes present
kubectl get nodeclaim

# Describe the latest GPU nodeclaim — already gone (NotFound)
kubectl describe nodeclaim gpu-node-pool-lz7xv

# Check G instance vCPU quota
aws service-quotas get-service-quota \
  --service-code ec2 \
  --quota-code L-DB2E81BA
```

### Root cause
G instance vCPU quota was `0.0` — the default for most AWS accounts.
Karpenter could declare nodeclaims but EC2 rejected every launch attempt silently.

### Fix
```bash
# Request quota increase — 32 vCPUs covers 2x g5.2xlarge (8 vCPU each) + headroom
aws service-quotas request-service-quota-increase \
  --service-code ec2 \
  --quota-code L-DB2E81BA \
  --desired-value 32

# Monitor approval status
aws service-quotas get-requested-service-quota-change \
  --request-id <id-from-above>
```

Watch for `Status` to move from `PENDING` → `CASE_OPENED` → `APPROVED`.

**What actually happened:**
- Request went to `CASE_OPENED` — assigned to a human reviewer, not auto-approved
- AWS Support email confirmed: "Addressing this request requires a collaboration
  with our internal teams"
- This is why the quota check belongs in STEP 1, not discovered mid-run

### Blog callout (add to STEP 6 as a warning, and STEP 1 as a prerequisite)
> 💡 **Before running deploy-nim.sh:** Check your G instance vCPU quota —
> it defaults to 0 in most accounts. If you followed the prerequisite in STEP 1,
> your quota is already approved. If not, NIMCache pods will stay Pending
> indefinitely with no obvious error in the pod logs.

---

## Quick Reference — Useful Commands During a NIM Run

```bash
# Watch NIMCache download progress
kubectl get nimcache -n nim-service -w
kubectl get pods -n nim-service -w

# Watch nodes being provisioned by Karpenter
kubectl get nodes -w
kubectl get nodeclaim

# Pod scheduling details
kubectl describe pod <pod-name> -n nim-service | tail -20

# Karpenter logs
kubectl logs -n kube-system -l app.kubernetes.io/name=karpenter --tail=50

# Check G instance quota
aws service-quotas get-service-quota \
  --service-code ec2 \
  --quota-code L-DB2E81BA

# Delete and re-apply NIMCaches (after a fix)
kubectl delete nimcache --all -n nim-service
kubectl apply -f nim/nimcaches.yaml

# Delete rolled-back CDK stack
aws cloudformation delete-stack --stack-name EksNimStack
aws cloudformation wait stack-delete-complete --stack-name EksNimStack
```
