#!/usr/bin/env bash
# Parity gate: old (kube-prometheus-stack PrometheusAgent) vs new (OTel Collector + Target Allocator)
# on a kind cluster, both remote-writing to one in-cluster VictoriaMetrics.
# Usage: tests/integration/parity-gate.sh   (env: KEEP_CLUSTER=1 to keep the cluster, WAIT=240, WAIT2=150)
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
CL=parity; CTX=kind-$CL; NS=last9
WAIT="${WAIT:-240}"; WAIT2="${WAIT2:-150}"
W="$(mktemp -d)"
K() { kubectl --context "$CTX" "$@"; }
H() { helm --kube-context "$CTX" "$@"; }
FAIL=0
fail() { echo "GATE FAIL: $*"; FAIL=1; }
cleanup() {
  [ -n "${PF:-}" ] && kill "$PF" 2>/dev/null
  [ "${KEEP_CLUSTER:-0}" = 1 ] || kind delete cluster --name "$CL" >/dev/null 2>&1
}
trap cleanup EXIT

free_gb=$(df -g / | awk 'NR==2{print $4}')
[ "$free_gb" -ge 6 ] || { echo "only ${free_gb}GiB free, need 6"; exit 2; }
for c in kind helm kubectl docker python3 perl; do command -v $c >/dev/null || { echo "missing $c"; exit 2; }; done
kind get clusters 2>/dev/null | grep -qx "$CL" && { echo "kind cluster $CL already exists; delete it first"; exit 2; }

echo "### 1. kind cluster"
kind create cluster --name "$CL" --wait 120s || exit 2

echo "### 2. VictoriaMetrics"
K create ns $NS
K -n $NS apply -f - <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata: {name: victoria-metrics}
spec:
  replicas: 1
  selector: {matchLabels: {app: victoria-metrics}}
  template:
    metadata: {labels: {app: victoria-metrics}}
    spec:
      containers:
        - name: vm
          image: victoriametrics/victoria-metrics:latest
          args: ["-retentionPeriod=1d", "-search.latencyOffset=0s"]
          ports: [{containerPort: 8428}]
---
apiVersion: v1
kind: Service
metadata: {name: victoria-metrics}
spec:
  selector: {app: victoria-metrics}
  ports: [{port: 8428}]
YAML
K -n $NS rollout status deploy/victoria-metrics --timeout=300s || exit 2
VM_RW="http://victoria-metrics.$NS.svc:8428/api/v1/write"
K -n $NS create secret generic last9-remote-write-secret --from-literal=username=u --from-literal=password=p

echo "### 3. old stack (kube-prometheus-stack 75.15.1)"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts >/dev/null 2>&1
helm repo update >/dev/null 2>&1
sed -e "s|{{YOUR_MONITORING_ENDPOINT}}|$VM_RW|" -e 's|my-cluster-name|parity|' \
  "$ROOT/tests/fixtures/k8s-monitoring-values.e1ad5c9.yaml" > "$W/old.yaml"
cat > "$W/old-extra.yaml" <<'YAML'
prometheus:
  prometheusSpec:
    externalLabels: {cluster: parity, pipeline: prom}
YAML
# same keep regex plus parity_app_.* (applied in phase 2)
sed -e 's#kube_statefulset_status_replicas_updated"#kube_statefulset_status_replicas_updated|parity_app_.*"#' "$W/old.yaml" > "$W/old-app.yaml"
cmp -s "$W/old.yaml" "$W/old-app.yaml" && { echo "old keep-regex patch did not apply"; exit 2; }
H install last9-k8s-monitoring prometheus-community/kube-prometheus-stack --version 75.15.1 -n $NS \
  -f "$W/old.yaml" -f "$W/old-extra.yaml" --wait --timeout 8m || { echo "old stack install failed"; exit 2; }

echo "### 4. new scraper (TA 0.156.0 + collector 0.165.0)"
# the kps kubelet ServiceMonitor exists only because the old stack is installed; the new TA scrapes kubelet via role:node jobs
K -n $NS get servicemonitors.monitoring.coreos.com -l app=kube-prometheus-stack-kubelet -o name | grep -q . \
  || { echo "kps kubelet ServiceMonitor label app=kube-prometheus-stack-kubelet not found"; K get servicemonitors.monitoring.coreos.com -A --show-labels; exit 2; }
perl -pe 's/^(\s*)service_monitor_selector: \{\}/$1service_monitor_selector:\n$1  matchExpressions:\n$1    - {key: app, operator: NotIn, values: [kube-prometheus-stack-kubelet]}/' \
  "$ROOT/last9-target-allocator-values.yaml" > "$W/ta.yaml"
