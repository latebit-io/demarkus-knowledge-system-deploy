#!/usr/bin/env bash
#
# Seed the broker's GCP Secret Manager secrets. See docs/runbook-secrets.md.
#
# Idempotent: a secret that already has a version is left alone (rotate with
# `gcloud secrets versions add`). The secret containers come from tofu
# (tofu/modules/platform-iam), so apply that first.
#
# Env:
#   PROJECT_ID          GCP project (default: projectId from deployment.yaml)
#   OIDC_CLIENT_ID      Google OAuth client id (prompted if unset)
#   OIDC_CLIENT_SECRET  Google OAuth client secret (prompted, hidden, if unset)
#
# Optional:
#   --signing-key FILE  existing broker ECDSA P-256 PEM (default: generate one)

set -euo pipefail

SIGNING_KEY=""
usage() { sed -n '3,15p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --signing-key) SIGNING_KEY="${2:-}"; shift 2 ;;
    -h|--help)     usage ;;
    *) echo "unknown arg: $1" >&2; usage ;;
  esac
done

die() { echo "seed-secrets: $*" >&2; exit 1; }
log() { echo "==> $*"; }

for cmd in gcloud jq openssl; do
  command -v "$cmd" >/dev/null 2>&1 || die "$cmd not on PATH"
done

if [[ -z "${PROJECT_ID:-}" ]]; then
  root="$(cd "$(dirname "$0")/.." && pwd)"
  PROJECT_ID="$(awk '/^projectId:/{print $2; exit}' "$root/deployment.yaml" 2>/dev/null || true)"
fi
[[ -n "$PROJECT_ID" ]] || die "PROJECT_ID not set and not found in deployment.yaml"

# True when the secret has at least one version; dies if the container is missing.
has_version() {
  local out
  out="$(gcloud secrets versions list "$1" --project "$PROJECT_ID" --limit=1 --format='value(name)')" \
    || die "cannot list versions of $1 (container missing? apply tofu first)"
  [[ -n "$out" ]]
}

# add_version ID: JSON value on stdin, never on argv.
add_version() {
  gcloud secrets versions add "$1" --project "$PROJECT_ID" --data-file=- >/dev/null
}

# ── broker-oidc-client ──────────────────────────────────────────────────────
if has_version broker-oidc-client; then
  log "broker-oidc-client already has a version, skipping"
else
  if [[ -z "${OIDC_CLIENT_ID:-}" ]]; then
    read -r -p "Google OAuth client id: " OIDC_CLIENT_ID
  fi
  if [[ -z "${OIDC_CLIENT_SECRET:-}" ]]; then
    read -r -s -p "Google OAuth client secret: " OIDC_CLIENT_SECRET; echo
  fi
  [[ -n "$OIDC_CLIENT_ID" ]]     || die "client id empty"
  [[ -n "$OIDC_CLIENT_SECRET" ]] || die "client secret empty"
  log "Adding broker-oidc-client"
  OIDC_CLIENT_ID="$OIDC_CLIENT_ID" OIDC_CLIENT_SECRET="$OIDC_CLIENT_SECRET" \
    jq -n '{client_id: env.OIDC_CLIENT_ID, client_secret: env.OIDC_CLIENT_SECRET}' | add_version broker-oidc-client
fi

# ── broker-jwks-signing-key ─────────────────────────────────────────────────
if has_version broker-jwks-signing-key; then
  log "broker-jwks-signing-key already has a version, skipping"
else
  tmp=""
  if [[ -z "$SIGNING_KEY" ]]; then
    tmp="$(mktemp)"
    trap '[[ -z "$tmp" ]] || rm -f "$tmp"' EXIT
    openssl ecparam -name prime256v1 -genkey -noout -out "$tmp"
    SIGNING_KEY="$tmp"
  fi
  [[ -r "$SIGNING_KEY" ]] || die "cannot read $SIGNING_KEY"
  # Reject junk early; a bad key only surfaces when the broker boots.
  grep -q "BEGIN .*PRIVATE KEY" "$SIGNING_KEY" || die "$SIGNING_KEY is not a PEM private key"
  log "Adding broker-jwks-signing-key"
  jq -n --rawfile pem "$SIGNING_KEY" '{pem: $pem}' | add_version broker-jwks-signing-key
fi

log "done. Verify: gcloud secrets versions list broker-oidc-client --project $PROJECT_ID"
