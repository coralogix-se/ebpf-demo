# values-ebpf.yaml — eBPF-only span metrics

This file explains what is different in **values-ebpf.yaml** compared to a default or standard otel-integration setup, and why those changes were made.

## Goal

- **No application traces** sent to Coralogix (no trace export, no trace-based costs).
- **Span metrics and APM** in Coralogix populated **only from eBPF** (inferred spans from the kernel), not from SDK/app traces.
- **Metrics and logs** unchanged: still sent to Coralogix as usual.
- **Apps are not broken**: they can still send traces to the agent; the agent accepts and drops them (debug exporter) so SDKs don’t see connection failures.

---

## What’s different and why

### 1. Agent: Coralogix only on metrics and logs

```yaml
opentelemetry-agent:
  presets:
    coralogixExporter:
      pipelines: ["metrics", "logs"]   # traces excluded
```

- **Default:** Coralogix exporter is on all three pipelines (metrics, logs, traces).
- **Here:** Coralogix is only on `metrics` and `logs`. Traces are never sent to Coralogix.

**Why:** We don’t want any trace export to Coralogix; we only want eBPF-derived span metrics.

---

### 2. Agent: App traces accepted but dropped

```yaml
opentelemetry-agent:
  config:
    service:
      pipelines:
        traces:
          exporters: [debug]
```

- **Default:** Traces pipeline exports to `coralogix`.
- **Here:** Traces pipeline exports only to `debug` (and we added `exporters.debug: {}`). So app traces are still **received** on the normal OTLP ports (4317/4318) but then **dropped** (not sent anywhere useful).

**Why:** Applications keep sending traces to the agent; the agent must have at least one exporter per pipeline. Using `debug` avoids connection errors and SDK retries while ensuring no traces go to Coralogix.

---

### 3. Agent: No head-sampling / no `traces/sampled`

```yaml
headSampling:
  enabled: false
```

- **Default:** Can be enabled, which creates a `traces/sampled` pipeline that exports to Coralogix.
- **Here:** Head sampling is disabled so there is no `traces/sampled` pipeline exporting traces.

**Why:** With head sampling on, the chart would still send (sampled) traces to Coralogix via `traces/sampled`. We want zero trace export, so we disable it.

---

### 4. Agent: No span metrics from the main traces pipeline

```yaml
spanMetrics:
  enabled: false
```

- **Default:** When enabled, the main traces pipeline feeds the spanmetrics connector, so **all** traces (app + eBPF) generate span metrics.
- **Here:** Span metrics are disabled on the **main** traces pipeline.

**Why:** We don’t want span metrics derived from application traces. We only want span metrics from eBPF traces, on a separate path (see below).

---

### 5. Agent: eBPF-only OTLP ports and pipeline

**New ports (eBPF only):**

- **4319** — gRPC (eBPF profiler).
- **4320** — HTTP (eBPF instrumentation traces).

**New config:**

- **Receiver** `otlp/ebpf`: listens on `${MY_POD_IP}:4319` (gRPC) and `:4320` (HTTP).
- **Connector** `spanmetrics/ebpf`: turns traces into RED metrics.
- **Pipeline** `traces/ebpf`: `receivers: [otlp/ebpf]` → `exporters: [spanmetrics/ebpf, coralogix]`.
- **Metrics pipeline:** `spanmetrics/ebpf` added as an extra **receiver**, so its output goes to the existing metrics pipeline → Coralogix.

**Why:** Only eBPF is configured to send traces to 4319/4320. So only eBPF traces enter `traces/ebpf`. They are sent to Coralogix as **traces** (so you can see eBPF spans in Coralogix) and also to **spanmetrics/ebpf** so **span metrics in Coralogix come only from eBPF** for APM. App traces remain dropped (main `traces` pipeline → debug only).

---

### 6. OBI: Wait for k8s cache (init container)

```yaml
opentelemetry-ebpf-instrumentation:
  initContainers:
    - name: wait-for-k8s-cache
      image: busybox:1.36
      command: [ "sh", "-c", "until nc -z opentelemetry-ebpf-instrumentation-k8s-cache 50055; do sleep 2; done; echo K8s cache is ready" ]
```

- **Default:** OBI DaemonSet pods start immediately; if the k8s-cache deployment is not ready yet, OBI logs "K8s cache service connection lost. Reconnecting..." and may miss metadata until it reconnects.
- **Here:** An init container waits until the k8s-cache service (port 50055) is reachable before the main OBI container starts.

