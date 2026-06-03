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

echo "Done — ${changed} file(s) updated ($([ "$changed" -eq 0 ] && echo 'already in sync' || echo 'committed by you'))."
