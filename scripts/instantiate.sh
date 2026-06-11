#!/usr/bin/env bash
# instantiate.sh — take a fresh fork of this template to a live knowledge system.
#
# Phased and idempotent. The CONFIG phase only writes files (safe, re-runnable).
# The CLOUD phases (bootstrap state, tofu apply) mutate real GCP resources and
# are each gated behind an explicit y/N. The irreducibly-MANUAL steps (Google /
# GitHub OAuth apps, DNS delegation, OpenBao seed) can't be safely automated —
# the script pauses and points you at the exact runbook + commands.
#
# Re-run any time: already-done steps are detected and skipped. Nothing here is
# destructive without confirmation.
#
# Usage: bash scripts/instantiate.sh
set -euo pipefail

cd "$(dirname "$0")/.." || exit 1 # repo root

# ── output helpers ─────────────────────────────────────────────────────────
bold() { printf '\033[1m%s\033[0m\n' "$*"; }
info() { printf '  %s\n' "$*"; }
warn() { printf '\033[33m  ! %s\033[0m\n' "$*"; }
ok() { printf '\033[32m  ✓ %s\033[0m\n' "$*"; }
phase() { printf '\n\033[1;36m── %s ──\033[0m\n' "$*"; }

# ask <prompt> <default> — read a value, falling back to default on empty input.
ask() {
  local prompt="$1" default="${2:-}" reply
  if [ -n "$default" ]; then
    read -r -p "  $prompt [$default]: " reply || true
    printf '%s' "${reply:-$default}"
  else
    read -r -p "  $prompt: " reply || true
    printf '%s' "$reply"
  fi
}

# confirm <prompt> — y/N gate; returns 0 only on an explicit yes.
confirm() {
  local reply
  read -r -p "  $1 [y/N]: " reply || true
  [[ "$reply" =~ ^[Yy]$ ]]
}

# pause <message> — wait for the operator to complete a manual step.
pause() {
  printf '\033[33m  ⏸  %s\033[0m\n' "$1"
  read -r -p "  Press Enter when done (or Ctrl-C to stop and resume later)… " _ || true
}

need() { command -v "$1" >/dev/null 2>&1 || { warn "missing required tool: $1"; MISSING=1; }; }

# ── 0. preflight ───────────────────────────────────────────────────────────
preflight() {
  phase "Preflight — tools + auth"
  MISSING=0
  for t in gcloud tofu kubectl helm yq bao; do need "$t"; done
  [ "${MISSING:-0}" = 0 ] || { warn "install the missing tools and re-run."; exit 2; }
  ok "tools present"
  if ! gcloud auth application-default print-access-token >/dev/null 2>&1; then
    warn "no application-default credentials."
    info "run: gcloud auth login && gcloud auth application-default login"
    confirm "Continue anyway?" || exit 2
  else
    ok "gcloud ADC present"
  fi
}

