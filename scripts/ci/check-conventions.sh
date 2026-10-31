#!/usr/bin/env bash
# scripts/ci/check-conventions.sh — the repo's OWN rules, which nothing else validates.
#
#   ./scripts/ci/check-conventions.sh        # from the repo root  (make conventions)
#
# validate.sh answers "is this valid Kubernetes?". This answers "is this valid *for this repo*?"
# — the conventions in CLAUDE.md and docs/platform/adding-an-app.md that are invisible to
# kustomize and kubeconform because the YAML is perfectly legal either way.
#
#   A. applicationset  every kubernetes/apps/<ns>/<app>/ is a shape Argo will actually generate
#                      (a directory at the wrong depth is SILENTLY ignored — no error anywhere)
#   B. nodeports       unique, and inside the 30000–32767 range (a clash = "already allocated"
#                      at Sync time, which looks like an Argo bug and isn't)
#   C. images          every image has an explicit tag; no bare :latest (Renovate is blind to it)
#   D. secretrefs      every secretKeyRef points at a key that the Secret in this repo declares.
#                      SOPS encrypts VALUES, not KEY NAMES, so this works with no age key — and it
#                      is the check that catches "secret not found"/wrong-key before Sync does.
#   E. placeholders    REPLACE_ME anywhere, not just in *.enc.yaml (WARN — see the secrets stance
#                      in CLAUDE.md). The Bark device key lives in a plain Deployment, so the
#                      existing *.enc.yaml-only check cannot see it.
#   F. ingress         one host per hostname, each with TLS + the cluster-issuer annotation
#   G. workloads       readiness probe + resource requests/limits (WARN — Argo health and Gatus
#                      both trust readiness; a pod with no probe is "Healthy" the instant it starts)
#
# Needs: ruby (already required by validate.sh). Exit 1 if any FAIL.
set -uo pipefail
cd "$(dirname "$0")/../.."
command -v ruby >/dev/null 2>&1 || { echo "missing tool: ruby"; exit 2; }
ruby - "$@" <<'RUBY'
require 'yaml'

FAIL = []; WARN = []
def pass(m) = puts("  \e[32mPASS\e[0m #{m}")
def fail_(m) = (FAIL << m; puts("  \e[31mFAIL\e[0m #{m}"))
def warn_(m) = (WARN << m; puts("  \e[33mWARN\e[0m #{m}"))

# Load every manifest once. Keep (file, doc) pairs so messages can point at a real path.
DOCS = Dir["kubernetes/**/*.yaml"].sort.reject { |f| f =~ %r{/charts/} }.flat_map do |f|
  begin
    YAML.load_stream(File.read(f)).compact.map { |d| [f, d] }
  rescue StandardError
    []                                  # validate.sh already reports unparseable YAML
  end
end.select { |_, d| d.is_a?(Hash) }

APP_DIRS = Dir["kubernetes/apps/*/*"].select { |d| File.directory?(d) }.sort

# Walk a nested structure yielding every Hash, so flow-style (`{ name: x, key: y }`) and
# block-style refs are found identically — grep cannot do this reliably.
def each_hash(node, &blk)
  case node
  when Hash  then blk.call(node); node.each_value { |v| each_hash(v, &blk) }
  when Array then node.each { |v| each_hash(v, &blk) }
  end
end

# ── A. ApplicationSet shape ───────────────────────────────────────────────────────────
puts "== A. applicationset: kubernetes/apps/<ns>/<app>/ is what the generator globs =="
stray = Dir["kubernetes/apps/*/*.yaml"]
stray.each { |f| fail_("#{f} — a manifest directly under kubernetes/apps/<ns>/; the generator globs */* so this is NEVER deployed") }
APP_DIRS.each do |d|
  if File.exist?("#{d}/kustomization.yaml")
    next
  elsif Dir["#{d}/*.yaml"].empty?
    fail_("#{d} — no kustomization.yaml and no manifests; Argo will generate an empty Application")
  else
    warn_("#{d} — no kustomization.yaml (directory-of-manifests mode; the repo convention is kustomize)")
  end
end
pass("#{APP_DIRS.size} app directories at the right depth") if stray.empty?

# ── B. NodePorts ──────────────────────────────────────────────────────────────────────
puts "== B. nodeports: unique and in range =="
ports = Hash.new { |h, k| h[k] = [] }
DOCS.each do |f, d|
  next unless d["kind"] == "Service"
  (d.dig("spec", "ports") || []).each { |p| ports[p["nodePort"]] << f if p["nodePort"] }
end
ports.each do |port, files|
  fail_("nodePort #{port} used #{files.size}× (#{files.uniq.join(', ')}) — Sync fails with 'already allocated'") if files.uniq.size > 1
  fail_("nodePort #{port} (#{files.first}) outside the 30000–32767 range") unless (30000..32767).cover?(port)
end
pass("#{ports.size} NodePorts, all unique and in range") if ports.values.all? { |v| v.uniq.size == 1 }

# ── C. Image pinning ──────────────────────────────────────────────────────────────────
puts "== C. images: explicit tag, never a bare :latest =="
imgs = []
DOCS.each do |f, d|
  each_hash(d) { |h| imgs << [f, h["image"]] if h["image"].is_a?(String) }
