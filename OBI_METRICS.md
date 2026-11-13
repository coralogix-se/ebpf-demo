# OBI / eBPF metrics reference

Metrics generated when OpenTelemetry eBPF Instrumentation (OBI) is enabled via
the Coralogix `otel-integration` Helm chart.

Sources:
- https://opentelemetry.io/docs/zero-code/obi/metrics/
- Coralogix OBI subchart defaults (`prometheus_export.port: 9090`)

---

## Export paths

| Path | Default | Notes |
|------|---------|-------|
| Prometheus scrape (`prometheus_export`) | off unless metrics Service enabled | values still list `:9090/metrics`; chart strips it when `service.enabled: false` |
| OTLP metrics (`otel_metrics_export`) | `http://${HOST_IP}:4318` | Pushed to Coralogix OTel agent |
| OTLP traces (`otel_traces_export`) | agent eBPF port (e.g. `:4320`) | Used for traces + optional spanmetrics |

`service.enabled` defaults to **false**. The helper `obi.prometheusExportEnabled` only keeps
`prometheus_export` in the ConfigMap when the metrics Service is enabled (or ServiceMonitor
forces it). Leaving Service off is enough to avoid Datadog OpenMetrics scrapes on hostNetwork.

### Validated on kind — OBI `v1.0.0` (Coralogix `otel-integration` `0.0.379` / OBI chart `0.1.30`)

| Scenario | Result |
|----------|--------|
| Default (`service.enabled: false`) | `prometheus_export` **absent**; `:9090` **DOWN** |
| `service.enabled: true` | `:9090/metrics` **UP** |
| Service on + `OTEL_EBPF_PROMETHEUS_PORT: "0"` | Endpoint **DOWN** (connection refused) |

### Older chart behavior (OBI `v0.9.0` / chart `0.1.16`)

Older Coralogix charts opened `:9090` by default even with Service off. Disable options:

| Fix | Result |
|-----|--------|
| Baseline `prometheus_export.port: 9090` | `:9090/metrics` **UP** |
| A. `prometheus_export.port: 0` alone | Helm **fails** (`containerPort: 0` invalid) |
| A′. `prometheus_export.port: 0` + `service.targetPort: 9090` | Endpoint **DOWN** |
| B. `OTEL_EBPF_PROMETHEUS_PORT: "0"` (config still 9090) | Endpoint **DOWN** |

### Recommended values (Coralogix `otel-integration`)

**Latest chart — leave Service off (default):** no scrape listener is rendered.

**Belt-and-suspenders (works on old and new charts):**

```yaml
opentelemetry-ebpf-instrumentation:
  env:
    OTEL_EBPF_PROMETHEUS_PORT: "0"
```

**Config-based on older charts that still emit `prometheus_export`:**

```yaml
opentelemetry-ebpf-instrumentation:
  # Required: chart templates containerPort from prometheus_export.port;
  # port 0 alone makes the DaemonSet invalid.
  service:
    targetPort: 9090
  config:
    data:
      prometheus_export:
        port: 0
        path: /metrics
```

Do **not** set `prometheus_export.port: 0` without `service.targetPort` (or another non-zero
container port override) — the OBI subchart will reject the DaemonSet.

---

## 1. Application metrics

Always relevant for instrumented HTTP / RPC / DB / messaging / GenAI traffic.