# ── 1. config — write deployment.yaml + tfvars + backend.tf + propagate ──────
collect_config() {
  phase "Config — the deployment identity (deployment.yaml is the single source)"
  info "deployment.yaml is COMMITTED and non-secret. terraform.tfvars is gitignored"
  info "and holds the secret/substrate knobs. Defaults shown in [brackets]."
  echo

  # repoURL auto-detected from the fork's origin remote.
  local detected_repo
  detected_repo="$(git remote get-url origin 2>/dev/null || true)"
  REPO_URL="$(ask 'Git URL of THIS fork (repoURL)' "$detected_repo")"

  DOMAIN="$(ask 'Domain (delegated subdomain, e.g. knowledge.example.com)' "$(yq -r '.domain // ""' deployment.yaml)")"
  PROJECT_ID="$(ask 'GCP project id to CREATE' "$(yq -r '.projectId // ""' deployment.yaml)")"
  REGION="$(ask 'GCP region' "$(yq -r '.region // "northamerica-northeast2"' deployment.yaml)")"
  GITHUB_ORG="$(ask 'GitHub org for admin SSO' "$(yq -r '.githubOrg // ""' deployment.yaml)")"
  OAUTH_CLIENT_ID="$(ask 'Google OAuth client id (public; create it first, or fill later)' "$(yq -r '.oauthClientId // ""' deployment.yaml)")"
  ADMIN_EMAILS="$(ask 'Admin emails (comma-separated)' "$(yq -r '(.adminEmails // []) | join(",")' deployment.yaml)")"
  # Worlds: PRESERVE an existing worlds[] verbatim across re-runs (idempotent —
  # never drop configured worlds); only seed root + one content world on a truly
  # fresh config. Add/remove worlds by editing deployment.yaml's worlds[].
  CONTENT_WORLD=""
  if yq -e '(.worlds // []) | map(select(.hub == true)) | length > 0' deployment.yaml >/dev/null 2>&1; then
    PRESERVE_WORLDS=1
    yq '.worlds' deployment.yaml > /tmp/instantiate-worlds.yaml
    WORLDS_SUMMARY="$(yq -r '[.worlds[].name] | join(", ")' deployment.yaml) (preserved — edit deployment.yaml to change)"
  else
    PRESERVE_WORLDS=0
    CONTENT_WORLD="$(ask 'First content world name (add more by editing deployment.yaml)' 'world-a')"
    WORLDS_SUMMARY="root (hub), $CONTENT_WORLD"
  fi
  DNS_TXT_OWNER="$(ask 'external-dns TXT owner id (unique per cluster)' "$(yq -r '.dnsTxtOwnerId // ""' deployment.yaml || true)")"
  [ -n "$DNS_TXT_OWNER" ] || DNS_TXT_OWNER="$PROJECT_ID"
  # allowDomains / webClients: PRESERVE existing values verbatim across re-runs
  # (same idempotency contract as worlds[] — never reset auth policy or
  # deregister web clients on a rerun); seed [] on a truly fresh config. Both
  # keys must EXIST even when empty — the broker ApplicationSet renders with
  # missingkey=error. Captured here as single-line JSON (valid YAML flow style)
  # BEFORE write_deployment_yaml truncates the file. Edit deployment.yaml by
  # hand to change (see docs/runbook-broker-allow-domains.md,
  # docs/runbook-broker-web-clients.md).
  ALLOW_DOMAINS_JSON="$(yq -o=json -I=0 '.allowDomains // []' deployment.yaml 2>/dev/null || echo '[]')"
  WEB_CLIENTS_JSON="$(yq -o=json -I=0 '.webClients // []' deployment.yaml 2>/dev/null || echo '[]')"

  echo
  info "Secret / substrate knobs (→ gitignored terraform.tfvars):"
  PROJECT_NAME="$(ask 'Project display name' "Demarkus Knowledge System")"
  BILLING_ACCOUNT="$(ask 'Billing account id (XXXXXX-XXXXXX-XXXXXX)' "")"
  ORG_ID="$(ask 'Org id (numeric; blank if using a folder)' "")"
  FOLDER_ID=""
  [ -n "$ORG_ID" ] || FOLDER_ID="$(ask 'Folder id (numeric)' "")"
  BUDGET_EMAIL="$(ask 'Budget alert email' "${ADMIN_EMAILS%%,*}")"

  echo
  info "OpenTofu state backend (created in the next phase; chicken/egg):"
  BOOTSTRAP_PROJECT="$(ask 'Bootstrap project id (holds the state bucket)' "")"
  STATE_BUCKET="$(ask 'State bucket name (globally unique)' "")"

  # Fail fast on missing required inputs — before writing files or touching the
  # cloud. (oauthClientId may be blank now and filled in before the OpenBao seed.)
  local missing=()
  [ -n "$DOMAIN" ] || missing+=("domain")
  [ -n "$PROJECT_ID" ] || missing+=("projectId")
  [ -n "$REGION" ] || missing+=("region")
  [ -n "$REPO_URL" ] || missing+=("repoURL")
  [ -n "$GITHUB_ORG" ] || missing+=("githubOrg")
  [ -n "$ADMIN_EMAILS" ] || missing+=("adminEmails")
  [ -n "$BILLING_ACCOUNT" ] || missing+=("billing_account")
  { [ -n "$ORG_ID" ] || [ -n "$FOLDER_ID" ]; } || missing+=("org_id or folder_id")
  [ -n "$BOOTSTRAP_PROJECT" ] || missing+=("bootstrap project")
  [ -n "$STATE_BUCKET" ] || missing+=("state bucket")
  if [ "${#missing[@]}" -gt 0 ]; then
    warn "missing required values: ${missing[*]}"
    info "re-run and provide them."
    exit 2
  fi

  echo
  bold "Review:"
  info "domain=$DOMAIN  projectId=$PROJECT_ID  region=$REGION  repoURL=$REPO_URL"
  info "githubOrg=$GITHUB_ORG  adminEmails=$ADMIN_EMAILS  worlds: $WORLDS_SUMMARY"
  info "billing=$BILLING_ACCOUNT  org/folder=${ORG_ID:-$FOLDER_ID}  bucket=$STATE_BUCKET"
  confirm "Write these files?" || { warn "aborted; nothing written."; exit 1; }

  write_deployment_yaml
  write_tfvars
  set_backend
  bash scripts/sync-deployment-config.sh >/dev/null && ok "repoURL propagated to all ApplicationSet generators"
}