**Why:** The cache provides Kubernetes metadata for spans (pod, deployment, etc.). Making OBI wait for it keeps the cache "happy" and avoids startup connection errors and missing attributes.

---

### 7. Agent: Pointing eBPF at the new ports

**Coralogix eBPF Profiler (disabled in values-ebpf):**

The eBPF profiler is **disabled** because it sends to `opentelemetry.proto.collector.profiles.v1development.ProfilesService`, which the collector does not implement, leading to: `rpc error: code = Unimplemented desc = unknown service ... ProfilesService`. eBPF traces still come from **OpenTelemetry eBPF Instrumentation (OBI)** only.

```yaml
coralogix-ebpf-profiler:
  enabled: false
```

If you still see profiler errors after upgrade, remove any existing profiler workload:  
`kubectl get daemonset,deployment -n <namespace> | grep -i profiler` then delete the profiler DaemonSet/Deployment.

**OpenTelemetry eBPF Instrumentation:**

```yaml
opentelemetry-ebpf-instrumentation:
  contextPropagation:
    enabled: true
    mode: "all"   # required for full distributed traces (network-level propagation)
  config:
    data:
      otel_traces_export:
        endpoint: "http://${HOST_IP}:4320"
```

**Why:** The instrumentation uses HTTP 4320; that port feeds the `traces/ebpf` → spanmetrics pipeline. App traces stay on 4317/4318 and never enter span metrics. **`contextPropagation.mode: "all"`** enables network-level trace context propagation (W3C `traceparent` injection); without it, OBI uses `"http,tcp"` by default and network-level propagation is disabled, so traces appear as disconnected single spans instead of linked distributed traces.

---

### 8. Cluster collector: No trace export, no profiles pipeline

- **Coralogix:** The cluster collector uses the same pattern as the agent: **`presets.coralogixExporter.pipelines: ["metrics", "logs"]`** so the chart does not add the coralogix exporter to the traces pipeline. **`config.service.pipelines.traces.exporters: [debug]`** and **`config.exporters.debug: {}`** ensure the traces pipeline is valid and drops traces instead of sending them to Coralogix.
- **Profiles:** The `profiles` pipeline and the `service.profilesSupport` feature gate are not used in values-ebpf, because the collector does not implement `ProfilesService` (v1development); keeping them would cause the eBPF profiler to log "unknown service ProfilesService" if the profiler were enabled.

**Why (obsolete):** So the cluster collector starts successfully with the profiles pipeline enabled; without this flag it would fail with “profiling signal support is at alpha level, gated under service.profilesSupport”.

---

### 9. Cluster collector: spanMetrics disabled

```yaml
opentelemetry-cluster-collector:
  presets:
    spanMetrics:
      enabled: false
```

**Why:** We don’t want the cluster collector to generate span metrics from any traces it might see; span metrics are generated only on the agent from the eBPF-only pipeline.

---

## Pipeline summary

| Pipeline        | Receivers              | Exporters        | Result |
|----------------|------------------------|------------------|--------|
| **traces**     | otlp (4317/4318), …   | debug            | App traces accepted, dropped. **Not** in span metrics. |
| **traces/ebpf**| otlp/ebpf (4319/4320)  | spanmetrics/ebpf, coralogix | eBPF traces → Coralogix (as traces) and → span metrics → metrics pipeline → Coralogix. |
| **metrics**    | …, spanmetrics/ebpf, …| coralogix        | Normal metrics + eBPF-derived span metrics to Coralogix. |
| **logs**       | …                      | coralogix        | Unchanged. |

So: **traces are not in the spanmetrics pipeline** except for the **traces/ebpf** pipeline, which contains only eBPF traces.

---

## Port reference

| Port  | Protocol | Used by        | Purpose                    |
|-------|----------|----------------|----------------------------|
| 4317  | gRPC     | Applications   | OTLP traces (accepted, then dropped). |
| 4318  | HTTP     | Applications   | OTLP traces/metrics/logs (traces dropped). |
| 4319  | gRPC     | eBPF profiler  | eBPF-only traces → span metrics. |
| 4320  | HTTP     | eBPF instrumentation | eBPF-only traces → span metrics. |

---

## How to use

1. Install or upgrade with this values file (and any other values you need):

   ```bash
   helm upgrade --install otel-coralogix-integration <chart> \
     -n <namespace> \
     -f values.yaml \
     -f values-ebpf.yaml
   ```

