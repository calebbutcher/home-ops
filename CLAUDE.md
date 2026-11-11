# home-ops

A k3s homelab that Flux runs from this repository. **This repository is public.**

## Layout

- `kubernetes/apps/<app>/`: one directory per app (HelmRelease, mostly bjw-s
  app-template, plus PVCs, ingress, CNPG Postgres, NetworkPolicies), listed in its
  `kustomization.yaml`.
- `kubernetes/infrastructure/`: cluster controllers and shared config.
  `kubernetes/flux/`: the Flux Kustomizations.
- `kubernetes/apps/monitoring/kube-prometheus-stack/`: alert rules
  (`prometheusrule-*.yaml`) and Alertmanager routing.
- `ansible/`: node provisioning and OS updates. `n8n/`: exported n8n workflows.
  `docs/`: runbooks.

## Rules

- Every change goes through a branch and a PR to `main`. Flux applies whatever merges.
- `*.sops.yaml` files are encrypted with SOPS. Never decrypt, edit or create them by
  hand, and never run kustomize transformers (top-level `namespace:` or labels) over them.
- No secrets, tokens, internal IPs or hostnames that aren't already in the repo. Never
  write which running service has which CVE.
- Commits are conventional (`fix(app): ...`). Commit and PR bodies say what changed,
  in short plain English.

## Checks

CI (`.github/workflows/validate.yml`) runs `kustomize build` + kubeconform, yamllint
(`.yamllint.yaml`) and gitleaks. The `automerge gate` check also blocks `claude/alert-*` PRs
until they have the `gate-approved` label.
