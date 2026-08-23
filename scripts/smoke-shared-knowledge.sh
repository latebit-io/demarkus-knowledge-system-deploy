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
yq -e 'select(.kind == "ConfigMap") | .data["config.yaml"] | from_yaml | .worlds | map(select(.bucket.url == "" or .bucket.worldID == "" or .readOnly != false)) | length == 0' "$TMPD/shared.yaml" >/dev/null
yq -e 'select(.kind == "Certificate") | .spec.dnsNames | length == 3' "$TMPD/shared.yaml" >/dev/null
yq -e 'select(.kind == "Deployment") | .spec.template.spec.containers[0].image == "ghcr.io/latebit-io/demarkus-knowledge-server:0.25.1"' "$TMPD/shared.yaml" >/dev/null

render_field apps/demarkus-broker/applicationset.yaml '.spec.template.spec.source.helm.values' "$TMPD/broker-values.yaml"
yq -e '.worlds | length == 3' "$TMPD/broker-values.yaml" >/dev/null
yq -e '.worlds | map((.allow.emails | contains(["fritz@latebit.io"])) and (.defaultToken.paths | length == 1) and (.defaultToken.paths[0] == "/**")) | all' "$TMPD/broker-values.yaml" >/dev/null
yq -e '.worlds[] | select(.name == "ontehfritz" and .namespace == "demarkus-knowledge" and .internalAddress == "ontehfritz-knowledge.demarkus-knowledge.svc.cluster.local:6309")' "$TMPD/broker-values.yaml" >/dev/null

render_field apps/demarkus-agent/applicationset.yaml '.spec.template.spec.source.helm.values' "$TMPD/agent-values.yaml"
yq -e '.config.seeds[] == "mark://ontehfritz-knowledge.demarkus-knowledge.svc.cluster.local:6309"' "$TMPD/agent-values.yaml" >/dev/null
yq -e '.config.hubs[] == "mark://root-knowledge.demarkus-knowledge.svc.cluster.local:6309"' "$TMPD/agent-values.yaml" >/dev/null

render_field apps/demarkus-worlds/applicationset.yaml '.spec.generators[0].matrix.generators[1].list.elementsYaml' "$TMPD/legacy-worlds.yaml"
yq -e 'length == 0' "$TMPD/legacy-worlds.yaml" >/dev/null

echo "Shared knowledge routing smoke passed for $CHART@$VERSION."
