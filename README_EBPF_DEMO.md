# eBPF Demo – Build and Deploy

A minimal multi-service demo that showcases **OpenTelemetry eBPF Instrumentation (OBI)** only: no SDK or app-level trace code. All tracing and propagation are done by eBPF. Services emit **trace-correlation logs** (JSON with `traceId`/`parentId`) for log-to-trace linking in Coralogix.

## Request flow (bitmap random walk)

**Loader** (plain Node) calls **tier1** with header `X-Visited-Bitmap: 0`. Each service then:

1. Sets its own bit in the bitmap (by index: tier1=0, tier2=1, …, goblog=9).
2. If all bits are set, returns `200` with body `done` (trace ends).
3. Otherwise picks a **random unvisited** service and forwards the request with the updated bitmap and W3C `traceparent`/`tracestate`.

So each trace is a **random walk** through the 10 services until every service has been visited once; the last one returns without calling further.

- **Loader** – Node; calls tier1 on an interval with `X-Visited-Bitmap: 0`. Instrumented by OBI; injects trace context.
- **tier1–tier5** – Node forwarders (shared `forwarder.js`), bitmap-aware.
- **py27-demo** – Python 2.7; **py-demo** – Python 3 (with `PYTHONUNBUFFERED` and `flush=True` so trace logs appear).
- **java-demo** – Java (jdk.httpserver + HttpClient).
- **dotnet-demo** – .NET minimal API; forwards `traceparent`/`tracestate` and `X-Visited-Bitmap` on outbound requests.
- **goblog** – Go server.

Each service logs a JSON line when `traceparent` is present: `{"traceId":"...","parentId":"...","service":"...","path":"..."}` so Coralogix can correlate logs with traces.

## What you need

- Kubernetes cluster (e.g. EKS); kernel 5.17+ recommended for eBPF propagation.
- `kubectl` and `helm` in PATH.
- **CORALOGIX_PRIVATE_KEY** (Coralogix send-your-data key for the team that receives traces/logs).

## Quick deploy (full redeploy)

```bash
cd ebpf-demo
export CORALOGIX_PRIVATE_KEY="your-private-key"
./redeploy-ebpf-demo.sh
```

This script:

1. Deletes the namespace `ebpfdemo` (if present) and recreates it.
2. Creates the `coralogix-keys` secret.
3. Runs `helm upgrade --install` for **coralogix/otel-integration** with **values-ebpf.yaml** (agent + OBI + cluster-collector; eBPF traces on 4320; `/health` and OBI/k8s-cache spans filtered out).
4. Applies **ebpf-demo.yaml** (all demo workloads).

**Note:** On some clusters the first Helm install can fail with `metadata.managedFields must be nil`. If that happens, run the same `helm upgrade --install` command from the script manually with `--force-replace` added, then run `kubectl apply -f ebpf-demo.yaml -n ebpfdemo`.

Pods may take 1–2 minutes to become Ready (Java/.NET/Go build on first run). The loader does a warmup (8 chain requests, 15s pause) so cold start is absorbed before the main loop.

## Files in this backup

| File / folder | Purpose |
|---------------|---------|
| **ebpf-demo.yaml** | All demo workloads: ConfigMaps (scripts), Deployments, Services for loader, tier1–5, py27, py, java, dotnet, goblog. |
| **redeploy-ebpf-demo.sh** | Full redeploy: delete namespace, create secret, Helm install, apply ebpf-demo.yaml. |
| **otel-integration/values-ebpf.yaml** | Helm values for Coralogix OTEL (agent, OBI, cluster-collector): eBPF ports 4319/4320, OBI config (propagation, routes, discovery, exclude OBI/k8s-cache), trace filter, logs pipeline. |
| **otel-integration/README_ebpf.md** | Notes on eBPF-specific OTEL integration settings. |
| **TROUBLESHOOTING_EBPF_PROPAGATION.md** | How propagation works, verification steps, loader/tier1 linking, tier2 “processing” time, dotnet trace split, health-check and filter notes. |
| **scripts/investigate-ebpf-propagation.sh** | Script to check OBI/agent config and pods for propagation. |

## Optional env vars (redeploy)

- **DEMO_NAMESPACE** – default `ebpfdemo`.
- **CLUSTER_NAME** – default `coralogixEbpf`; should match `global.clusterName` and OBI’s cluster name so traces group correctly.
- **CORALOGIX_DOMAIN** – default `cx498.coralogix.com`.
- **HELM_VERSION** – chart version; default `0.0.276`.

## After deploy

- In Coralogix, filter traces by service names: `ebpf-demo-loader`, `ebpf-demo-tier1`–`ebpf-demo-tier5`, `py27-demo`, `py-demo`, `java-demo`, `dotnet-demo`, `goblog`.
- Trace-correlation logs (with `traceId`) appear in tier1–5, java, dotnet, goblog, py27, and py-demo for log-to-trace correlation.
- Loader timeout: chain timeout is 180s; if the full round-trip is slower, the loader may log a timeout even though the backend trace is complete. Increasing `chainTimeoutMs` in the loader ConfigMap can reduce that.

## Stability notes

- Full ~40-span traces are most consistent after warmup. Tier2 has a preferred pod affinity to run on the same node as tier1 to help OBI link tier1→tier2.
- Dotnet forwards incoming `traceparent`/`tracestate` on its outbound request so the trace does not split at dotnet.
- Init containers for java-demo and tier4 have a 3-minute timeout so they do not block forever if downstream is slow.
