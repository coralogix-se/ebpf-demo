# Troubleshooting: eBPF Traces Not Propagating Across Services

This demo relies **only on OBI (OpenTelemetry eBPF Instrumentation)** for distributed trace context propagation. No application code forwards `traceparent` or other headers; OBI injects and reads trace context at the network level.

## How OBI propagation is supposed to work

1. **Loader** (curl) calls **tier1** → no trace context on the first request; OBI on tier1’s node creates the **root span** for that trace.
2. **tier1 → tier2 → … → goblog**: For each outbound HTTP call, OBI injects W3C `traceparent` (and related context) into the request. The downstream service’s OBI reads that context and creates a **child span** with the same trace ID.
3. All spans are sent to the collector on the eBPF-only port (4320) and exported to Coralogix, so you see one trace with multiple spans across services.

**Health checks:** K8s readiness/liveness probes and init-container health checks hit `GET /health` on each service without trace context, so they would otherwise appear as many separate one-span traces. In `values-ebpf.yaml`, OBI is configured with `routes.ignored_patterns: ["/health"]` and `ignore_mode: traces`, so those requests do not produce spans. The main request flow (loader → tier1 → …) does not call `/health`, so your end-to-end trace stays one connected trace and is not split by health checks.

### Where is time spent in a trace? (“tier2 processing”, etc.)

A span’s **duration** is wall-clock time from **request received** to **response sent**. For the Node forwarders (tier1, tier2, …), that time is almost entirely **waiting on the next hop** (e.g. tier2 waiting on py27 → … → goblog), not CPU “processing”. So when you see a long “tier2 processing” (or similar) span, the time is really spent **downstream** (py27, py-demo, tier3, java-demo, tier4, dotnet-demo, tier5, goblog). The bottleneck is usually cold start or slow response in Java, .NET, or Go. The forwarder code does not add delays or extra work.

### Empty operation name on first or some spans

OBI sometimes leaves **operationName** empty on a span (e.g. the loader’s client span or dotnet-demo’s server span). This is a known quirk: the eBPF layer may not always infer the HTTP method/path for the first request or for certain runtimes (e.g. .NET minimal API). The trace is still correct and propagation works; only the display name for that span is missing. If it becomes an issue, you can filter or label in the UI by **serviceName** instead.

### Dotnet-demo "split" at GET /fetch (~15% of traces)

Occasionally the **dotnet-demo** outbound span (operationName `GET /fetch`, client call to tier5) is exported with **no parent** (`parentId`/`references` null). In the trace view this shows as a "split": the dotnet server span (receive from tier4) and the dotnet→tier5 client span appear disconnected, or the client span appears as an orphan root. This is an **OBI .NET instrumentation quirk**: under some async/threading conditions the outbound HTTP span is not linked to the current trace context. The demo uses a **shared HttpClient** and explicit **traceparent**/tracestate forwarding to reduce the chance (it may occur less often than with a per-request HttpClient). If it still happens, the trace is still valid (same trace ID), only the parent link for that one span is missing in the backend.

### Loader span still separate from tier1

If the loader appears in the same trace as tier1 but not as the parent of tier1 (e.g. shown as a separate segment), the loader’s `traceparent` may not be the one tier1 is using. Ensure (1) the loader is **excluded from OBI** (`discovery.exclude_services` with `k8s_deployment_name: "ebpf-demo-loader"` in `values-ebpf.yaml`) so only the loader’s SDK injects context, and (2) the loader uses `propagation.inject(context.active(), headers)` and passes those headers on the request to tier1. If your chart does not support `k8s_deployment_name` in exclude_services, loader and tier1 can end up with different trace IDs (loader from SDK, tier1 from OBI).

## Prerequisites (checked by the chart when `contextPropagation.enabled: true`)

When `contextPropagation.enabled: true` in `values-ebpf.yaml`, the otel-integration chart should:

- Set **hostNetwork: true** for the OBI DaemonSet (needed for network-level injection).
- Add **NET_ADMIN** to the OBI container (needed to inject headers).
- Mount **/sys/fs/cgroup** from the host (needed for socket/process discovery and propagation).

Additional requirements:

- **Kernel 5.17+** (or distro with backported eBPF/TC support) for network-level context propagation.
- **OBI runs on every node** where demo workloads run (DaemonSet). If a tier or the loader runs on a node without OBI, that hop may not be traced or linked.

## Run the investigation script

From the `ebpf-demo` directory (or with `SCRIPT_DIR` set):

```bash
./scripts/investigate-ebpf-propagation.sh [DEMO_NAMESPACE]
```

Default namespace is `ebpfdemo`. The script checks values-ebpf.yaml, then (if `kubectl` and the namespace exist) OBI DaemonSet (hostNetwork, NET_ADMIN, cgroup), OBI ConfigMap, node coverage, agent ports, and recent agent/OBI logs.

## Verification steps (no app changes)

### 1. Confirm OBI has propagation enabled

- In `values-ebpf.yaml`, under `opentelemetry-ebpf-instrumentation`:
  - `contextPropagation.enabled: true`
  - `contextPropagation.mode: "all"`
  - `env.OTEL_EBPF_BPF_TRACK_REQUEST_HEADERS: "true"`