grep -q NotIn "$W/ta.yaml" || { echo "TA selector patch did not apply"; exit 2; }
perl -pe 's/^(\s*)cluster: "\{\{CLUSTER_NAME\}\}"/$1cluster: "parity"\n$1pipeline: otel/; s/\{\{LAST9_METRICS_ENDPOINT\}\}/'"${VM_RW//\//\\/}"'/; s/\{\{APP_METRICS_KEEP_ALT\}\}//' \
  "$ROOT/last9-otel-metrics-values.yaml" > "$W/otel.yaml"
perl -pe 's/\{\{APP_METRICS_KEEP_ALT\}\}/|parity_app_.*/' "$ROOT/last9-otel-metrics-values.yaml" \
  | perl -pe 's/^(\s*)cluster: "\{\{CLUSTER_NAME\}\}"/$1cluster: "parity"\n$1pipeline: otel/; s/\{\{LAST9_METRICS_ENDPOINT\}\}/'"${VM_RW//\//\\/}"'/' > "$W/otel-app.yaml"
grep -q 'pipeline: otel' "$W/otel.yaml" && ! grep -v '^ *#' "$W/otel.yaml" | grep -q '{{' || { echo "collector values fill failed"; exit 2; }
# GATE WORKAROUND (finding for the values file): with every receiver port disabled the chart renders a Service with
# no ports and the install fails ("spec.ports: Required value"). Disabled here, not in last9-otel-metrics-values.yaml.
printf 'service:\n  enabled: false\n' > "$W/svc-off.yaml"
H install last9-target-allocator open-telemetry/opentelemetry-target-allocator --version 0.156.0 -n $NS -f "$W/ta.yaml" --wait --timeout 5m || { echo "TA install failed"; exit 2; }
H install last9-otel-metrics open-telemetry/opentelemetry-collector --version 0.165.0 -n $NS -f "$W/otel.yaml" -f "$W/svc-off.yaml" --wait --timeout 5m || { echo "collector install failed"; exit 2; }

echo "### 5. sample app"
K create ns parity-app
K apply -f "$HERE/fixtures/sample-app.yaml" || exit 2
K -n parity-app rollout status deploy/parity-app --timeout=300s || exit 2

K -n $NS port-forward svc/victoria-metrics 18428:8428 >/dev/null 2>&1 & PF=$!
sleep 3
VM=http://127.0.0.1:18428
D() { python3 -I "$HERE/parity_diff.py" "$VM" pipeline=prom pipeline=otel "$@"; }

echo "### 6. waiting ${WAIT}s"; sleep "$WAIT"

echo "### 7. parity diff (default keep)"
D --queries "$HERE/fixtures/parity-queries.txt" --name-regex '(?!parity_app_).*' || fail "parity diff (default)"

echo "### 8. default-keep: parity_app_* absent from both"
for p in prom otel; do
  n=$(curl -s -G "$VM/api/v1/series" --data-urlencode "match[]={__name__=~\"parity_app_.*\",pipeline=\"$p\"}" | python3 -I -c 'import sys,json;print(len(json.load(sys.stdin)["data"]))')
  [ "$n" = 0 ] || fail "parity_app_* present in $p without opt-in ($n series)"
done

echo "### 9. app-metrics opt-in (both pipelines)"
H upgrade last9-otel-metrics open-telemetry/opentelemetry-collector --version 0.165.0 -n $NS -f "$W/otel-app.yaml" -f "$W/svc-off.yaml" --wait --timeout 5m || fail "collector upgrade"
H upgrade last9-k8s-monitoring prometheus-community/kube-prometheus-stack --version 75.15.1 -n $NS -f "$W/old-app.yaml" -f "$W/old-extra.yaml" --wait --timeout 8m || fail "old upgrade"
echo "waiting ${WAIT2}s"; sleep "$WAIT2"
for m in parity_app_requests_total parity_app_latency_seconds_bucket parity_app_latency_seconds_sum parity_app_latency_seconds_count; do
  n=$(curl -s -G "$VM/api/v1/series" --data-urlencode "match[]={__name__=\"$m\",pipeline=\"otel\"}" | python3 -I -c 'import sys,json;print(len(json.load(sys.stdin)["data"]))')
  [ "$n" -gt 0 ] || fail "otel missing $m after opt-in"
done
curl -s -G "$VM/api/v1/series" --data-urlencode 'match[]={__name__="parity_app_latency_seconds_bucket",pipeline="otel",le!=""}' \
  | python3 -I -c 'import sys,json;sys.exit(0 if json.load(sys.stdin)["data"] else 1)' || fail "otel histogram bucket has no le label"
D --name-regex 'parity_app_.*' || fail "parity_app_* diff"

echo "### TA logs (config errors)"
K -n $NS logs deploy/last9-target-allocator-ta --tail=200 2>&1 | grep -i -E 'error|unknown|unmarshal|field' | head -20 || true
[ $FAIL = 0 ] && echo "GATE PASS" || echo "GATE FAILED"
exit $FAIL