| Family | OTel name | Prometheus name | Type | Unit | Description |
|--------|-----------|-----------------|------|------|-------------|
| Application | `http.client.request.duration` | `http_client_request_duration_seconds` | Histogram | seconds | Duration of HTTP calls (client) |
| Application | `http.client.request.body.size` | `http_client_request_body_size_bytes` | Histogram | bytes | HTTP request body size (client) |
| Application | `http.client.response.body.size` | `http_client_response_body_size_bytes` | Histogram | bytes | HTTP response body size (client) |
| Application | `http.server.request.duration` | `http_server_request_duration_seconds` | Histogram | seconds | Duration of HTTP calls (server) |
| Application | `http.server.request.body.size` | `http_server_request_body_size_bytes` | Histogram | bytes | HTTP request body size (server) |
| Application | `http.server.response.body.size` | `http_server_response_body_size_bytes` | Histogram | bytes | HTTP response body size (server) |
| Application | `rpc.client.call.duration` | `rpc_client_call_duration_seconds` | Histogram | seconds | Duration of RPC calls (client) |
| Application | `rpc.server.call.duration` | `rpc_server_call_duration_seconds` | Histogram | seconds | Duration of RPC calls (server) |
| Application | `db.client.operation.duration` | `db_client_operation_duration_seconds` | Histogram | seconds | DB client operation duration (experimental) |
| Application | `db.server.operation.duration` | `db_server_operation_duration_seconds` | Histogram | seconds | Server-side Redis/Memcached/SQL duration (experimental) |
| Application | `messaging.client.operation.duration` | `messaging_client_operation_duration_seconds` | Histogram | seconds | Messaging client ops (Kafka, MQTT, NATS, AMQP) (experimental) |
| Application | `messaging.process.duration` | `messaging_process_duration_seconds` | Histogram | seconds | Messaging process ops (experimental) |
| Application | `gen_ai.client.operation.duration` | `gen_ai_client_operation_duration_seconds` | Histogram | seconds | GenAI client operation duration (experimental) |
| Application | `gen_ai.client.token.usage` | `gen_ai_client_token_usage` | Histogram | 1 | GenAI input/output tokens (experimental) |

### Common high-cardinality attributes (application metrics)

Shown by default (and amplify Datadog custom-metric count when scraped):

- `service.name`, `service.namespace`, `target.instance`
- `http.request.method`, `http.response.status_code`
- `http.route` (when routes config is present)
- Kubernetes (when enabled): `k8s.namespace.name`, `k8s.deployment.name`,
  `k8s.pod.name`, `k8s.node.name`, `k8s.daemonset.name`, `k8s.statefulset.name`,
  `k8s.replicaset.name`, `k8s.owner.name`, `k8s.container.name`, `k8s.cluster.name`, …

RPC metrics also use: `rpc.method`, `rpc.system.name`, `rpc.response.status_code`.

Histograms further multiply series by bucket count.

---

## 2. Go runtime metrics

| OTel name | Prometheus name | Type | Unit |
|-----------|-----------------|------|------|
| `go.memory.limit` | `go_memory_limit_bytes` | Gauge | bytes |
| `go.memory.gc.goal` | `go_memory_gc_goal_bytes` | Gauge | bytes |
| `go.memory.gc.cycles` | `go_memory_gc_cycles_total` | Counter | cycles |
| `go.memory.gc.pause.duration` | `go_memory_gc_pause_duration_seconds` | Histogram | seconds |
| `go.memory.used` | `go_memory_used_bytes` | Gauge | bytes |
| `go.memory.allocated` | `go_memory_allocated_bytes_total` | Counter | bytes |
| `go.memory.allocations` | `go_memory_allocations_total` | Counter | allocations |
| `go.cpu.time` | `go_cpu_time_seconds_total` | Counter | seconds |
| `go.goroutine.count` | `go_goroutine_count` | Gauge | goroutines |
| `go.processor.limit` | `go_processor_limit` | Gauge | threads |
| `go.config.gogc` | `go_config_gogc_percent` | Gauge | percent |
| `go.schedule.duration` | `go_schedule_duration_seconds` | Histogram | seconds |

---

## 3. JVM runtime metrics

| OTel name | Prometheus name | Type | Unit |
|-----------|-----------------|------|------|
| `jvm.memory.used` | `jvm_memory_used_bytes` | Gauge | bytes |
| `jvm.memory.committed` | `jvm_memory_committed_bytes` | Gauge | bytes |
| `jvm.memory.limit` | `jvm_memory_limit_bytes` | Gauge | bytes |
| `jvm.memory.used_after_last_gc` | `jvm_memory_used_after_last_gc_bytes` | Gauge | bytes |

Labeled by `jvm.memory.type` and `jvm.memory.pool.name`.

---

## 4. Node.js runtime metrics

