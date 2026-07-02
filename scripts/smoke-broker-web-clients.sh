#!/usr/bin/env bash
# Smoke test: the broker chart honours the confidential web-client registry
# (`webClients`) end-to-end through the ApplicationSet's goTemplate values
# block — i.e. the registry set in `deployment.yaml` actually lands in the
# rendered broker config Secret. Drift here is a silent SSO failure for every
# registered web app (or worse: a chart bump that drops the wiring renders
# `webClients: []` and the broker rejects clients it should accept). This
# catches that on the PR. Sibling of smoke-broker-allow-domains.sh — same
# render harness, see that script's header for the gomplate-vs-ArgoCD
# fidelity rationale.
#
# Customer-name policy: no real client ids, hostnames, or secret hashes —
# fixtures use RFC 2606 reserved domains and a synthetic 64-hex hash. The
# hash is not secret material (sha256 of an operator-generated secret), but
# real ones still don't belong in the public test surface.
#
# Usage: bash scripts/smoke-broker-web-clients.sh
# Exit 0 = all cases pass; exit 1 = a case failed; exit 2 = tooling missing /
# render failure.
set -euo pipefail

cd "$(dirname "$0")/.."

APPSET="apps/demarkus-broker/applicationset.yaml"

for tool in yq helm gomplate; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "$tool is required (workflow installs gomplate; yq and helm ship on ubuntu-latest)" >&2
    exit 2
  }
done

TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT

REPO="$(yq '.spec.template.spec.source.repoURL' "$APPSET")"
CHART="$(yq '.spec.template.spec.source.chart' "$APPSET")"
VERSION="$(yq '.spec.template.spec.source.targetRevision' "$APPSET")"

APPSET_VALUES_TMPL="$TMPD/appset-values.tmpl"
yq '.spec.template.spec.source.helm.values' "$APPSET" > "$APPSET_VALUES_TMPL"

render_values() { # <fixture_deployment_yaml> -> rendered values to stdout
  local fixture="$1" ctx errf
  ctx="$TMPD/ctx.json"
  yq -o=json '.' "$fixture" > "$ctx"

  errf="$(mktemp)"
  if ! gomplate \
        --missing-key error \
        --context ".=$ctx" \
        --file "$APPSET_VALUES_TMPL" 2>"$errf"; then
    echo "gomplate render of the ApplicationSet helm.values block failed:" >&2
    cat "$errf" >&2
    exit 2
  fi
}

render_chart() { # <values_file> -> rendered manifests to stdout
  local vfile="$1" errf
  errf="$(mktemp)"
  if ! helm template demarkus-broker "oci://$REPO/$CHART" \
        --version "$VERSION" -f "$vfile" --kube-version 1.31.0 2>"$errf"; then
    { echo "helm render failed for $CHART@$VERSION:"; cat "$errf"; } >&2
    exit 2
  fi
}

# Extract any rendered Secret body that mentions webClients. Handle both
# stringData and base64 data so a chart refactor can't turn this into a
# false green.
extract_config_yaml() { # <rendered_manifests>
  yq '
    select(.kind == "Secret")
    | (
        (.stringData // {})
        + ((.data // {}) | with_entries(.value |= @base64d))
      )
    | to_entries[]
    | select(.value | test("webClients"))
    | .value
  ' "$1"
}

# Synthetic sha256-hex — shape-valid (64 hex chars), obviously not real.
HASH_A="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
HASH_B="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

# Render one fixture through AppSet values + chart and leave the broker
# config YAML at $TMPD/<label>.config.yaml. Args: <label> <web-clients-json>
render_case() {
  local label="$1" clients_json="$2"
  local fixture vfile rendered cfg

  fixture="$TMPD/$label.deployment.yaml"
  cat > "$fixture" <<EOF
domain: example.com
projectId: example-test-project
region: northamerica-northeast2
repoURL: https://example.com/test/repo.git
githubOrg: example-org
dnsTxtOwnerId: example-test
oauthClientId: example-client-id.apps.googleusercontent.com
adminEmails:
  - operator@example.com
writerDomains: []
allowDomains: []
webClients: $clients_json
worlds:
  - name: root
    hub: true
  - name: world-a
EOF

  vfile="$TMPD/$label.values.yaml"
  render_values "$fixture" > "$vfile"

  rendered="$TMPD/$label.rendered.yaml"
  render_chart "$vfile" > "$rendered"

  cfg="$(extract_config_yaml "$rendered")"
  if [ -z "$cfg" ]; then
    echo "❌ $label: no rendered Secret carries a webClients key — chart $CHART@$VERSION likely missing the wiring." >&2
    exit 1
  fi
  printf '%s\n' "$cfg" > "$TMPD/$label.config.yaml"
}

# Assert a yq expression over a case's rendered broker config. The config is
# structured YAML, so field assertions beat regex (no dependence on the
# chart's quoting / inline-vs-block list style). Args: <label> <yq-expr> <want>
assert_cfg() {
  local label="$1" expr="$2" want="$3" got
  got="$(yq "$expr" "$TMPD/$label.config.yaml")"
  if [ "$got" != "$want" ]; then
    echo "❌ $label: yq '$expr' = '$got', want '$want'." >&2
    echo "--- rendered config ---" >&2
    cat "$TMPD/$label.config.yaml" >&2
    exit 1
  fi
}

# Case 1 — empty registry renders as an explicit `webClients: []` (the
# chart's self-documenting "no web clients" posture), not an absent key.
render_case empty '[]'
assert_cfg empty '. | has("webClients")' 'true'
assert_cfg empty '.webClients | length' '0'
echo "✅ empty"

# Case 2 — single client: id, hash, redirect URI, and name all land in the
# rendered config.
render_case single \
  '[{"clientID":"library-web","clientSecretHash":"'"$HASH_A"'","redirectURIs":["https://library.example.com/auth/callback"],"name":"Example Library"}]'
assert_cfg single '.webClients | length' '1'
assert_cfg single '.webClients[0].clientID' 'library-web'
assert_cfg single '.webClients[0].clientSecretHash' "$HASH_A"
assert_cfg single '.webClients[0].redirectURIs[0]' 'https://library.example.com/auth/callback'
assert_cfg single '.webClients[0].name' 'Example Library'
echo "✅ single"

# Case 3 — two clients, one with multiple redirect URIs and one with an
# empty name; both registrations survive the range.
render_case multi \
  '[{"clientID":"library-web","clientSecretHash":"'"$HASH_A"'","redirectURIs":["https://library.example.com/auth/callback","https://reading.example.org/auth/callback"],"name":"Example Library"},{"clientID":"portal-web","clientSecretHash":"'"$HASH_B"'","redirectURIs":["https://portal.example.net/auth/callback"],"name":""}]'
assert_cfg multi '.webClients | length' '2'
assert_cfg multi '.webClients[0].redirectURIs | length' '2'
assert_cfg multi '.webClients[0].redirectURIs[1]' 'https://reading.example.org/auth/callback'
assert_cfg multi '.webClients[1].clientID' 'portal-web'
assert_cfg multi '.webClients[1].clientSecretHash' "$HASH_B"
assert_cfg multi '.webClients[1].redirectURIs[0]' 'https://portal.example.net/auth/callback'
assert_cfg multi '.webClients[1].name | length' '0'
echo "✅ multi"

echo
echo "✅ All broker webClients smoke cases passed against $CHART@$VERSION."
