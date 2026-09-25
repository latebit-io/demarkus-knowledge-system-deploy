#!/usr/bin/env bash
# Verifies deployment.yaml routing through shared-server, broker, agent, and
# legacy-world ApplicationSet templates without cluster credentials.
set -euo pipefail

cd "$(dirname "$0")/.."

for tool in yq helm gomplate; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "$tool is required" >&2
    exit 2
  }
done

TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT

yq -o=json '.' deployment.yaml > "$TMPD/deployment.json"

render_field() { # <manifest> <yq path> <output>
  local manifest="$1" path="$2" output="$3" template
  template="$TMPD/$(basename "${manifest%/*}")-$(basename "$output").tmpl"
  yq "$path" "$manifest" > "$template"
  gomplate --missing-key error --context ".=$TMPD/deployment.json" --file "$template" > "$output"
}

SHARED_APPSET="apps/demarkus-knowledge-server/applicationset.yaml"
render_field "$SHARED_APPSET" '.spec.template.spec.source.helm.values' "$TMPD/shared-values.yaml"

REPO="$(yq '.spec.template.spec.source.repoURL' "$SHARED_APPSET")"
CHART="$(yq '.spec.template.spec.source.chart' "$SHARED_APPSET")"
VERSION="$(yq '.spec.template.spec.source.targetRevision' "$SHARED_APPSET")"
helm template knowledge "oci://$REPO/$CHART" --version "$VERSION" \
  --namespace demarkus-knowledge -f "$TMPD/shared-values.yaml" > "$TMPD/shared.yaml"

# Expectations derive from deployment.yaml so adding a world cannot
# silently break this smoke (music and bruno did, twice).
SHARED_COUNT="$(yq '[.worlds[] | select(.backend == "shared")] | length' deployment.yaml)"
SHARED_DNS="$(yq '[.worlds[] | select(.backend == "shared") | .name + "-knowledge.demarkus-knowledge.svc.cluster.local"] | sort | join(",")' deployment.yaml)"
ALL_WORLD_NAMES="$(yq '[.worlds[].name] | sort | join(",")' deployment.yaml)"
yq -e 'select(.kind == "ConfigMap") | .data["config.yaml"] | from_yaml | .worlds | length == '"$SHARED_COUNT" "$TMPD/shared.yaml" >/dev/null
yq -e 'select(.kind == "ConfigMap") | .data["config.yaml"] | from_yaml | .worlds | map(select((.bucket.url // "") == "" or (.bucket.worldID // "") == "" or .readOnly != false)) | length == 0' "$TMPD/shared.yaml" >/dev/null
yq -e 'select(.kind == "Certificate") | .spec.dnsNames | sort | join(",") == "'"$SHARED_DNS"'"' "$TMPD/shared.yaml" >/dev/null
yq -e 'select(.kind == "Deployment") | .spec.replicas == 3' "$TMPD/shared.yaml" >/dev/null
# Image tag comes from the rendered values so an appset image bump can't
# drift from a second hardcoded pin here (bit 6a67b4b: 0.25.1 vs 0.30.0).
SHARED_TAG="$(yq -e '.image.tag' "$TMPD/shared-values.yaml")"
yq -e 'select(.kind == "Deployment") | .spec.template.spec.containers[0].image == "ghcr.io/latebit-io/demarkus-knowledge-server:'"$SHARED_TAG"'"' "$TMPD/shared.yaml" >/dev/null
# Token Secrets are chart-derived (<name>-tokens); each shared world mounts its own.
SHARED_TOKENS="$(yq '[.worlds[] | select(.backend == "shared") | .name + "-tokens"] | sort | join(",")' deployment.yaml)"
yq -e 'select(.kind == "Deployment") | [.spec.template.spec.volumes[] | select(.name | test("^world-token-")) | .secret.secretName] | sort | join(",") == "'"$SHARED_TOKENS"'"' "$TMPD/shared.yaml" >/dev/null

render_field apps/demarkus-broker/applicationset.yaml '.spec.template.spec.source.helm.values' "$TMPD/broker-values.yaml"
yq -e '.worlds | map(.name) | sort | join(",") == "'"$ALL_WORLD_NAMES"'"' "$TMPD/broker-values.yaml" >/dev/null
yq -e '.worlds | map(.allow.emails | contains(["fritz@latebit.io"])) | all' "$TMPD/broker-values.yaml" >/dev/null
yq -e '.worlds[] | select(.name == "ontehfritz" and .namespace == "demarkus-knowledge" and .internalAddress == "ontehfritz-knowledge.demarkus-knowledge.svc.cluster.local:6309" and .dialAddress == "knowledge.demarkus-knowledge.svc.cluster.local:6309")' "$TMPD/broker-values.yaml" >/dev/null

# tokensSecret and defaultToken come from chart defaults: check the rendered
# broker config, not the values.
BROKER_APPSET="apps/demarkus-broker/applicationset.yaml"
BROKER_REPO="$(yq '.spec.template.spec.source.repoURL' "$BROKER_APPSET")"
BROKER_CHART="$(yq '.spec.template.spec.source.chart' "$BROKER_APPSET")"
BROKER_VERSION="$(yq '.spec.template.spec.source.targetRevision' "$BROKER_APPSET")"
helm template demarkus-broker "oci://$BROKER_REPO/$BROKER_CHART" --version "$BROKER_VERSION" \
  --namespace demarkus-broker -f "$TMPD/broker-values.yaml" > "$TMPD/broker.yaml"
yq 'select(.kind == "Secret" and .metadata.name == "demarkus-broker-config") | .stringData["config.yaml"]' "$TMPD/broker.yaml" > "$TMPD/broker-config.yaml"
yq -e '.worlds | map(.tokensSecret == .name + "-tokens" and (.defaultToken.paths | length == 1) and .defaultToken.paths[0] == "/**") | all' "$TMPD/broker-config.yaml" >/dev/null
yq -e '[.worlds[] | select(.namespace == "demarkus-knowledge") | .dialAddress == "knowledge.demarkus-knowledge.svc.cluster.local:6309"] | all' "$TMPD/broker-config.yaml" >/dev/null

AGENT_APPSET="apps/demarkus-agent/applicationset.yaml"
render_field "$AGENT_APPSET" '.spec.template.spec.source.helm.values' "$TMPD/agent-values.yaml"

AGENT_TEMPLATE="$TMPD/agent-values.yaml.tmpl"
yq '.spec.template.spec.source.helm.values' "$AGENT_APPSET" > "$AGENT_TEMPLATE"
expect_agent_render_failure() { # <case> <deployment yq expression>
  local name="$1" expression="$2" config="$TMPD/agent-$1.json" output
  yq -o=json "$expression" deployment.yaml > "$config"
  if output="$(gomplate --missing-key error --context ".=$config" --file "$AGENT_TEMPLATE" 2>&1)"; then
    echo "agent hub validation accepted invalid case: $name" >&2
    exit 1
  fi
  if [[ "$output" != *"exactly one hub is required and it must be named root"* ]]; then
    echo "agent hub validation failed unexpectedly for case: $name" >&2
    echo "$output" >&2
    exit 1
  fi
}
expect_agent_render_failure no-hub 'del(.worlds[].hub)'
expect_agent_render_failure multiple-hubs '.worlds[1].hub = true'
expect_agent_render_failure wrong-hub-name '.worlds[0].name = "not-root"'

SEEDS="$(yq '[.worlds[] | select(.hub != true) | "mark://" + .name] | sort | join(",")' deployment.yaml)"
yq -e '.config.seeds | sort | join(",") == "'"$SEEDS"'"' "$TMPD/agent-values.yaml" >/dev/null
yq -e '.config.hubs | join(",") == "mark://root"' "$TMPD/agent-values.yaml" >/dev/null
# Every shared world dials the one knowledge Service and presents its own SNI.
for world in $(yq '.worlds[] | select(.backend == "shared") | .name' deployment.yaml); do
  yq -e '.config.endpoints["'"$world"'"].dialAddress == "knowledge.demarkus-knowledge.svc.cluster.local:6309" and .config.endpoints["'"$world"'"].serverName == "'"$world"'-knowledge.demarkus-knowledge.svc.cluster.local"' "$TMPD/agent-values.yaml" >/dev/null
done

AGENT_REPO="$(yq '.spec.template.spec.source.repoURL' "$AGENT_APPSET")"
AGENT_CHART="$(yq '.spec.template.spec.source.chart' "$AGENT_APPSET")"
AGENT_VERSION="$(yq '.spec.template.spec.source.targetRevision' "$AGENT_APPSET")"
helm template demarkus-agent "oci://$AGENT_REPO/$AGENT_CHART" --version "$AGENT_VERSION" \
  --namespace demarkus-agent -f "$TMPD/agent-values.yaml" > "$TMPD/agent.yaml"
yq 'select(.kind == "ConfigMap") | .data["agent.toml"]' "$TMPD/agent.yaml" > "$TMPD/agent.toml"
yq -p=toml -oy -e '.endpoints.root.dial_address == "knowledge.demarkus-knowledge.svc.cluster.local:6309" and .endpoints.root.server_name == "root-knowledge.demarkus-knowledge.svc.cluster.local"' "$TMPD/agent.toml" >/dev/null
# Publish token: ESO copies root-token-values:admin verbatim (no template);
# the chart projects that key to tokens.d/root:6309 as a required source.
yq -e '.spec.target | has("template") | not' apps/demarkus-agent/external-secret.yaml >/dev/null
yq -e '.spec.data[0].secretKey == "admin" and .spec.data[0].remoteRef.key == "root-token-values" and .spec.data[0].remoteRef.property == "admin"' apps/demarkus-agent/external-secret.yaml >/dev/null
yq -e '.tokens.fromWorldSecrets[0].hostPort == "root:6309" and .tokens.fromWorldSecrets[0].secret == "demarkus-agent-hub-tokens"' "$TMPD/agent-values.yaml" >/dev/null
yq -e 'select(.kind == "Deployment") | .spec.template.spec.volumes[] | select(.name == "tokens") | .projected.sources[] | select(.secret.name == "demarkus-agent-hub-tokens") | ((.secret | has("optional") | not) and .secret.items[0].key == "admin" and .secret.items[0].path == "tokens.d/root:6309")' "$TMPD/agent.yaml" >/dev/null

render_field apps/demarkus-worlds/applicationset.yaml '.spec.generators[0].matrix.generators[1].list.elementsYaml' "$TMPD/legacy-worlds.yaml"
yq -e 'length == 0' "$TMPD/legacy-worlds.yaml" >/dev/null

echo "Shared knowledge routing smoke passed for $CHART@$VERSION."
