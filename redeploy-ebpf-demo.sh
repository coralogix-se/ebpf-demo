#!/bin/bash
# Delete ebpfdemo, recreate it, deploy collector first, then eBPF demo.
# Requires: CORALOGIX_PRIVATE_KEY
# Optional: CORALOGIX_DOMAIN (default cx498.coralogix.com), CLUSTER_NAME (default coralogixEbpf)

set -euo pipefail

if [ -z "${CORALOGIX_PRIVATE_KEY:-}" ]; then
  echo "Error: CORALOGIX_PRIVATE_KEY must be set."
  exit 1
fi

NAMESPACE="${DEMO_NAMESPACE:-ebpfdemo}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Pin chart version to avoid "unable to find exact version; falling back to closest" warning. Override with HELM_VERSION env.
HELM_VERSION="${HELM_VERSION:-0.0.317}"
CORALOGIX_DOMAIN="${CORALOGIX_DOMAIN:-cx498.coralogix.com}"
CLUSTER_NAME="${CLUSTER_NAME:-coralogixEbpf}"

echo "[1/5] Deleting namespace ${NAMESPACE} (if present)..."
kubectl delete namespace "${NAMESPACE}" --timeout=120s 2>/dev/null || true

echo "[2/5] Creating namespace ${NAMESPACE}..."
kubectl create namespace "${NAMESPACE}"

echo "[3/5] Creating secrets..."
kubectl create secret generic coralogix-keys \
  --from-literal=PRIVATE_KEY="${CORALOGIX_PRIVATE_KEY}" \
  -n "${NAMESPACE}" \
  --dry-run=client -o yaml | kubectl apply -f - -n "${NAMESPACE}"

echo "[4/5] Deploying Coralogix OTEL collector (values-ebpf)..."
helm repo add coralogix https://cgx.jfrog.io/artifactory/coralogix-charts-virtual 2>/dev/null || true
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts 2>/dev/null || true
helm repo update

# OBI cluster name must match global.clusterName so eBPF spans and other data group together in Coralogix
# --server-side=false avoids "metadata.managedFields must be nil" on some clusters (Helm 4+)
helm upgrade --install otel-coralogix-integration coralogix/otel-integration \
  --values "${SCRIPT_DIR}/otel-integration/values-ebpf.yaml" \
  --namespace "${NAMESPACE}" \
  --version "${HELM_VERSION}" \
  --set global.domain="${CORALOGIX_DOMAIN}" \
  --set global.clusterName="${CLUSTER_NAME}" \
  --set opentelemetry-ebpf-instrumentation.env.OTEL_EBPF_KUBE_CLUSTER_NAME="${CLUSTER_NAME}" \
  --disable-openapi-validation \
  --server-side=false \
  --wait --timeout 5m

echo "[5/5] Deploying eBPF demo (tiers, py/java/dotnet/go forwarders, loader)..."
kubectl apply -f "${SCRIPT_DIR}/ebpf-demo.yaml" -n "${NAMESPACE}"

echo "Done. Collector is up; eBPF demo pods may take 1–2 min to become Ready (Java/.NET/Go compile on first run)."
