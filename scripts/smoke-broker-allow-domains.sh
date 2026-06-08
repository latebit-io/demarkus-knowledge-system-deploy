#!/usr/bin/env bash
# Smoke test: the broker chart honours `oidc.allowDomains` end-to-end through
# the ApplicationSet's goTemplate values block — i.e. the list set in
# `deployment.yaml` actually lands in the rendered broker config Secret. The
# gate is broker-global, so any drift between deployment.yaml and what the
# pod boots with is a silent auth-policy failure (users get in who shouldn't,
# or get locked out org-wide). This catches that on the PR.
#
# Cluster-free by design: renders the chart with `helm template` against a
# synthesised deployment.yaml (we can't pipe the ApplicationSet's git-files
# generator through helm directly, so we resolve the same {{ .allowDomains }}
# templating here with `yq` and hand the result to helm as -f values). Same
# tooling profile as scripts/check-immutable-fields.sh — bash + yq + helm,
# all preinstalled on `ubuntu-latest`.
#
# Customer-name policy: this test MUST NOT carry real customer domains, not
# even as fixtures. The whole point of `allowDomains` is org isolation; if a
# customer's domain ever appears in this repo's test surface it leaks who the
# tenants are. Fixtures use only example.com / example.org / example.net
# (RFC 2606 reserved). The test asserts the rendered Secret contains the
# fixture domains it set; it does not (and must not) assert any real domain.
#
# Usage: bash scripts/smoke-broker-allow-domains.sh
# Exit 0 = all cases pass; exit 1 = a case failed; exit 2 = tooling missing /
# helm render failure.
set -euo pipefail

cd "$(dirname "$0")/.."

APPSET="apps/demarkus-broker/applicationset.yaml"

command -v yq >/dev/null 2>&1 || { echo "yq is required (preinstalled on ubuntu-latest runners)" >&2; exit 2; }
command -v helm >/dev/null 2>&1 || { echo "helm is required" >&2; exit 2; }

TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT

REPO="$(yq '.spec.template.spec.source.repoURL' "$APPSET")"
CHART="$(yq '.spec.template.spec.source.chart' "$APPSET")"
VERSION="$(yq '.spec.template.spec.source.targetRevision' "$APPSET")"
RAW_VALUES="$(yq '.spec.template.spec.source.helm.values' "$APPSET")"

# Render the ApplicationSet's goTemplate values block with a fixture
# deployment.yaml — same path the argocd-applicationset-controller takes, just
# locally. The controller uses Sprig-flavoured Go templates with
# `missingkey=error`; the `gomplate` CLI is the closest local equivalent but
# isn't on runners by default, so we lean on `yq -p y` + a tiny shell shim
# instead: substitute the handful of `{{ .field }}` references this values
# block actually uses. Keep the substitution list in sync with the AppSet.
#
# Fields referenced: .domain, .oauthClientId, .adminEmails (range),
# .allowDomains (range), .worlds (range with .name).
render_values() { # <fixture_deployment_yaml>  ->  rendered values to stdout
  local fixture="$1"
  local domain client_id
  domain="$(yq '.domain' "$fixture")"
  client_id="$(yq '.oauthClientId' "$fixture")"

  # Expand the {{- range $.adminEmails }} block by yanking the admin emails
  # out of the fixture and writing them under every world's allow.emails.
  local admins_yaml worlds_yaml allow_domains_yaml
  admins_yaml="$(yq -o=json '.adminEmails' "$fixture")"
  worlds_yaml="$(yq -o=json '.worlds' "$fixture")"
  allow_domains_yaml="$(yq -o=json '.allowDomains // []' "$fixture")"

  # Inline-render with a Python shim: cheaper than pulling in gomplate, and the
  # templating surface here is small + stable.
  python3 - "$domain" "$client_id" "$admins_yaml" "$worlds_yaml" "$allow_domains_yaml" <<'PY'
import json, sys, textwrap
domain, client_id, admins_json, worlds_json, allow_json = sys.argv[1:6]
admins = json.loads(admins_json)
worlds = json.loads(worlds_json)
allow  = json.loads(allow_json)

worlds_block = []
for w in worlds:
    worlds_block.append(f"  - name: {w['name']}")
    worlds_block.append(f"    namespace: {w['name']}")
    worlds_block.append(f"    tokensSecret: {w['name']}-tokens")
    worlds_block.append( "    allow:")
    worlds_block.append( "      emails:")
    for e in admins:
        worlds_block.append(f"        - {e}")
    worlds_block.append( "    defaultToken:")
    worlds_block.append( '      paths: ["/**"]')

allow_block = "\n".join(f"  - {json.dumps(d)}" for d in allow) or "  []"

print(textwrap.dedent(f"""\
replicaCount: 1
image:
  tag: "0.1.31"
server:
  publicURL: "https://broker.{domain}"
  cookieKey: ""
  mcp:
    firstMintMaxAttempts: 10
    firstMintMaxBackoff: 15s
oidc:
  issuer: "https://accounts.google.com"
  clientID: "{client_id}"
  existingSecretRef:
    name: oidc-client
  existingSigningKeyRef:
    name: jwks-signing-key
  redirectURL: "https://broker.{domain}/auth/callback"
  allowDomains:
"""))
if allow:
    for d in allow:
        print(f"    - {json.dumps(d)}")
else:
    print("    []")
print("worlds:")
print("\n".join(worlds_block))
print(textwrap.dedent("""\
ingress:
  enabled: true
  className: nginx
  host: broker.placeholder.invalid
  tls:
    certManager:
      enabled: true
      issuerRef:
        kind: ClusterIssuer
        name: letsencrypt-prod
  mcp:
    host: placeholder.invalid
    tls:
      certManager:
        enabled: true
        issuerRef:
          kind: ClusterIssuer
          name: letsencrypt-prod
worldDialer:
  insecureSkipVerify: true
"""))
PY
}

