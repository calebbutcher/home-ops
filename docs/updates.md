# Updates: how they work

This cluster is **approve-then-apply**. Nothing upgrades on its own.

## The flow

1. **Everything is pinned to an exact version** — Helm chart versions in each
   `HelmRelease` (`spec.chart.spec.version`) and container image tags in the
   bjw-s `values.*.image.tag` fields. No floating ranges, no `latest`.
2. **[Renovate](https://docs.renovatebot.com/)** (Mend-hosted GitHub App) scans the repo on a
   weekly schedule and opens **one PR per available update**. Config: [`renovate.json`](../renovate.json).
3. **You approve by merging the PR.** Flux then reconciles `main` and applies the
   change to the cluster within ~30m.
4. **Awareness** = the **"Renovate Dependency Dashboard"** GitHub issue (a live list
   of every pending update) plus GitHub's normal PR notifications. Nothing is set
   to auto-merge.

### One-time setup (manual)

Install the Renovate app on the repo at <https://github.com/apps/renovate>, grant it
`calebbutcher/home-ops`, and merge the onboarding ("Configure Renovate") PR it opens.

### Seerr note

`seerr/seerr` publishes only a moving `latest` tag (no semver releases), so it is
pinned by **immutable digest** (`tag: latest@sha256:...`). Renovate's `pinDigests`
opens a PR whenever that digest changes.

## Follow-on: Discord notifications (not yet enabled)

GitHub already notifies on PRs and the Dependency Dashboard. To *also* push Flux
events (reconcile success/failure, applied upgrades) to a Discord channel, the
notification-controller is already installed — this is purely additive:

1. Create a Discord channel webhook (Channel → Integrations → Webhooks).
2. Store the webhook URL as a SOPS-encrypted Secret (`.sops.yaml` already covers
   `kubernetes/`), e.g. `kubernetes/flux/cluster/flux-system/discord-webhook.sops.yaml`.
3. Add a Flux `Provider` (type `discord`, `secretRef` → the webhook secret) and an
   `Alert` selecting the resources to report on (e.g. all `HelmRelease` and
   `Kustomization` events at `info` level). Reference:
   <https://fluxcd.io/flux/monitoring/alerts/>
4. Add both manifests to the `flux-system` kustomization and commit.
