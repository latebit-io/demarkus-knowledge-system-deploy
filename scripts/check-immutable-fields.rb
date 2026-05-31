#!/usr/bin/env ruby
# frozen_string_literal: true
#
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
# Usage: BASE_REF=origin/main ruby scripts/check-immutable-fields.rb
# Exit 0 = no immutable changes; exit 1 = at least one (fails the PR check).

require 'yaml'
require 'open3'
require 'tempfile'

BASE = ENV['BASE_REF'] || 'origin/main'

# Immutable StatefulSet spec fields (everything else under spec is mutable:
# replicas, ordinals, template, updateStrategy, persistentVolumeClaim-
# RetentionPolicy, minReadySeconds, revisionHistoryLimit).
IMMUTABLE = %w[serviceName podManagementPolicy selector volumeClaimTemplates].freeze

# StatefulSet-bearing apps. source_path points at the Helm source block
# (Application vs ApplicationSet differ); release is the name used at render
# time ({{name}} in ApplicationSet values is substituted with it consistently
# on both sides, so the comparison is about shape, not the world's identity).
APPS = [
  {
    name: 'worlds',
    path: 'apps/demarkus-worlds/applicationset.yaml',
    source_path: %w[spec template spec source],
    sync_path: %w[spec template spec syncPolicy syncOptions],
    ignore_path: %w[spec template spec ignoreDifferences],
    release: 'world'
  },
  {
    name: 'openbao',
    path: 'platform/openbao/application.yaml',
    source_path: %w[spec source],
    sync_path: %w[spec syncPolicy syncOptions],
    ignore_path: %w[spec ignoreDifferences],
    release: 'openbao'
  }
].freeze

def dig_path(doc, path)
  path.reduce(doc) { |acc, k| acc.is_a?(Hash) ? acc[k] : nil }
end

# Manifest text at a git ref, or nil if the file doesn't exist there.
def file_at_ref(ref, path)
  out, status = Open3.capture2('git', 'show', "#{ref}:#{path}")
  status.success? ? out : nil
end

# Fields ArgoCD strips from its apply payload for this app: those listed in
# ignoreDifferences for the StatefulSet, but only when RespectIgnoreDifferences
# is also set (otherwise ServerSideApply still sends them and they DO matter).
def stripped_fields(app, doc)
  sync = dig_path(doc, app[:sync_path]) || []
  return [] unless sync.include?('RespectIgnoreDifferences=true')

  (dig_path(doc, app[:ignore_path]) || []).flat_map do |idf|
    next [] unless idf['kind'] == 'StatefulSet'

    (idf['jsonPointers'] || [])
      .select { |jp| jp.start_with?('/spec/') }
      .map { |jp| jp.split('/').last }
  end
end

# Render the app's chart from a manifest string; return { sts_name => {field => value} }.
def render_statefulsets(app, manifest_yaml)
  doc = YAML.safe_load(manifest_yaml, aliases: true)
  src = dig_path(doc, app[:source_path])
  return nil unless src

  chart = src['chart']
  repo = src['repoURL']
  version = src['targetRevision']
  values = (src.dig('helm', 'values') || '').gsub('{{name}}', app[:release])
  considered = IMMUTABLE - stripped_fields(app, doc)

  vfile = Tempfile.new(['values', '.yaml'])
  vfile.write(values)
  vfile.close

  # repoURL is OCI unless it's an explicit http(s) Helm repo. ArgoCD treats a
  # bare registry path (ghcr.io/latebit-io/charts) as OCI; the helm CLI needs
  # the oci:// scheme spelled out and the chart appended to the ref. Classic
  # http(s) repos use --repo + bare chart name instead.
  http = repo.start_with?('http://', 'https://')
  if http
    cmd = ['helm', 'template', app[:release], chart, '--repo', repo,
           '--version', version, '-f', vfile.path]
  else
    base = repo.start_with?('oci://') ? repo : "oci://#{repo}"
    cmd = ['helm', 'template', app[:release], "#{base}/#{chart}",
           '--version', version, '-f', vfile.path]
  end
  # Some charts (openbao-helm) gate on kubeVersion >= 1.30; the helm default
  # render version is older. Pin a version at/above the live cluster's floor so
  # the render isn't rejected. (Render-only; does not affect what's deployed.)
  cmd += ['--kube-version', '1.31.0']

  out, err, status = Open3.capture3(*cmd)
  vfile.unlink
  raise "helm render failed for #{app[:name]} @ #{version}:\n#{err}" unless status.success?

  result = {}
  YAML.load_stream(out) do |r|
    next unless r.is_a?(Hash) && r['kind'] == 'StatefulSet'

    name = r.dig('metadata', 'name')
    result[name] = considered.each_with_object({}) { |f, h| h[f] = r.dig('spec', f) }
  end
  result
end

findings = []

APPS.each do |app|
  head_yaml = File.exist?(app[:path]) ? File.read(app[:path]) : nil
  base_yaml = file_at_ref(BASE, app[:path])

  next if head_yaml.nil?              # app removed in this PR — not our concern
  next if base_yaml.nil?             # new app — nothing to compare (it's a create)
  next if head_yaml == base_yaml     # unchanged — skip the render entirely

  base_sts = render_statefulsets(app, base_yaml)
  head_sts = render_statefulsets(app, head_yaml)

  (base_sts.keys & head_sts.keys).each do |sts|
    IMMUTABLE.each do |field|
      next unless base_sts[sts].key?(field) && head_sts[sts].key?(field)
      next if base_sts[sts][field] == head_sts[sts][field]

      findings << { app: app[:name], sts: sts, field: field,
                    base: base_sts[sts][field], head: head_sts[sts][field] }
    end
  end
end

if findings.empty?
  puts "✅ No immutable StatefulSet field changes between #{BASE} and HEAD."
  exit 0
end

puts "❌ Immutable StatefulSet field change(s) detected — ArgoCD CANNOT apply these in place."
puts
findings.each do |f|
  puts "• #{f[:app]} / StatefulSet #{f[:sts]} — field `spec.#{f[:field]}` changed:"
  puts "    base (#{BASE}): #{f[:base].inspect}"
  puts "    head (this PR): #{f[:head].inspect}"
end
puts
puts "These fields are immutable in Kubernetes. In any environment where the"
puts "StatefulSet already exists, this change will WEDGE the ArgoCD sync until an"
puts "operator runs a manual recreate:"
puts
puts "    kubectl delete statefulset <name> -n <namespace> --cascade=orphan"
puts
puts "(pod + PVC survive; ArgoCD recreates the StatefulSet at the new spec). Plan"
puts "this as part of the rollout — see docs/runbook-world-version-bump.md."
exit 1
