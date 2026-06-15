#!/usr/bin/env bash
# Investigate eBPF trace propagation per TROUBLESHOOTING_EBPF_PROPAGATION.md.
# Run from repo root or with SCRIPT_DIR pointing at ebpf-demo.
# Usage: ./scripts/investigate-ebpf-propagation.sh [DEMO_NAMESPACE]
#   DEMO_NAMESPACE defaults to ebpfdemo.

set -euo pipefail

NAMESPACE="${1:-ebpfdemo}"
SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
VALUES="${SCRIPT_DIR}/otel-integration/values-ebpf.yaml"

echo "=== eBPF propagation investigation (namespace: ${NAMESPACE}) ==="
echo ""

# --- 1. Config verification (no cluster needed) ---
echo "--- 1. values-ebpf.yaml: context propagation and OBI env ---"
if [ ! -f "${VALUES}" ]; then
  echo "FAIL: ${VALUES} not found"
else
  if grep -q 'contextPropagation:' "${VALUES}" && grep -q 'enabled: true' "${VALUES}"; then
    echo "OK: contextPropagation present and enabled"
  else
    echo "WARN: contextPropagation.enabled not clearly true in values"
  fi
  if grep -q 'mode: "all"' "${VALUES}"; then
    echo "OK: contextPropagation.mode is \"all\""
  else
    echo "WARN: contextPropagation.mode \"all\" not found"
  fi
  if grep -q 'OTEL_EBPF_BPF_TRACK_REQUEST_HEADERS' "${VALUES}" && grep -q '"true"' "${VALUES}"; then
    echo "OK: OTEL_EBPF_BPF_TRACK_REQUEST_HEADERS is set to true"
  else
    echo "WARN: OTEL_EBPF_BPF_TRACK_REQUEST_HEADERS not set or not true"
  fi
  if grep -q 'otel_traces_export' "${VALUES}" && grep -q '4320' "${VALUES}"; then
    echo "OK: OBI trace export endpoint uses port 4320"
  else
    echo "WARN: OBI otel_traces_export / 4320 not found"
  fi
  if grep -q 'otlp/ebpf' "${VALUES}" && grep -q '4320' "${VALUES}"; then
    echo "OK: Collector otlp/ebpf receiver uses 4320"
  else
    echo "WARN: Collector eBPF receiver (4320) not found"
  fi
fi
echo ""

# --- 2–7. Cluster checks (skip if kubectl or namespace missing) ---
if ! command -v kubectl &>/dev/null; then
  echo "--- Skipping cluster checks (kubectl not found) ---"
  echo "  Run the commands in TROUBLESHOOTING_EBPF_PROPAGATION.md manually."
  exit 0
fi

if ! kubectl get namespace "${NAMESPACE}" &>/dev/null; then
  echo "--- Skipping cluster checks (namespace ${NAMESPACE} not found) ---"
  echo "  Deploy with: redeploy-ebpf-demo.sh (after setting CORALOGIX_PRIVATE_KEY)"
  exit 0
fi

echo "--- 2. OBI DaemonSet: hostNetwork, NET_ADMIN, cgroup ---"
OBI_DS="$(kubectl get daemonset -n "${NAMESPACE}" -l app.kubernetes.io/name=opentelemetry-ebpf-instrumentation -o name 2>/dev/null | head -1)"
if [ -z "${OBI_DS}" ]; then
  echo "WARN: No OBI DaemonSet found in ${NAMESPACE}"
else
  if kubectl get "${OBI_DS}" -n "${NAMESPACE}" -o yaml | grep -q 'hostNetwork: true'; then
    echo "OK: OBI pod spec has hostNetwork: true"
  else
    echo "FAIL: OBI pod spec missing hostNetwork: true (required for context propagation)"
  fi
  if kubectl get "${OBI_DS}" -n "${NAMESPACE}" -o yaml | grep -q 'NET_ADMIN'; then
    echo "OK: OBI container has NET_ADMIN capability"
  else
    if kubectl get "${OBI_DS}" -n "${NAMESPACE}" -o yaml | grep -q 'privileged: true'; then
      echo "OK: OBI runs privileged (includes NET_ADMIN)"
    else
      echo "FAIL: OBI has neither NET_ADMIN nor privileged"
    fi
  fi
  if kubectl get "${OBI_DS}" -n "${NAMESPACE}" -o yaml | grep -q '/sys/fs/cgroup'; then
    echo "OK: OBI has /sys/fs/cgroup volume mount"
  else
    echo "WARN: OBI missing /sys/fs/cgroup mount (may affect propagation)"
  fi
