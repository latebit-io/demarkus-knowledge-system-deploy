#!/usr/bin/env bash
# Pre-merge guard: flag when a PR changes an IMMUTABLE StatefulSet field on a
# demarkus-managed chart. Kubernetes forbids in-place updates to a
# StatefulSet's serviceName, selector, podManagementPolicy, or
# volumeClaimTemplates — so ArgoCD cannot reconcile such a change. In any
# environment where the StatefulSet already exists, it wedges the sync
# (sync=OutOfSync, operation Failed, pod stuck on the old spec) until an
# operator runs a manual `kubectl delete statefulset --cascade=orphan`
# recreate. Catching it on the PR turns a 2am wedged-prod surprise into a
# reviewed, planned change. See docs/runbook-world-version-bump.md.
#
# Cluster-free by design: it renders the Helm charts at the PR base and the PR
# head and diffs only the immutable fields. No kubeconfig, no cluster
# reachability, safe to run on forks of this template. It models ArgoCD's
# ignoreDifferences + RespectIgnoreDifferences, so a field ArgoCD strips from
# its apply payload (e.g. the worlds volumeClaimTemplates) is NOT flagged —
# avoiding false positives on changes ArgoCD already tolerates.
#
# What it does NOT catch: render-vs-live drift (a field the chart renders
# differently from what the live cluster defaulted, e.g. volumeMode: null vs
# Filesystem). That class is handled structurally by ignoreDifferences +
# RespectIgnoreDifferences on the affected app, and ultimately by fixing the
# chart. This guard is about chart/values changes between revisions.
#
# Bash + yq (mikefarah) + helm — all preinstalled on GitHub `ubuntu-latest`
# runners, so this stays dependency-free like the rest of the repo's tooling
# and falls under the same shellcheck coverage (.coderabbit.yaml).
#
# Usage: BASE_REF=origin/main bash scripts/check-immutable-fields.sh
# Exit 0 = no immutable changes; exit 1 = at least one (fails the PR check);
# exit 2 = missing tool / helm render failure.
set -euo pipefail

BASE="${BASE_REF:-origin/main}"

# Immutable StatefulSet spec fields (everything else under spec is mutable:
# replicas, ordinals, template, updateStrategy, persistentVolumeClaim-
# RetentionPolicy, minReadySeconds, revisionHistoryLimit).
IMMUTABLE=(serviceName podManagementPolicy selector volumeClaimTemplates)

command -v yq >/dev/null 2>&1 || { echo "yq is required (preinstalled on ubuntu-latest runners)" >&2; exit 2; }
command -v helm >/dev/null 2>&1 || { echo "helm is required" >&2; exit 2; }

# All scratch files land in one dir so a single trap cleans up.
TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT
export TMPDIR="$TMPD"
FINDINGS="$(mktemp)"

# Fields ArgoCD strips from its apply payload for this app: those listed in
# ignoreDifferences for the StatefulSet, but only when RespectIgnoreDifferences
# is also set (otherwise ServerSideApply still sends them and they DO matter).
# Args: <manifest> <sync_path> <ignore_path>. Prints one field name per line.
stripped_fields() {
  local manifest="$1" sync_path="$2" ignore_path="$3"
  if ! yq "($sync_path // [])[]" "$manifest" 2>/dev/null | grep -qxF "RespectIgnoreDifferences=true"; then
    return 0
  fi
  yq "($ignore_path // [])[] | select(.kind == \"StatefulSet\") | (.jsonPointers // [])[]" "$manifest" 2>/dev/null \
    | grep '^/spec/' | sed 's#.*/##' || true
}

# IMMUTABLE minus the stripped set, one field per line.
considered_fields() {
  local manifest="$1" sync_path="$2" ignore_path="$3" stripped f
  stripped="$(stripped_fields "$manifest" "$sync_path" "$ignore_path")"
  for f in "${IMMUTABLE[@]}"; do
    grep -qxF "$f" <<<"$stripped" || printf '%s\n' "$f"
  done
}