write_deployment_yaml() {
  {
    echo "# Single source of truth for this deployment's identity. Committed +"
    echo "# non-secret. Generated by scripts/instantiate.sh; edit by hand after."
    echo "domain: $DOMAIN"
    echo "projectId: $PROJECT_ID"
    echo "region: $REGION"
    echo "repoURL: $REPO_URL"
    echo "githubOrg: $GITHUB_ORG"
    echo "dnsTxtOwnerId: $DNS_TXT_OWNER"
    echo "oauthClientId: $OAUTH_CLIENT_ID"
    echo "adminEmails:"
    local e
    IFS=',' read -ra _emails <<<"$ADMIN_EMAILS"
    for e in "${_emails[@]}"; do echo "  - ${e// /}"; done
    echo "allowDomains: $ALLOW_DOMAINS_JSON"
    echo "webClients: $WEB_CLIENTS_JSON"
    echo "worlds:"
    if [ "${PRESERVE_WORLDS:-0}" = 1 ] && [ -s /tmp/instantiate-worlds.yaml ]; then
      sed 's/^/  /' /tmp/instantiate-worlds.yaml
    else
      echo "  - name: root"
      echo "    hub: true"
      echo "  - name: $CONTENT_WORLD"
    fi
  } > deployment.yaml
  ok "wrote deployment.yaml"
}

write_tfvars() {
  local f=tofu/envs/prod/terraform.tfvars
  {
    echo "# gitignored — secret/substrate knobs only. Identity is in deployment.yaml."
    echo "project_name    = \"$PROJECT_NAME\""
    echo "billing_account = \"$BILLING_ACCOUNT\""
    [ -n "$ORG_ID" ] && echo "org_id = \"$ORG_ID\""
    [ -n "$FOLDER_ID" ] && echo "folder_id = \"$FOLDER_ID\""
    echo "budget_alert_email = \"$BUDGET_EMAIL\""
  } > "$f"
  ok "wrote $f (gitignored)"
}

# Point both tofu roots' backend.tf at the state bucket. The backend block is
# evaluated before any variable, so it can't read deployment.yaml — hence this
# explicit rewrite.
set_backend() {
  local b
  for b in tofu/envs/prod/backend.tf tofu/bootstrap/ci/backend.tf; do
    [ -f "$b" ] || continue
    sed -E -i.bak "s#(bucket[[:space:]]*=[[:space:]]*)\"[^\"]*\"#\\1\"$STATE_BUCKET\"#" "$b"
    rm -f "$b.bak"
    ok "pointed $b at bucket $STATE_BUCKET"
  done
}