fi
echo ""

echo "--- 3. OBI ConfigMap: ebpf.context_propagation ---"
OBI_CM="$(kubectl get configmap -n "${NAMESPACE}" -l app.kubernetes.io/name=opentelemetry-ebpf-instrumentation -o name 2>/dev/null | head -1)"
if [ -n "${OBI_CM}" ]; then
  if kubectl get "${OBI_CM}" -n "${NAMESPACE}" -o yaml | grep -q 'context_propagation'; then
    echo "OK: OBI config contains context_propagation"
  else
    echo "WARN: OBI config missing context_propagation"
  fi
else
  echo "WARN: OBI ConfigMap not found"
fi
echo ""

echo "--- 4. OBI on all nodes vs demo workloads ---"
OBI_NODES="$(kubectl get pods -n "${NAMESPACE}" -l app.kubernetes.io/name=opentelemetry-ebpf-instrumentation -o jsonpath='{.items[*].spec.nodeName}' 2>/dev/null | tr ' ' '\n' | sort -u)"
DEMO_NODES="$(kubectl get pods -n "${NAMESPACE}" -o jsonpath='{.items[*].spec.nodeName}' 2>/dev/null | tr ' ' '\n' | sort -u)"
if [ -n "${OBI_NODES}" ] && [ -n "${DEMO_NODES}" ]; then
  MISSING=""
  for n in ${DEMO_NODES}; do
    if ! echo "${OBI_NODES}" | grep -q "^${n}$"; then
      MISSING="${MISSING} ${n}"
    fi
  done
  if [ -z "${MISSING}" ]; then
    echo "OK: Every node running demo pods also has an OBI pod"
  else
    echo "WARN: Nodes with demo but no OBI:${MISSING}"
  fi
else
  echo "INFO: OBI nodes: ${OBI_NODES:-none}; Demo nodes: ${DEMO_NODES:-none}"
fi
echo ""

echo "--- 5. Collector (agent) eBPF ports 4319/4320 ---"
AGENT_POD="$(kubectl get pods -n "${NAMESPACE}" -l app.kubernetes.io/name=opentelemetry-collector -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
if [ -n "${AGENT_POD}" ]; then
  if kubectl get pod "${AGENT_POD}" -n "${NAMESPACE}" -o yaml | grep -q 'containerPort: 4320'; then
    echo "OK: Agent pod exposes containerPort 4320"
  else
    echo "WARN: Agent pod may not expose 4320 (check ports.otlp-ebpf-http)"
  fi
  if kubectl get pod "${AGENT_POD}" -n "${NAMESPACE}" -o yaml | grep -q 'hostPort: 4320'; then
    echo "OK: Agent pod has hostPort 4320"
  else
    echo "WARN: Agent pod may not have hostPort 4320"
  fi
else
  echo "WARN: No collector (agent) pod found in ${NAMESPACE}"
fi
echo ""

echo "--- 6. Agent logs (last 50 lines, eBPF-related) ---"
if [ -n "${AGENT_POD}" ]; then
  out=$(kubectl logs "${AGENT_POD}" -n "${NAMESPACE}" --tail=50 2>/dev/null | grep -i ebpf || true); echo "${out:-"(no ebpf mentions in last 50 lines)"}"
else
  echo "(skipped: no agent pod)"
fi
echo ""

echo "--- 7. OBI logs (last 30 lines, errors/attach) ---"
OBI_POD="$(kubectl get pods -n "${NAMESPACE}" -l app.kubernetes.io/name=opentelemetry-ebpf-instrumentation -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
if [ -n "${OBI_POD}" ]; then
  out=$(kubectl logs "${OBI_POD}" -n "${NAMESPACE}" --tail=30 2>/dev/null | grep -iE 'error|attach|propagation|traceparent|context' || true); echo "${out:-"(no matching lines in last 30)"}"
else
  echo "(skipped: no OBI pod)"
fi
echo ""

echo "=== Done. See TROUBLESHOOTING_EBPF_PROPAGATION.md for kernel check and next steps. ==="