end
bad_imgs = 0
imgs.uniq.each do |f, img|
  ref = img.split("@").first.to_s
  tag = ref.include?(":") ? ref.split(":").last : nil
  next if img.include?("@sha256:")       # digest-pinned is immutable; fine
  if tag.nil?
    bad_imgs += 1; fail_("#{f} — #{img} has no tag (implicitly :latest)")
  elsif tag == "latest"
    bad_imgs += 1; fail_("#{f} — #{img} is :latest; Renovate cannot bump it and rollback is impossible")
  end
end
pass("#{imgs.uniq.size} image references, all pinned") if bad_imgs.zero?

# ── D. secretKeyRef → the Secret's declared keys ───────────────────────────────────────
puts "== D. secretrefs: every secretKeyRef key exists in the Secret this repo declares =="
# SOPS with encrypted_regex ^(data|stringData)$ leaves KEY NAMES in cleartext, so an encrypted
# file still tells us which keys it provides — no age key needed.
declared = {}
DOCS.each do |f, d|
  next unless d["kind"] == "Secret"
  keys = ((d["stringData"] || {}).keys + (d["data"] || {}).keys).uniq
  (declared[d.dig("metadata", "name")] ||= { keys: [], file: f })[:keys].concat(keys)
end
refs = []
DOCS.each do |f, d|
  each_hash(d) do |h|
    r = h["secretKeyRef"]
    refs << [f, r["name"], r["key"], h["optional"] || r["optional"]] if r.is_a?(Hash) && r["name"] && r["key"]
  end
end
external = Hash.new(0)
refs.uniq.each do |f, name, key, optional|
  src = declared[name]
  if src.nil?
    external[name] += 1                  # created outside git (Ansible, or a cleartext resource)
  elsif !src[:keys].include?(key)
    fail_("#{f} — secretKeyRef #{name}.#{key} but #{src[:file]} declares only: #{src[:keys].sort.join(', ')}")
  end
end
external.each { |n, c| warn_("Secret '#{n}' (#{c} ref#{c > 1 ? 's' : ''}) is not defined in this repo — created out-of-band? CI cannot verify its keys") }
pass("#{refs.uniq.size} secretKeyRefs checked, #{declared.size} Secrets declared in-repo")

# ── E. Placeholders ───────────────────────────────────────────────────────────────────
puts "== E. placeholders: REPLACE_ME anywhere (not just *.enc.yaml) =="
hits = Dir["kubernetes/**/*.yaml"].sort.flat_map do |f|
  File.readlines(f).each_with_index.select { |l, _| l.include?("REPLACE_ME") }.map { |l, i| "#{f}:#{i + 1}" }
end
hits.each { |h| warn_("#{h} — placeholder still in place") }
pass("no REPLACE_ME placeholders") if hits.empty?

# ── F. Ingress ────────────────────────────────────────────────────────────────────────
puts "== F. ingress: unique hostnames, TLS + cluster-issuer =="
hosts = Hash.new { |h, k| h[k] = [] }
DOCS.each do |f, d|
  next unless d["kind"] == "Ingress"
  name = d.dig("metadata", "name")
  (d.dig("spec", "rules") || []).each { |r| hosts[r["host"]] << f if r["host"] }
  ann = d.dig("metadata", "annotations") || {}
  warn_("#{f} — Ingress #{name} has no cert-manager.io/cluster-issuer annotation") unless ann.key?("cert-manager.io/cluster-issuer")
  warn_("#{f} — Ingress #{name} has no tls: block (no certificate will be issued)") if (d.dig("spec", "tls") || []).empty?
end
hosts.each { |h, fs| fail_("hostname #{h} claimed by #{fs.uniq.size} Ingresses (#{fs.uniq.join(', ')})") if fs.uniq.size > 1 }
pass("#{hosts.size} ingress hostnames, all unique")

# ── G. Workload hygiene ───────────────────────────────────────────────────────────────
puts "== G. workloads: readiness probe + resources (Argo health and Gatus trust these) =="
missing = 0
DOCS.each do |f, d|
  next unless %w[Deployment StatefulSet DaemonSet].include?(d["kind"])
  next if f.include?("-patch.yaml")      # strategic-merge patches are fragments: upstream supplies probes
  (d.dig("spec", "template", "spec", "containers") || []).each do |c|
    gaps = []
    gaps << "no readinessProbe" unless c["readinessProbe"]
    gaps << "no resources.requests" unless c.dig("resources", "requests")
    gaps << "no limits.memory" unless c.dig("resources", "limits", "memory")
    next if gaps.empty?
    missing += 1
    warn_("#{f} [#{c['name']}] #{gaps.join(', ')}")
  end
end
pass("every container has a readiness probe and resource bounds") if missing.zero?

puts
puts "#{WARN.size} warning(s)" unless WARN.empty?
if FAIL.empty?
  puts "CONVENTIONS OK"
else
  puts "CONVENTIONS FAILED (#{FAIL.size})"
  exit 1
end
RUBY