# Render the app's chart from a manifest file to stdout (multi-doc YAML).
# Args: <manifest> <source_path> <release> <app_name>.
render_chart() {
  local manifest="$1" source_path="$2" release="$3" name="$4"
  local chart repo version vfile errf
  chart="$(yq "$source_path.chart" "$manifest")"
  repo="$(yq "$source_path.repoURL" "$manifest")"
  version="$(yq "$source_path.targetRevision" "$manifest")"

  # The world-name placeholder in ApplicationSet values is substituted with the
  # release on both sides, so the comparison is about shape, not the world's
  # identity. Matches both the legacy fasttemplate form ({{name}}) and the
  # goTemplate form ({{ .name }} / {{.name}}) the worlds AppSet now uses.
  vfile="$(mktemp)"
  yq "$source_path.helm.values // \"\"" "$manifest" \
    | sed -E "s/\{\{[[:space:]]*\.?name[[:space:]]*\}\}/$release/g" > "$vfile"

  # repoURL is OCI unless it's an explicit http(s) Helm repo. ArgoCD treats a
  # bare registry path (ghcr.io/latebit-io/charts) as OCI; the helm CLI needs
  # the oci:// scheme spelled out and the chart appended to the ref. Classic
  # http(s) repos use --repo + bare chart name instead.
  local -a cmd
  case "$repo" in
    http://*|https://*) cmd=(helm template "$release" "$chart" --repo "$repo" --version "$version" -f "$vfile") ;;
    oci://*)            cmd=(helm template "$release" "$repo/$chart" --version "$version" -f "$vfile") ;;
    *)                  cmd=(helm template "$release" "oci://$repo/$chart" --version "$version" -f "$vfile") ;;
  esac
  # Some charts (openbao-helm) gate on kubeVersion >= 1.30; the helm default
  # render version is older. Pin a version at/above the live cluster's floor so
  # the render isn't rejected. (Render-only; does not affect what's deployed.)
  cmd+=(--kube-version 1.31.0)

  errf="$(mktemp)"
  if ! "${cmd[@]}" 2>"$errf"; then
    { echo "helm render failed for $name @ $version:"; cat "$errf"; } >&2
    exit 2
  fi
}

# Does the rendered StatefulSet carry this spec field at all? Prints true/false.
field_present() { # <render_file> <sts_name> <field>
  yq "select(.kind == \"StatefulSet\" and .metadata.name == \"$2\") | .spec | has(\"$3\")" "$1"
}

# Canonical (key-sorted, compact JSON) value of the field, for comparison.
field_value() { # <render_file> <sts_name> <field>
  yq -o=json -I=0 "select(.kind == \"StatefulSet\" and .metadata.name == \"$2\") | .spec.$3 | sort_keys(..)" "$1"
}

# yq path prefix to the Helm source/sync/ignore blocks, derived from the
# manifest's kind: ApplicationSet nests them under .spec.template.spec; a plain
# Application has them at .spec. Computed per-manifest so an app mid-conversion
# (base Application, head ApplicationSet) is handled on both sides.
path_prefix() { # <manifest>
  if [ "$(yq '.kind' "$1")" = "ApplicationSet" ]; then echo ".spec.template.spec"; else echo ".spec"; fi
}

