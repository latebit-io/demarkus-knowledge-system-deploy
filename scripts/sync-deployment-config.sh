#!/usr/bin/env bash
# Propagate the deployment-config value(s) that ArgoCD's ApplicationSet git
# generators can't read for themselves into the manifests.
#
# Why this exists: a git-files generator reads deployment.yaml, but it cannot
# read its OWN repo URL from the file it's reading (chicken-and-egg). So every
# per-app ApplicationSet — and the root ApplicationSet — must carry the git
# generator repoURL as a literal. deployment.yaml's `repoURL` is the single
# source of truth; this script copies it into those generators.
#
# After forking and editing deployment.yaml's `repoURL`, run this once —
# otherwise the generators keep rendering from UPSTREAM's deployment.yaml.
#
# Idempotent: re-running with an unchanged deployment.yaml is a no-op.
# Usage: bash scripts/sync-deployment-config.sh
set -euo pipefail

cd "$(dirname "$0")/.." || exit 1 # repo root

command -v yq >/dev/null 2>&1 || { echo "yq is required" >&2; exit 2; }

REPO_URL="$(yq -r '.repoURL' deployment.yaml)"
[ -n "$REPO_URL" ] && [ "$REPO_URL" != "null" ] || { echo "deployment.yaml: repoURL is required" >&2; exit 2; }

echo "deployment.yaml repoURL = $REPO_URL"
echo "projectId = $(yq -r '.projectId' deployment.yaml), region = $(yq -r '.region' deployment.yaml)"
echo "Propagating to ApplicationSet git generators…"

changed=0
# Match ONLY the git-generator self-reference: a github.com/<org>/<repo>.git
# URL. Chart sources use ghcr.io / charts.*.io / *.github.io — never a .git
# path — so they are never touched.
while IFS= read -r f; do
  before="$(cat "$f")"
  sed -E -i.bak "s#(repoURL:[[:space:]]*)https://github\.com/[^[:space:]]+\.git#\1${REPO_URL}#g" "$f"
  rm -f "$f.bak"
  if [ "$before" != "$(cat "$f")" ]; then
    echo "  updated: $f"
    changed=$((changed + 1))
  fi
done < <(grep -rlE 'repoURL:[[:space:]]*https://github\.com/[^[:space:]]+\.git' apps platform bootstrap 2>/dev/null)

# External Secrets store: its project, cluster location and the ESO service
# account annotation are literals (no templating for a plain Application).
PROJECT_ID="$(yq -r '.projectId' deployment.yaml)"
REGION="$(yq -r '.region' deployment.yaml)"
[ -n "$PROJECT_ID" ] && [ "$PROJECT_ID" != "null" ] || { echo "deployment.yaml: projectId is required" >&2; exit 2; }
[ -n "$REGION" ] && [ "$REGION" != "null" ] || { echo "deployment.yaml: region is required" >&2; exit 2; }

STORE=platform/external-secrets/cluster-secret-store-gcp.yaml
ESO_APP=platform/external-secrets/application.yaml
before="$(cat "$STORE" "$ESO_APP")"
P="$PROJECT_ID" L="${REGION}-a" yq -i \
  '.spec.provider.gcpsm.projectID = strenv(P) | .spec.provider.gcpsm.auth.workloadIdentity.clusterLocation = strenv(L)' "$STORE"
sed -E -i.bak "s#(iam\.gke\.io/gcp-service-account:[[:space:]]*external-secrets@)[^.[:space:]]+(\.iam\.gserviceaccount\.com)#\1${PROJECT_ID}\2#" "$ESO_APP"
rm -f "$ESO_APP.bak"
if [ "$before" != "$(cat "$STORE" "$ESO_APP")" ]; then
  echo "  updated: $STORE, $ESO_APP"
  changed=$((changed + 1))
fi

echo "Done — ${changed} file(s) updated ($([ "$changed" -eq 0 ] && echo 'already in sync' || echo 'committed by you'))."
