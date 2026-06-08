#!/usr/bin/env bash
# Smoke test: the broker chart honours `oidc.allowDomains` end-to-end through
# the ApplicationSet's goTemplate values block — i.e. the list set in
# `deployment.yaml` actually lands in the rendered broker config Secret. The
# gate is broker-global, so any drift between deployment.yaml and what the
# pod boots with is a silent auth-policy failure (users get in who shouldn't,
# or get locked out org-wide). This catches that on the PR.
#
# Cluster-free by design and ApplicationSet-faithful: the values text passed
# to helm is the LITERAL `spec.template.spec.source.helm.values` from
# `apps/demarkus-broker/applicationset.yaml`, rendered with gomplate against
# a synthetic deployment.yaml. argocd-applicationset-controller renders that
# same string with Go text/template + sprig and `missingkey=error`; gomplate
# uses the same engine + sprig superset, so a wiring drift in the AppSet
# (dropped range, renamed field, missing key) fails this smoke for the same
# reason it would fail in-cluster. A previous version of this script
# constructed its own values YAML by hand — that masked exactly the drift
# the smoke is supposed to catch.
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
# render failure.
set -euo pipefail

cd "$(dirname "$0")/.."

APPSET="apps/demarkus-broker/applicationset.yaml"

# gomplate is the one piece NOT preinstalled on ubuntu-latest runners; the
# workflow installs it. Locally: `brew install gomplate` (mac) or a single
# curl from the gomplate releases page. Kept in lockstep with the AppSet's
# templating because every other substitute (hand-rolled regex, Python f-strings)
# can silently miss a new directive the AppSet starts using.
for tool in yq helm gomplate python3; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "$tool is required (workflow installs gomplate; the rest ship on ubuntu-latest)" >&2
    exit 2
  }
done

TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT

REPO="$(yq '.spec.template.spec.source.repoURL' "$APPSET")"
CHART="$(yq '.spec.template.spec.source.chart' "$APPSET")"
VERSION="$(yq '.spec.template.spec.source.targetRevision' "$APPSET")"

# Pull the AppSet's helm.values text verbatim, then strip a single layer of
# block-scalar indentation. ArgoCD applies the values text to the chart with
# the same de-indenting yaml unmarshal does, so the canonical comparison is
# against the dedented body — not the literal indented block scalar.
APPSET_VALUES_TMPL="$TMPD/appset-values.tmpl"
yq '.spec.template.spec.source.helm.values' "$APPSET" > "$APPSET_VALUES_TMPL"

render_values() { # <fixture_deployment_yaml> -> rendered values to stdout
  local fixture="$1" ctx errf
  ctx="$TMPD/ctx.json"
  # gomplate consumes the deployment.yaml as a datasource; the AppSet's
  # `{{ .domain }}` / `{{ range .worlds }}` references resolve against this.
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

# Extract any rendered Secret body that mentions allowDomains. Charts may use
# `stringData` (plain) or `data` (base64) — handle both so a future chart
# refactor doesn't silently turn this into a false green.
extract_config_yaml() { # <rendered_manifests>
  yq '
    select(.kind == "Secret")
    | (
        (.stringData // {})
        + ((.data // {}) | with_entries(.value |= @base64d))
      )
    | to_entries[]
    | select(.value | test("allowDomains"))
    | .value
  ' "$1"
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