# Render base + head for one app and append any immutable-field changes to
# FINDINGS. Args: <name> <path> <release>. The Helm-source path prefix is
# derived per-manifest from its kind, so an app mid-transition (base
# Application, head ApplicationSet) is compared correctly on both sides.
process_app() {
  local name="$1" path="$2" release="$3"

  [ -f "$path" ] || return 0                       # app removed in this PR — not our concern

  local base_yaml
  base_yaml="$(git show "$BASE:$path" 2>/dev/null)" || return 0   # new app — nothing to compare
  if diff -q <(printf '%s' "$base_yaml") "$path" >/dev/null 2>&1; then
    return 0                                        # unchanged — skip the render entirely
  fi

  local base_manifest head_manifest base_render head_render
  base_manifest="$(mktemp)"; head_manifest="$(mktemp)"
  printf '%s' "$base_yaml" > "$base_manifest"
  cp "$path" "$head_manifest"

  base_render="$(mktemp)"; head_render="$(mktemp)"
  local base_p head_p
  base_p="$(path_prefix "$base_manifest")"
  head_p="$(path_prefix "$head_manifest")"
  render_chart "$base_manifest" "${base_p}.source" "$release" "$name" > "$base_render"
  render_chart "$head_manifest" "${head_p}.source" "$release" "$name" > "$head_render"

  # A field is compared only when it's considered (not ArgoCD-stripped) on BOTH
  # sides — mirroring the per-side stripped computation in the original.
  local base_considered head_considered compare_fields base_sts head_sts common_sts
  base_considered="$(considered_fields "$base_manifest" "${base_p}.syncPolicy.syncOptions" "${base_p}.ignoreDifferences")"
  head_considered="$(considered_fields "$head_manifest" "${head_p}.syncPolicy.syncOptions" "${head_p}.ignoreDifferences")"
  compare_fields="$(comm -12 <(sort <<<"$base_considered") <(sort <<<"$head_considered"))"

  base_sts="$(yq 'select(.kind == "StatefulSet") | .metadata.name' "$base_render")"
  head_sts="$(yq 'select(.kind == "StatefulSet") | .metadata.name' "$head_render")"
  common_sts="$(comm -12 <(sort <<<"$base_sts") <(sort <<<"$head_sts"))"

  local sts field bp hp bv hv
  while IFS= read -r sts; do
    [ -n "$sts" ] || continue
    while IFS= read -r field; do
      [ -n "$field" ] || continue
      bp="$(field_present "$base_render" "$sts" "$field")"
      hp="$(field_present "$head_render" "$sts" "$field")"
      { [ "$bp" = "true" ] && [ "$hp" = "true" ]; } || continue
      bv="$(field_value "$base_render" "$sts" "$field")"
      hv="$(field_value "$head_render" "$sts" "$field")"
      [ "$bv" = "$hv" ] && continue
      {
        # Single quotes are intentional: the backticks are literal markdown and
        # %s are printf specifiers — double quotes would let the shell try to
        # run `spec.%s` as a command substitution.
        # shellcheck disable=SC2016
        printf '• %s / StatefulSet %s — field `spec.%s` changed:\n' "$name" "$sts" "$field"
        printf '    base (%s): %s\n' "$BASE" "$bv"
        printf '    head (this PR): %s\n' "$hv"
      } >> "$FINDINGS"
    done <<<"$compare_fields"
  done <<<"$common_sts"
}

# StatefulSet-bearing apps. The Helm-source path prefix is derived per-manifest
# from its kind inside process_app (Application vs ApplicationSet).
process_app worlds  apps/demarkus-worlds/applicationset.yaml world
process_app openbao platform/openbao/applicationset.yaml openbao

if [ ! -s "$FINDINGS" ]; then
  echo "✅ No immutable StatefulSet field changes between $BASE and HEAD."
  exit 0
fi

echo "❌ Immutable StatefulSet field change(s) detected — ArgoCD CANNOT apply these in place."
echo
cat "$FINDINGS"
echo
echo "These fields are immutable in Kubernetes. In any environment where the"
echo "StatefulSet already exists, this change will WEDGE the ArgoCD sync until an"
echo "operator runs a manual recreate:"
echo
echo "    kubectl delete statefulset <name> -n <namespace> --cascade=orphan"
echo
echo "(pod + PVC survive; ArgoCD recreates the StatefulSet at the new spec). Plan"
echo "this as part of the rollout — see docs/runbook-world-version-bump.md."
exit 1