2. Ensure eBPF components (profiler, instrumentation) are enabled and use the endpoints above; they are already set in **values-ebpf.yaml**.

3. In Coralogix you get:
   - **Metrics:** normal metrics + span metrics from eBPF only.
   - **Logs:** unchanged.
   - **Traces:** none (no trace export).
   - **APM:** populated from eBPF-derived span metrics only.

---

## Troubleshooting: spans but no decent-sized traces

If you see many spans but traces stay small (e.g. 1–2 spans per trace instead of a full request chain), check the following.

1. **Context propagation**  
   Confirm the eBPF instrumentation pod has `OTEL_EBPF_BPF_CONTEXT_PROPAGATION=all`:
   ```bash
   kubectl exec -n <namespace> <obi-pod> -- env | grep OTEL_EBPF_BPF_CONTEXT_PROPAGATION
   ```
   In this setup it is set via `contextPropagation.mode: "all"` in values.

2. **L7 proxy (e.g. Envoy / frontend-proxy)**  
   OBI’s **TCP-level** propagation does not traverse L7 proxies: the proxy terminates the connection and opens new ones, so trace context must be carried in **HTTP headers** (e.g. `traceparent`). OBI does inject `traceparent` in outgoing HTTP headers when propagation is enabled. If the proxy strips or does not forward that header to backends, you get disconnected traces. Ensure the proxy forwards `traceparent` (and optionally `tracestate`) to backends, or use the proxy’s native OpenTelemetry tracing so it participates in the trace.

3. **K8s cache connection**  
   At startup, OBI logs `K8s cache service connection lost. Reconnecting...` if the metadata cache is not ready. Without the cache, Kubernetes attributes (e.g. pod name, deployment) can be missing or wrong, and trace grouping can suffer. **values-ebpf.yaml** includes an **init container** (`wait-for-k8s-cache`) that blocks the OBI DaemonSet pod until `opentelemetry-ebpf-instrumentation-k8s-cache:50055` is reachable, so the main OBI container only starts after the cache is ready. If you still see connection errors, ensure the k8s-cache deployment is running and that the init container’s service name matches your release (the chart uses `k8sCache.service.name`; if you override it, update the init container’s host in values).

4. **Cluster name**  
   Set `env.OTEL_EBPF_KUBE_CLUSTER_NAME` (e.g. to `global.clusterName`) so OBI can attach the cluster name to spans; this improves filtering and grouping in Coralogix.

5. **Java / TLS**  
   If you see `couldn't attach OpenTelemetry eBPF Java Agent` or `unable to attach java agent to process`, that service will not get Java-level (e.g. TLS) context propagation; other services can still form linked traces via HTTP propagation. **values-ebpf.yaml** sets **`javaagent.attach_timeout: 30s`** (default 10s) so slow JVMs (e.g. Kafka, ad, fraud-detection) have more time to respond to runtime attach and fewer "java attach timed out" errors occur. If you still see **"error reading line EOF"** for a Java process, the JVM may be closing the attach stream early (e.g. under load); increasing timeout does not fix that—consider starting that JVM with `-javaagent` if you need TLS telemetry for it.

6. **Services with no traces (checkout, payment, quote, shipping, product-catalog)**  
   If important backends show **no traces at all**, common causes and fixes:

   - **Process age:** OBI ignores processes younger than `min_process_age` (default 5s). Pods that handle traffic immediately after start can miss instrumentation. **values-ebpf.yaml** sets **`discovery.min_process_age: 2s`** so backends are instrumented sooner; adjust if needed.
   - **Trace context not propagated:** If traffic goes **Browser → Envoy (frontend-proxy) → Frontend → backends**, the proxy must forward **`traceparent`** (and optionally `tracestate`) to the frontend and the frontend must send them on to backends. OBI injects `traceparent` on outgoing HTTP from instrumented processes; if the **incoming** request to the frontend has no trace context (e.g. Envoy doesn’t forward it), the frontend still starts a trace and should propagate it to checkout/payment/etc. If the proxy **strips** or **overwrites** trace headers, backends get new trace IDs and appear as single-span traces or “missing” when you look at the full request trace. **Fix:** Configure the frontend-proxy (Envoy) to **forward** `traceparent` and `tracestate` on requests to the frontend (and on any proxy-to-backend hops). Envoy’s router forwards headers by default; if you use custom config that strips headers, add `request_headers_to_copy` or stop stripping these.
   - **gRPC / Go:** Backends like checkout and product-catalog often use **gRPC**. OBI supports gRPC (HTTP/2); if a specific Go binary or library doesn’t use the hooked code paths, you may see no spans. Check OBI logs for “instrumenting process … checkout” (or similar) to confirm the process was attached; if it was attached but still no spans, the traffic may not be on a captured path.
   - **Single-span traces:** Backend spans may exist but in **separate traces** (one span per trace) if context wasn’t propagated. In Coralogix, search by **service name** (e.g. `checkout`) and look for single-span traces; if present, the fix is propagation (Envoy/frontend forwarding trace headers), not discovery.

