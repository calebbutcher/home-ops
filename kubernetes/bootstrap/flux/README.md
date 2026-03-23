# Flux Bootstrap

After Ansible completes and the cluster is healthy, bootstrap Flux CD:

## Prerequisites

1. Install `flux` CLI: https://fluxcd.io/flux/installation/
2. Install `age` and `sops` for secret encryption
3. Verify cluster access: `kubectl get nodes`

## Bootstrap

```bash
export GITHUB_TOKEN=<your-github-personal-access-token>

flux bootstrap github \
  --owner=calebbutcher \
  --repository=home-ops \
  --branch=main \
  --path=kubernetes/flux/cluster \
  --personal \
  --private=false
```

## Post-Bootstrap: SOPS Secret

Create the Age key secret so Flux can decrypt SOPS-encrypted secrets:

```bash
# Generate a new age key (if you don't have one)
age-keygen -o age.key

# Create the secret in the cluster
cat age.key | kubectl create secret generic sops-age \
  --namespace=flux-system \
  --from-file=age.agekey=/dev/stdin

# Update .sops.yaml with your public key
# Store the private key securely (NOT in git)
```

## Verify

```bash
flux get all -A
kubectl get kustomizations -A
kubectl get helmreleases -A
```
