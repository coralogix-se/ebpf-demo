# eBPF Demo – Build and Deploy

A minimal multi-service demo that showcases **OpenTelemetry eBPF Instrumentation (OBI)** only: no SDK or app-level trace code. All tracing and propagation are done by eBPF. Services emit **synchronous JSON logs** to stdout; OBI **log_enricher** injects `trace_id` and `span_id` for log-to-trace correlation in Coralogix.

## Request flow (bitmap random walk)

**Loader** (plain Node) calls **tier1** with header `X-Visited-Bitmap: 0`. Each service then:

1. Sets its own bit in the bitmap (by index: tier1=0, tier2=1, …, goblog=9).
2. If all bits are set, returns `200` with body `done` (trace ends).
3. Otherwise picks a **random unvisited** service and forwards the request with the updated bitmap and W3C `traceparent`/`tracestate`.

- **Loader** – Node; calls tier1 on an interval. Instrumented by OBI; injects trace context.
- **tier1–tier5** – Node forwarders (shared `forwarder.js`).
- **py27-demo** – Python 2.7 (eBPF-only; no OTel SDK).
- **py-demo** – Python 3.
- **java-demo** – Java (jdk.httpserver + HttpClient).
- **dotnet-demo** – .NET minimal API.
- **goblog** – Go server.

Each service logs one JSON line per request, e.g. `{"level":"info","msg":"request","service":"tier1","path":"/"}`. OBI enriches it in-place:

```json
{"level":"info","msg":"request","service":"tier1","path":"/","trace_id":"…","span_id":"…"}
```

The OTel agent promotes `trace_id` → `traceId` for Coralogix log–trace linking.

## What you need

- Kubernetes cluster (e.g. EKS); **kernel 6.12+** for OBI log enrichment (6.0+ minimum).
- `kubectl` and `helm` in PATH.
- **CORALOGIX_PRIVATE_KEY** (Coralogix send-your-data key).

## Quick deploy (full redeploy)

```bash
export CORALOGIX_PRIVATE_KEY="your-private-key"
./redeploy-ebpf-demo.sh
```

This script:

1. Deletes the namespace `ebpfdemo` (if present) and recreates it.
2. Creates the `coralogix-keys` secret.
3. Runs `helm upgrade --install` for **coralogix/otel-integration** with **values-ebpf.yaml** (OBI log_enricher, eBPF traces on 4320, log JSON promotion).
4. Applies **ebpf-demo.yaml** (all demo workloads).

Pods may take 1–2 minutes to become Ready (Java/.NET/Go compile on first run). The loader warmup absorbs cold start before the main loop.

## Files

| File / folder | Purpose |
|---------------|---------|
| **ebpf-demo.yaml** | Demo workloads: ConfigMaps, Deployments, Services. |
| **redeploy-ebpf-demo.sh** | Full redeploy script. |
| **otel-integration/values-ebpf.yaml** | Helm values: OBI log_enricher, propagation, eBPF trace pipeline, log transform. |
| **otel-integration/README_ebpf.md** | eBPF-specific OTEL integration notes. |
| **otel-integration/values-ebpfdemo-patch.yaml** | Optional patch when sharing a cluster with another OBI release. |
| **TROUBLESHOOTING_EBPF_PROPAGATION.md** | Propagation verification and troubleshooting. |
| **scripts/investigate-ebpf-propagation.sh** | Check OBI/agent config and pods. |

## Optional env vars (redeploy)

- **DEMO_NAMESPACE** – default `ebpfdemo`.
- **CLUSTER_NAME** – default `coralogixEbpf`; must match `global.clusterName` and OBI cluster name.
- **CORALOGIX_DOMAIN** – default `cx498.coralogix.com`.
- **HELM_VERSION** – chart version; default `0.0.317` (OBI v0.9.0+ required for log enricher).

## After deploy

- Filter traces by service: `ebpf-demo-loader`, `ebpf-demo-tier1`–`tier5`, `py27-demo`, `py-demo`, `java-demo`, `dotnet-demo`, `goblog`.
- Verify log enrichment: `kubectl -n ebpfdemo logs -l app=ebpf-demo-tier1 --tail=20 | grep trace_id`

## Stability notes

- Tier2 has pod affinity to tier1 to help OBI link tier1→tier2 on the same node.
- Dotnet forwards incoming `traceparent`/`tracestate` on outbound requests to avoid trace splits.
- JSON logs must be written **synchronously on the request thread** (see [OBI trace-log correlation](https://opentelemetry.io/docs/zero-code/obi/trace-log-correlation/)).