7. **Traces not joined; Action often empty**  
   If you see **every service** but traces are **not linked** (each service in its own trace or disconnected), and the **Action** field is often empty:

   - **Propagation (why traces don’t join):**  
     - **First hop (e.g. Envoy → Frontend):** The frontend-proxy must send **`traceparent`** (and optionally **`tracestate`**) on requests to the frontend. Envoy’s OpenTelemetry tracer normally injects the current trace context on upstream requests; if you use custom header manipulation, ensure you do **not** strip or overwrite `traceparent`/`tracestate`. If headers are not reaching the frontend, add under the **virtual_host** (e.g. `name: frontend`) in Envoy’s `route_config`:
       ```yaml
       request_headers_to_add:
         - header:
             key: traceparent
             value: "%REQ(traceparent)%"
             append_action: OVERWRITE_IF_EXISTS_OR_ADD
         - header:
             key: tracestate
             value: "%REQ(tracestate)%"
             append_action: OVERWRITE_IF_EXISTS_OR_ADD
       ```
       (Only add this if the client or an earlier hop sends these headers; otherwise leave propagation to Envoy’s tracer.)  
     - **Service-to-service (e.g. Frontend → checkout):** OBI injects `traceparent` on **HTTP** outbound requests when `contextPropagation.mode: "all"`. If calls are **gRPC**, context must be in gRPC **metadata** (HTTP/2 headers). OBI may not inject into gRPC client metadata in all runtimes (e.g. Node or Go gRPC); if so, you get separate traces per service. **Workaround:** Ensure the app (or an interceptor) adds W3C trace context to gRPC metadata for outbound calls, or use HTTP between services where possible.  
     - **Check:** In Coralogix, open a trace that should be end-to-end; if you see multiple trace IDs or only one span per trace, propagation is failing at the hop where the trace “splits”.

   - **Action field empty:**  
     Coralogix often maps **Action** from **span name** or **`http.route`**. **values-ebpf.yaml** sets **`routes.unmatch: heuristic`** so OBI’s routes decorator runs and sets **`http.route`** (and span names) where possible. If Action is still empty: (1) In Coralogix APM settings, check which span attribute or span name is used for “Action” and ensure it’s set (e.g. `http.route`, `rpc.service`/`rpc.method` for gRPC, or span name). (2) For gRPC, OBI may set `rpc.service` and `rpc.method`; if Coralogix expects `http.route`, you may need to map Action from those attributes or from span name.

---

## Log correlation: trace ID in log attributes

Demo apps (Node, Python, Java, .NET) log JSON to stdout with `traceId`, `parentId`, and `service` inside the log body. If your backend (e.g. Coralogix) expects **top-level** `traceId` (and optionally `parentId`, `service.name`) for log–trace correlation, the raw log record has those only inside the `message` field.

**values-ebpf.yaml** defines a transform processor **`transform/log_json_promote`** that:

- Parses the log body as JSON when it is a string.
- Copies `traceId` → `attributes["traceId"]`, `parentId` → `attributes["parentId"]`, `service` → `attributes["service.name"]`.

So exported logs get top-level attributes for correlation. For this to run, the **logs** pipeline must include `transform/log_json_promote` (typically as the first processor, before `batch`). The preset may define the logs pipeline; if your chart merges user config with the preset, you can add under `config.service.pipelines`:

```yaml
logs:
  processors: [transform/log_json_promote, batch]
```

If the chart does not merge and that would replace the pipeline (losing receivers/exporters), add the processor via the chart’s mechanism for extra log processors or use Coralogix log pipeline rules to parse the message as JSON and promote `traceId` to a top-level field.

---

## Files

- **values-ebpf.yaml** — Helm values for the eBPF-only span-metrics setup described above.
- **README_ebpf.md** — This file; explains what’s different and why.
