#!/usr/bin/env bash
# Verifies deployment.yaml routing through the knowledge server (with its
# broker and federation) and legacy-world ApplicationSet templates without
# cluster credentials.
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
SHARED_NAMES="$(yq '[.worlds[] | select(.backend == "shared") | .name] | sort | join(",")' deployment.yaml)"
yq -e 'select(.kind == "ConfigMap") | .data["config.yaml"] | from_yaml | .worlds | length == '"$SHARED_COUNT" "$TMPD/shared.yaml" >/dev/null
yq -e 'select(.kind == "ConfigMap") | .data["config.yaml"] | from_yaml | .worlds | map(select((.bucket.url // "") == "" or (.bucket.worldID // "") == "" or .readOnly != false)) | length == 0' "$TMPD/shared.yaml" >/dev/null
# The QUIC certificate also carries the memory tenants' authority domain.
QUIC_DNS="$(yq '[.worlds[] | select(.backend == "shared") | .name + "-knowledge.demarkus-knowledge.svc.cluster.local"] + ["knowledge.demarkus-knowledge.svc.cluster.local", "*.knowledge.demarkus-knowledge.svc.cluster.local"] | sort | join(",")' deployment.yaml)"
yq -e 'select(.kind == "Certificate" and .metadata.name == "knowledge-tls") | .spec.dnsNames | sort | join(",") == "'"$QUIC_DNS"'"' "$TMPD/shared.yaml" >/dev/null
yq -e 'select(.kind == "Deployment") | .spec.replicas == 3' "$TMPD/shared.yaml" >/dev/null
# Image tag comes from the rendered values so an appset image bump can't
# drift from a second hardcoded pin here (bit 6a67b4b: 0.25.1 vs 0.30.0).
SHARED_TAG="$(yq -e '.image.tag' "$TMPD/shared-values.yaml")"
yq -e 'select(.kind == "Deployment") | .spec.template.spec.containers[0].image == "ghcr.io/latebit-io/demarkus-knowledge:'"$SHARED_TAG"'"' "$TMPD/shared.yaml" >/dev/null
# Token Secrets are chart-derived; each shared world projects its optional
# <name>-tokens and <name>-static-tokens pair, and no bootstrap Job renders.
SHARED_TOKENS="$(yq '[.worlds[] | select(.backend == "shared") | .name + "-tokens"] | sort | join(",")' deployment.yaml)"
SHARED_STATIC_TOKENS="$(yq '[.worlds[] | select(.backend == "shared") | .name + "-static-tokens"] | sort | join(",")' deployment.yaml)"
yq -e 'select(.kind == "Deployment") | [.spec.template.spec.volumes[] | select(.name | test("^world-token-")) | .projected.sources[0].secret | select(.optional == true) | .name] | sort | join(",") == "'"$SHARED_TOKENS"'"' "$TMPD/shared.yaml" >/dev/null
yq -e 'select(.kind == "Deployment") | [.spec.template.spec.volumes[] | select(.name | test("^world-token-")) | .projected.sources[1].secret | select(.optional == true) | .name] | sort | join(",") == "'"$SHARED_STATIC_TOKENS"'"' "$TMPD/shared.yaml" >/dev/null
yq -e '[select(.kind == "Job")] | length == 0' "$TMPD/shared.yaml" >/dev/null

# The broker in the same process: every shared world local under its writer
# list, state in the dedicated bucket, tenants under the chart's own domain.
yq 'select(.kind == "Secret" and .metadata.name == "knowledge-broker-config") | .stringData["config.yaml"]' "$TMPD/shared.yaml" > "$TMPD/broker-config.yaml"
ADMIN_EMAIL="$(yq '.adminEmails[0]' deployment.yaml)"
yq -e '.worlds | map(.name) | sort | join(",") == "'"$SHARED_NAMES"'"' "$TMPD/broker-config.yaml" >/dev/null
yq -e '.worlds | map(.local == true and .profile == "knowledge" and .internalAddress == .name + "-knowledge.demarkus-knowledge.svc.cluster.local:6309" and (.allow.emails | contains(["'"$ADMIN_EMAIL"'"]))) | all' "$TMPD/broker-config.yaml" >/dev/null
for world in $(yq '.worlds[] | select(.backend == "shared" and has("writerEmails")) | .name' deployment.yaml); do
  WRITERS="$(yq -o=json -I=0 '.worlds[] | select(.name == "'"$world"'") | .writerEmails' deployment.yaml)"
  yq -e '.worlds[] | select(.name == "'"$world"'") | .allow.emails | contains('"$WRITERS"')' "$TMPD/broker-config.yaml" >/dev/null
done
yq -e '.server.stateBucket == "gs://'"$(yq '.brokerStateBucket' deployment.yaml)"'"' "$TMPD/broker-config.yaml" >/dev/null
yq -e 'has("agentTokens") | not' "$TMPD/broker-config.yaml" >/dev/null
# Federation: the one world marked hub, derived in process with no token.
HUB="$(yq '[.worlds[] | select(.hub == true) | .name] | join(",")' deployment.yaml)"
[[ "$HUB" =~ ^[a-z0-9-]+$ ]] || { echo "exactly one world must be marked hub, got [$HUB]" >&2; exit 1; }
yq -e '.federation.hub == "'"$HUB"'"' "$TMPD/broker-config.yaml" >/dev/null
yq -e '.provisioning.mode == "allowlisted" and .provisioning.authorityDomain == "knowledge.demarkus-knowledge.svc.cluster.local" and .provisioning.bucketPrefix == "'"$(yq '.projectId' deployment.yaml)"'-memory-" and .provisioning.registrySecret == "demarkus-memory-broker-registry"' "$TMPD/broker-config.yaml" >/dev/null
INGRESS_HOSTS="$(yq '["broker." + .domain, .domain, .memoryDomain] | sort | join(",")' deployment.yaml)"
yq -e 'select(.kind == "Ingress") | [.spec.rules[].host] | sort | join(",") == "'"$INGRESS_HOSTS"'"' "$TMPD/shared.yaml" >/dev/null

render_field apps/demarkus-worlds/applicationset.yaml '.spec.generators[0].matrix.generators[1].list.elementsYaml' "$TMPD/legacy-worlds.yaml"
yq -e 'length == 0' "$TMPD/legacy-worlds.yaml" >/dev/null

echo "Shared knowledge routing smoke passed for $CHART@$VERSION."