- After deploy, check the OBI ConfigMap; the rendered config should contain:
  - `ebpf.context_propagation: "all"`

### 2. Confirm OBI pod spec (hostNetwork, capabilities, cgroup)

```bash
kubectl get daemonset -n <DEMO_NAMESPACE> -l app.kubernetes.io/name=opentelemetry-ebpf-instrumentation -o yaml
```

- Pod spec should have **hostNetwork: true**.
- Container should have **NET_ADMIN** (or run privileged).
- Volume mount for **/sys/fs/cgroup** should be present when context propagation is enabled.

### 3. OBI on all nodes where demo runs

```bash
kubectl get pods -n <DEMO_NAMESPACE> -l app.kubernetes.io/name=opentelemetry-ebpf-instrumentation -o wide
kubectl get pods -n <DEMO_NAMESPACE> -o wide  # demo workloads
```

Ensure every node that runs a demo pod (loader, tier1–tier5, py-demo, java-demo, dotnet-demo, goblog) also has an OBI pod running.

### 4. Collector receiving eBPF traces (port 4320)

- Agent (DaemonSet) should expose **hostPort 4320** and listen on `MY_POD_IP:4320`.
- OBI sends to `http://${HOST_IP}:4320`. On each node, `HOST_IP` is the node IP, so traffic goes to the agent on that node’s hostPort 4320.

Check agent logs for eBPF pipeline errors:

```bash
kubectl logs -n <DEMO_NAMESPACE> -l app.kubernetes.io/name=opentelemetry-collector --tail=200 | grep -i ebpf
```

### 5. OBI logs (attach and propagation)

Look for attach failures or propagation-related messages:

```bash
kubectl logs -n <DEMO_NAMESPACE> -l app.kubernetes.io/name=opentelemetry-ebpf-instrumentation --tail=300
```

- “java attach timed out” → increase `config.data.javaagent.attach_timeout` (e.g. already 30s in values-ebpf).
- “K8s cache service connection lost” → init container waits for k8s cache; if it still fails, check k8s-cache deployment.

### 6. Kernel version (on node)

```bash
kubectl get nodes -o wide
# On a node:
uname -r   # 5.17+ recommended for network-level propagation
```

### 7. Optional: co-locate demo on one node (for debugging)

If you see spans but they don’t link into one trace, try scheduling all demo pods on a single node so one OBI instance sees more of the traffic (useful only for debugging; propagation can work across nodes).

Example pod affinity for the loader (repeat idea for other deployments if needed):

```yaml
affinity:
  podAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      - labelSelector:
          matchLabels:
            app: ebpf-demo-tier1
        topologyKey: kubernetes.io/hostname
```

## What you should see when it works

- In Coralogix APM/Traces: one trace per loader request containing spans from **tier1, tier2, py27-demo, py-demo, tier3, java-demo, tier4, dotnet-demo, tier5, goblog** (or a subset if some are not yet instrumented).
- The **loader** (curl) is not instrumented by OBI; the **root span** is the first instrumented service (tier1).

## Cluster name alignment

eBPF spans must use the same cluster name as the rest of the integration so they group correctly in Coralogix. `redeploy-ebpf-demo.sh` sets both `global.clusterName` and `opentelemetry-ebpf-instrumentation.env.OTEL_EBPF_KUBE_CLUSTER_NAME` from `CLUSTER_NAME` (default `coralogixEbpf`). If you deploy with a different `CLUSTER_NAME`, both are updated; do not set only one in values or traces may appear under a different cluster.

## CPU and OBI resources

If traces stay incomplete even after several minutes (e.g. OBI “doesn’t see everything”), the node or OBI may be CPU-starved. OBI must process eBPF events for every instrumented process; with no resource requests it can be throttled and drop or delay spans.

- **Check usage** (requires metrics-server):
  ```bash
  kubectl top nodes
  kubectl top pods -n <DEMO_NAMESPACE> -l app.kubernetes.io/name=opentelemetry-ebpf-instrumentation
  kubectl top pods -n <DEMO_NAMESPACE>
  ```
  If OBI or the node is at or near CPU limit, increase resources or move workload.

- **Give OBI guaranteed CPU:** In `values-ebpf.yaml`, under `opentelemetry-ebpf-instrumentation`, set `resources.requests.cpu` (e.g. `250m`) and `resources.limits.cpu` so OBI isn’t throttled. On **t3.large** (2 vCPU, ~1930m allocatable per node), each node runs one OBI pod and one agent pod; keep OBI `limits.cpu` at **1** so OBI + agent (1 CPU limit each) fit. On larger nodes (e.g. t3.xlarge), you can raise OBI’s limit.

## If traces still don’t propagate

- Double-check the same **Helm values** and **chart version** used in Coralogix’s OBI distributed-tracing docs (e.g. context propagation, TRACK_REQUEST_HEADERS, hostNetwork).
- Ensure **no L7 proxy or TLS termination** between services that could strip or alter headers (this demo uses plain HTTP; that’s ideal for OBI).
- Try the same cluster with a **single-node** test (all demo pods on one node) to rule out cross-node or routing issues.
