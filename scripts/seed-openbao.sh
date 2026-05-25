#!/usr/bin/env bash
#
# Seed OpenBao for the demarkus broker (Phase 6).
#
# Idempotent: each step checks current state before mutating, so re-runs
# are safe. See docs/runbook-openbao-seed.md for the human-driven flow
# this script slots into (root rotation, port-forward, verification).
#
# Required env:
#   BAO_ADDR   — e.g. http://127.0.0.1:8200 (via kubectl port-forward)
#   BAO_TOKEN  — a root or sufficiently-privileged token
#
# Required args:
#   --oidc-env     path to a key=value file with client_id + client_secret
#   --signing-key  path to the broker's ECDSA P-256 PEM
#
# Optional:
#   --broker-namespace   k8s namespace where the broker will run (default: demarkus-broker)
#   --broker-ksa         k8s service account name for the broker (default: demarkus-broker)

set -euo pipefail

BROKER_NAMESPACE="demarkus-broker"
BROKER_KSA="demarkus-broker"
OIDC_ENV=""
SIGNING_KEY=""

usage() {
  sed -n '3,21p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --oidc-env)         OIDC_ENV="$2"; shift 2 ;;
    --signing-key)      SIGNING_KEY="$2"; shift 2 ;;
    --broker-namespace) BROKER_NAMESPACE="$2"; shift 2 ;;
    --broker-ksa)       BROKER_KSA="$2"; shift 2 ;;
    -h|--help)          usage ;;
    *) echo "unknown arg: $1" >&2; usage ;;
  esac
done

die() { echo "seed-openbao: $*" >&2; exit 1; }
log() { echo "==> $*"; }

# ── Preflight ─────────────────────────────────────────────────────────────
for cmd in bao jq; do
  command -v "$cmd" >/dev/null 2>&1 || die "$cmd not on PATH"
done
[[ -n "${BAO_ADDR:-}" ]]  || die "BAO_ADDR not set (e.g. http://127.0.0.1:8200)"
[[ -n "${BAO_TOKEN:-}" ]] || die "BAO_TOKEN not set"
[[ -n "$OIDC_ENV"     ]]  || die "--oidc-env required"
[[ -n "$SIGNING_KEY"  ]]  || die "--signing-key required"
[[ -r "$OIDC_ENV"     ]]  || die "cannot read $OIDC_ENV"
[[ -r "$SIGNING_KEY"  ]]  || die "cannot read $SIGNING_KEY"

# Parse oidc env file: only client_id= / client_secret= lines, no eval.
CLIENT_ID="$(awk -F= '$1=="client_id"{ sub(/^client_id=/, ""); print; exit }' "$OIDC_ENV")"
CLIENT_SECRET="$(awk -F= '$1=="client_secret"{ sub(/^client_secret=/, ""); print; exit }' "$OIDC_ENV")"
[[ -n "$CLIENT_ID"     ]] || die "client_id missing in $OIDC_ENV"
[[ -n "$CLIENT_SECRET" ]] || die "client_secret missing in $OIDC_ENV"

# Validate PEM shape early so a typo in --signing-key doesn't land a junk
# value into OpenBao that only surfaces when the broker boots.
grep -q "BEGIN .*PRIVATE KEY" "$SIGNING_KEY" || die "$SIGNING_KEY does not look like a PEM private key"

bao status >/dev/null || die "bao status failed against $BAO_ADDR"

# ── 1. Kubernetes auth method ─────────────────────────────────────────────
log "Ensuring auth/kubernetes/ is enabled"
if bao auth list -format=json | jq -e '."kubernetes/"' >/dev/null; then
  log "  already enabled — skipping enable"
else
  bao auth enable kubernetes
fi

log "Configuring auth/kubernetes/config"
bao write auth/kubernetes/config \
  kubernetes_host="https://kubernetes.default.svc:443" >/dev/null

# ── 2. kv-v2 secrets engine at secret/ ────────────────────────────────────
log "Ensuring kv-v2 is mounted at secret/"
if bao secrets list -format=json | jq -e '."secret/" | select(.type=="kv" and (.options.version=="2" or .version==2))' >/dev/null; then
  log "  already mounted — skipping enable"
elif bao secrets list -format=json | jq -e '."secret/"' >/dev/null; then
  die "secret/ is mounted but not kv-v2; remount as kv-v2 before seeding"
else
  bao secrets enable -path=secret -version=2 kv
fi

# ── 3. Seed broker secrets ────────────────────────────────────────────────
log "Writing secret/broker/oidc-client"
bao kv put secret/broker/oidc-client \
  client_id="$CLIENT_ID" \
  client_secret="$CLIENT_SECRET" >/dev/null

log "Writing secret/broker/jwks-signing-key"
bao kv put secret/broker/jwks-signing-key \
  pem=@"$SIGNING_KEY" >/dev/null

# ── 4. Broker policy ──────────────────────────────────────────────────────
log "Writing policy 'broker'"
bao policy write broker - <<'POLICY' >/dev/null
path "secret/data/broker/*" {
  capabilities = ["read"]
}
POLICY

# ── 5. Kubernetes auth role for the broker ────────────────────────────────
log "Writing auth/kubernetes/role/broker (ns=$BROKER_NAMESPACE ksa=$BROKER_KSA)"
bao write auth/kubernetes/role/broker \
  bound_service_account_names="$BROKER_KSA" \
  bound_service_account_namespaces="$BROKER_NAMESPACE" \
  policies="broker" \
  ttl="1h" >/dev/null

log "done. Verify with: bao kv get secret/broker/oidc-client"
