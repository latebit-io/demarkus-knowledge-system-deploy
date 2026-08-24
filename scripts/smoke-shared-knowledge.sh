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

yq -e 'select(.kind == "ConfigMap") | .data["config.yaml"] | from_yaml | .worlds | length == 3' "$TMPD/shared.yaml" >/dev/null
yq -e 'select(.kind == "ConfigMap") | .data["config.yaml"] | from_yaml | .worlds | map(select((.bucket.url // "") == "" or (.bucket.worldID // "") == "" or .readOnly != false)) | length == 0' "$TMPD/shared.yaml" >/dev/null
yq -e 'select(.kind == "Certificate") | .spec.dnsNames | sort | join(",") == "latebit-knowledge.demarkus-knowledge.svc.cluster.local,ontehfritz-knowledge.demarkus-knowledge.svc.cluster.local,root-knowledge.demarkus-knowledge.svc.cluster.local"' "$TMPD/shared.yaml" >/dev/null
yq -e 'select(.kind == "Deployment") | .spec.replicas == 3' "$TMPD/shared.yaml" >/dev/null
yq -e 'select(.kind == "Deployment") | .spec.template.spec.containers[0].image == "ghcr.io/latebit-io/demarkus-knowledge-server:0.25.1"' "$TMPD/shared.yaml" >/dev/null

render_field apps/demarkus-broker/applicationset.yaml '.spec.template.spec.source.helm.values' "$TMPD/broker-values.yaml"
yq -e '.worlds | map(.name) | sort | join(",") == "latebit,ontehfritz,root"' "$TMPD/broker-values.yaml" >/dev/null
yq -e '.worlds | map((.allow.emails | contains(["fritz@latebit.io"])) and (.defaultToken.paths | length == 1) and (.defaultToken.paths[0] == "/**")) | all' "$TMPD/broker-values.yaml" >/dev/null
yq -e '.worlds[] | select(.name == "ontehfritz" and .namespace == "demarkus-knowledge" and .internalAddress == "ontehfritz-knowledge.demarkus-knowledge.svc.cluster.local:6309")' "$TMPD/broker-values.yaml" >/dev/null

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

yq -e '.config.seeds | sort | join(",") == "mark://latebit,mark://ontehfritz"' "$TMPD/agent-values.yaml" >/dev/null
yq -e '.config.hubs | join(",") == "mark://root"' "$TMPD/agent-values.yaml" >/dev/null
yq -e '.config.endpoints.root.dialAddress == "root-knowledge.demarkus-knowledge.svc.cluster.local:6309" and .config.endpoints.root.serverName == "root-knowledge.demarkus-knowledge.svc.cluster.local"' "$TMPD/agent-values.yaml" >/dev/null
yq -e '.config.endpoints.latebit.dialAddress == "latebit-knowledge.demarkus-knowledge.svc.cluster.local:6309" and .config.endpoints.latebit.serverName == "latebit-knowledge.demarkus-knowledge.svc.cluster.local"' "$TMPD/agent-values.yaml" >/dev/null
yq -e '.config.endpoints.ontehfritz.dialAddress == "ontehfritz-knowledge.demarkus-knowledge.svc.cluster.local:6309" and .config.endpoints.ontehfritz.serverName == "ontehfritz-knowledge.demarkus-knowledge.svc.cluster.local"' "$TMPD/agent-values.yaml" >/dev/null

AGENT_REPO="$(yq '.spec.template.spec.source.repoURL' "$AGENT_APPSET")"
AGENT_CHART="$(yq '.spec.template.spec.source.chart' "$AGENT_APPSET")"
AGENT_VERSION="$(yq '.spec.template.spec.source.targetRevision' "$AGENT_APPSET")"
helm template demarkus-agent "oci://$AGENT_REPO/$AGENT_CHART" --version "$AGENT_VERSION" \
  --namespace demarkus-agent -f "$TMPD/agent-values.yaml" > "$TMPD/agent.yaml"
yq 'select(.kind == "ConfigMap") | .data["agent.toml"]' "$TMPD/agent.yaml" > "$TMPD/agent.toml"
yq -p=toml -oy -e '.endpoints.root.dial_address == "root-knowledge.demarkus-knowledge.svc.cluster.local:6309" and .endpoints.root.server_name == "root-knowledge.demarkus-knowledge.svc.cluster.local"' "$TMPD/agent.toml" >/dev/null
yq -e '.spec.target.template.data["tokens.toml"] | contains("[\"root:6309\"]")' apps/demarkus-agent/external-secret.yaml >/dev/null

render_field apps/demarkus-worlds/applicationset.yaml '.spec.generators[0].matrix.generators[1].list.elementsYaml' "$TMPD/legacy-worlds.yaml"
yq -e 'length == 0' "$TMPD/legacy-worlds.yaml" >/dev/null

echo "Shared knowledge routing smoke passed for $CHART@$VERSION."