render_chart() { # <values_file>  ->  rendered manifests to stdout
  local vfile="$1" errf
  errf="$(mktemp)"
  if ! helm template demarkus-broker "oci://$REPO/$CHART" \
        --version "$VERSION" -f "$vfile" --kube-version 1.31.0 2>"$errf"; then
    { echo "helm render failed for $CHART@$VERSION:"; cat "$errf"; } >&2
    exit 2
  fi
}

# Extract the broker's config Secret body (the only place `allowDomains` is
# expected to land). Chart renders one Secret per OIDC config; we look for any
# Secret whose stringData (or decoded data) contains the key.
extract_config_yaml() { # <rendered_manifests>
  yq 'select(.kind == "Secret") | (.stringData // {}) | to_entries | .[] | select(.value | test("allowDomains")) | .value' "$1"
}

# One test case. Args: <label> <fixture-allow-domains-json> <expected-pattern> [<must-not-contain-pattern>]
run_case() {
  local label="$1" allow_json="$2" expect_re="$3" forbid_re="${4:-}"
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
allowDomains: $allow_json
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
    echo "❌ $label: no rendered Secret carries an allowDomains key — chart $CHART@$VERSION likely missing the wiring." >&2
    exit 1
  fi

  if ! grep -Eq "$expect_re" <<<"$cfg"; then
    echo "❌ $label: rendered config Secret does NOT match /$expect_re/." >&2
    echo "--- rendered config ---" >&2
    echo "$cfg" >&2
    exit 1
  fi

  if [ -n "$forbid_re" ] && grep -Eq "$forbid_re" <<<"$cfg"; then
    echo "❌ $label: rendered config Secret unexpectedly contains /$forbid_re/." >&2
    exit 1
  fi

  echo "✅ $label"
}

# Case 1 — empty list renders as a gate-open allowlist (the chart's "leave it
# off" posture). We assert the key is present and the value is the empty list.
run_case empty '[]' 'allowDomains:[[:space:]]*\[\]'

# Case 2 — single-domain list (the typical single-tenant deployment).
run_case single '["example.com"]' 'allowDomains:.*example\.com' 'example\.org|example\.net'

# Case 3 — multi-domain list (multi-tenant deployments like this repo's).
run_case multi '["example.com","example.org","example.net"]' \
  'allowDomains:.*example\.com.*example\.org.*example\.net'

echo
echo "✅ All broker allowDomains smoke cases passed against $CHART@$VERSION."