# ── 2. bootstrap state — gated cloud mutation ────────────────────────────────
bootstrap_state() {
  phase "Bootstrap state — create the bootstrap project + GCS state bucket"
  if gcloud storage buckets describe "gs://$STATE_BUCKET" >/dev/null 2>&1; then
    ok "state bucket gs://$STATE_BUCKET already exists — skipping"
    return 0
  fi
  warn "This CREATES cloud resources (a project + a versioned GCS bucket)."
  confirm "Create bootstrap project '$BOOTSTRAP_PROJECT' + bucket '$STATE_BUCKET'?" || { warn "skipped — create them by hand, then re-run."; return 0; }
  if ! gcloud projects describe "$BOOTSTRAP_PROJECT" >/dev/null 2>&1; then
    gcloud projects create "$BOOTSTRAP_PROJECT" ${ORG_ID:+--organization "$ORG_ID"} ${FOLDER_ID:+--folder "$FOLDER_ID"}
    gcloud billing projects link "$BOOTSTRAP_PROJECT" --billing-account "$BILLING_ACCOUNT"
  fi
  gcloud storage buckets create "gs://$STATE_BUCKET" \
    --project "$BOOTSTRAP_PROJECT" --location "$REGION" \
    --uniform-bucket-level-access --public-access-prevention
  gcloud storage buckets update "gs://$STATE_BUCKET" --versioning
  ok "state bucket ready"
}

# ── 3. apply substrate — gated; shows the plan before applying ───────────────
apply_substrate() {
  phase "Substrate — OpenTofu (project, network, DNS, GKE, ArgoCD, KMS, budget)"
  ( cd tofu/envs/prod && tofu init -input=false >/dev/null ) && ok "tofu init"
  warn "Review the plan below before applying."
  ( cd tofu/envs/prod && tofu plan -input=false )
  if confirm "Apply this plan? (creates the GKE substrate)"; then
    ( cd tofu/envs/prod && tofu apply -input=false -auto-approve )
    ok "substrate applied — ArgoCD is installed and watching $REPO_URL"
  else
    warn "skipped apply. Re-run when ready."
  fi
}

# ── 4–6. manual gates — guided, with pointers ────────────────────────────────
guide_manual() {
  phase "Manual steps — these can't be safely automated"

  bold "  a) Delegate DNS"
  info "Copy the Cloud DNS zone's NS records to your registrar for $DOMAIN."
  info "  gcloud dns record-sets list --zone <zone> --project $PROJECT_ID --filter type=NS"
  pause "Delegate NS + wait for propagation (cert-manager + external-dns need it)."

  bold "  b) Seed OpenBao (Google OAuth client first)"
  info "Create a Google OAuth client (redirect https://broker.$DOMAIN/auth/callback),"
  info "put its id in deployment.yaml's oauthClientId, then seed secrets:"
  info "  → docs/runbook-openbao-seed.md   (scripts/seed-openbao.sh helps)"
  pause "Init + seed OpenBao (broker OIDC secret, signing key, world tokens)."

  bold "  c) Admin SSO (Dex + a GitHub OAuth app)"
  info "Create a GitHub OAuth app (callback https://dex.$DOMAIN/callback), seed its"
  info "client into OpenBao, wire Dex.  → docs/runbook-dex-sso.md"
  pause "Wire Dex SSO for the ArgoCD + OpenBao admin UIs."

  bold "  d) CI (optional but recommended)"
  info "Bootstrap Workload Identity Federation so PRs plan + merges apply, no keys."
  info "  → docs/runbook-ci-wif.md"
}

# ── 7. verify ────────────────────────────────────────────────────────────────
verify() {
  phase "Verify"
  info "curl -s https://$DOMAIN/.well-known/oauth-authorization-server | jq ."
  if curl -fsS "https://$DOMAIN/.well-known/oauth-authorization-server" >/dev/null 2>&1; then
    ok "$DOMAIN is serving RFC 8414 OAuth metadata — the broker MCP gateway is live."
    info "Finish: /knowledge-join from a Claude Code plugin should complete the device flow."
  else
    warn "$DOMAIN not answering yet — normal until DNS + ArgoCD + OpenBao seed are done."
  fi
}

main() {
  bold "demarkus knowledge-system instantiator"
  info "Fork → live. Config is automated; cloud steps are gated; manual steps guided."
  preflight
  collect_config
  bootstrap_state
  apply_substrate
  guide_manual
  verify
  phase "Done"
  ok "Config committed to deployment.yaml. Re-run this script any time to resume."
}

main "$@"