| OTel name | Prometheus name | Type | Unit |
|-----------|-----------------|------|------|
| `nodejs.eventloop.time` | `nodejs_eventloop_time_seconds_total` | Counter | seconds |
| `nodejs.eventloop.utilization` | `nodejs_eventloop_utilization_ratio` | Gauge | 1 |
| `nodejs.eventloop.delay.min` | `nodejs_eventloop_delay_min_seconds` | Gauge | seconds |
| `nodejs.eventloop.delay.max` | `nodejs_eventloop_delay_max_seconds` | Gauge | seconds |
| `nodejs.eventloop.delay.mean` | `nodejs_eventloop_delay_mean_seconds` | Gauge | seconds |
| `nodejs.eventloop.delay.stddev` | `nodejs_eventloop_delay_stddev_seconds` | Gauge | seconds |
| `nodejs.eventloop.delay.p50` | `nodejs_eventloop_delay_p50_seconds` | Gauge | seconds |
| `nodejs.eventloop.delay.p90` | `nodejs_eventloop_delay_p90_seconds` | Gauge | seconds |
| `nodejs.eventloop.delay.p99` | `nodejs_eventloop_delay_p99_seconds` | Gauge | seconds |

`nodejs.eventloop.time` is labeled by `nodejs.eventloop.state` (`idle` / `active`).

---

## 5. Network metrics

Only when network observability is enabled (`network.enable: true` / network preset).
**Off by default** in the Coralogix OBI application preset.

| OTel name | Prometheus name | Type | Unit | Description |
|-----------|-----------------|------|------|-------------|
| `obi.network.flow.bytes` | `obi_network_flow_bytes_total` | Counter | bytes | Bytes between network endpoints |
| `obi.network.flow.packets` | `obi_network_flow_packets_total` | Counter | packets | Packets between network endpoints |
| `obi.network.inter.zone.bytes` | `obi_network_inter_zone_bytes_total` | Counter | bytes | Inter-AZ bytes (K8s, experimental) |
| `obi.stat.tcp.rtt` | `obi_stat_tcp_rtt_seconds` | Histogram | seconds | TCP RTT (StatsO11y) |
| `obi.stat.tcp.failed.connections` | `obi_stat_tcp_failed_connections_total` | Counter | 1 | Failed TCP connects |
| `obi.stat.tcp.retransmits` | `obi_stat_tcp_retransmits_total` | Counter | 1 | TCP retransmits |
| `obi.stat.tcp.io` | `obi_stat_tcp_io_bytes_total` | Counter | bytes | Socket-layer TCP I/O |

---

## 6. OBI internal metrics

Only when an internal metrics Prometheus exporter is configured
(e.g. `internal_metrics.prometheus.port`). **Off by default** in the chart.

| Prometheus name | Type | Description |
|-----------------|------|-------------|
| `obi_ebpf_tracer_flushes` | Histogram | Trace group flush sizes from eBPF |
| `obi_metric_exports_total` | Counter | Metric batches sent to OTel collector |
| `obi_metric_export_errors_total` | CounterVec | Failed metric exports by error type |
| `obi_trace_exports_total` | Counter | Trace batches sent to OTel collector |
| `obi_trace_export_errors_total` | CounterVec | Failed trace exports by error type |
| `obi_prometheus_http_requests_total` | CounterVec | Requests to the Prometheus scrape endpoint |
| `obi_bpf_network_ignored_packets_total` | Counter | Packets dropped by network filters |
| `obi_instrumented_processes` | GaugeVec | Instrumented processes by name |
| `obi_internal_build_info` | GaugeVec | OBI binary version / build info |
| `obi_avoided_services` | GaugeVec | Services skipped because SDK was detected |

Optional BPF probe/map metrics exist behind an opt-in eBPF metrics feature.

---

## 7. Coralogix agent–side metrics (not OBI scrape)

These are produced by the OTel agent / collectors when eBPF traces/metrics flow
through Coralogix pipelines. They typically go to Coralogix over OTLP, not via
OBI `:9090`.

| Source | Examples |
|--------|----------|
| `spanmetrics/ebpf` connector | Call counts, latency histograms, error rates derived from eBPF traces |
| Host metrics preset | Host CPU, memory, disk, network |
| Kubelet metrics preset | Pod/container kubelet stats |
| Collector self-metrics (`:8888`) | `otelcol_*` collector telemetry |

---

## Datadog note

Generic Prometheus / OpenMetrics scrapes in Datadog are billed as **custom metrics**.
On older charts, OBI’s `:9090/metrics` on a **hostNetwork** DaemonSet was a strong
candidate for a sudden custom-metrics spike when eBPF was enabled alongside Datadog.
On current Coralogix charts (`service.enabled: false` by default), the scrape listener
is not rendered unless you explicitly enable the metrics Service.
