# Effective Menu Read Benchmark

## Purpose

Measure the PostgreSQL-backed customer menu read path before introducing Redis.

## Test environment

The benchmark runs against the Docker Compose Effective Menu Service on port `8081`.
Redis is disabled for this baseline.

## Dataset

The integration fixture uses outlet `1` with a persisted effective-menu snapshot. The
initial connectivity run used one item; the larger run used 50 visible active items.

## Endpoint

```text
GET http://localhost:8081/api/v1/outlets/1/menu
```

## Load tool

```powershell
./scripts/effective-menu-baseline.ps1 -Requests 300
```

The script records successful responses, failures, average latency, and P50/P95/P99
latency for timed HTTP requests.

For concurrent load, use k6 from Docker:

```powershell
docker run --rm -i --add-host=host.docker.internal:host-gateway `
  -v "${PWD}/load-tests:/scripts" `
  grafana/k6 run /scripts/effective-menu-k6.js
```

The k6 stages increase traffic from 10 to 100 concurrent virtual users and validate
both the HTTP status and the presence of the effective-menu response.

For the manual million-request endurance run:

```powershell
docker run --rm -i --add-host=host.docker.internal:host-gateway `
  -v "${PWD}/load-tests:/scripts" `
  -v "${PWD}:/results" `
  grafana/k6 run --summary-export=/results/k6-million-summary.json `
  /scripts/effective-menu-million.js
```

This run is intentionally excluded from Maven and CI because it is a long-running
capacity test.

## Baseline results

| Metric | Result |
|---|---:|
| Requests | 1,000 |
| Concurrency | 1 (sequential compatibility baseline) |
| Successful requests | 1,000 |
| Failed requests | 0 |
| Average latency | 2.75 ms |
| P50 latency | 2.40 ms |
| P95 latency | 4.47 ms |
| P99 latency | 8.64 ms |

### Concurrent k6 run

| Metric | Result |
|---|---:|
| Peak virtual users | 99 (configured maximum 100) |
| Duration | 15 seconds |
| Requests | 28,731 |
| Failed requests | 0 |
| Requests per second | 1,915 |
| Average latency | 19.33 ms |
| P50 latency | 17.85 ms |
| P95 latency | 35.90 ms |
| P99 latency | not emitted by the console summary; threshold passed below 500 ms |
| Maximum latency | 122.25 ms |

### Concurrent k6 run after pool tuning

The Effective Menu service was rebuilt with Hikari maximum pool size `30` and minimum
idle connections `10` (the previous default maximum was `10`). The same short k6
scenario was then repeated.

| Metric | Result |
|---|---:|
| Peak virtual users | 99 (configured maximum 100) |
| Duration | 15 seconds |
| Requests | 18,767 |
| HTTP failures | 1 EOF during graceful shutdown |
| Requests per second | 467 |
| Average latency | 34.58 ms |
| P50 latency | 26.11 ms |
| P95 latency | 78.66 ms |
| P99 latency | 121.30 ms |

The larger pool did not improve this run: throughput was lower and one connection closed
during graceful shutdown. The service stayed healthy, and the latency thresholds still
passed. This points to a limit outside the database connection pool (for example request
threading, Docker networking, or the load generator), so we should not claim that pool
size alone solves the million-request endurance problem.

### Compression experiment

HTTP gzip compression reduced the response transfer size, but increased CPU work and
latency in this local setup. With compression enabled the same test reached 12,667
requests (about 845 requests/second), with 49.5 ms average latency and 124.58 ms P95.
Compression is therefore kept as an explicit opt-in setting rather than enabled by
default for this baseline.

### Payload-size comparison

To isolate response size, the same k6 test was run with outlet `1` temporarily reduced
to one visible item. The 50-item snapshot was restored immediately afterwards.

| Metric | One item |
|---|---:|
| Requests | 35,992 |
| Requests per second | 2,399 |
| Average latency | 17.02 ms |
| P95 latency | 38.50 ms |
| P99 latency | 58.13 ms |
| Failed requests | 0 |

The one-item response was about 1 KB and sustained substantially more traffic than the
larger 5.4 KB response. This confirms response payload size and network transfer are a
major part of the sustained-load limit. The database query itself is not the primary
bottleneck in this test.

### Redis-enabled comparison

With Redis running and the outlet snapshot already cached, the same k6 scenario completed
44,318 requests (about 1,003 requests/second). Average latency was 14.03 ms, P95 was
29.13 ms, and P99 was 41.74 ms. Three requests timed out during graceful shutdown. Redis
reduced normal request latency, but throughput remained limited by response payload size
and local Docker/network capacity.

## Observations

The 50-item snapshot completed 1,000 sequential requests without failures. The concurrent
k6 run reached 99 virtual users and 1,915 requests per second with no failures. The k6
thresholds passed: P95 below 250 ms and P99 below 500 ms.

The separate million-request endurance run was intentionally stopped after approximately
205,000 requests when the 100-virtual-user load began producing connection timeouts. This
means the current Docker/embedded deployment is healthy for the measured 100-user burst,
but it is not yet proven to sustain a million requests continuously. Redis or further
connection-pool/server tuning must be evaluated against this observed limit.

We also tested the million-request scenario with 60 virtual users. It reached approximately
125,000 completed iterations in 63 seconds before repeated connection timeouts appeared,
so it was stopped safely. Lowering the user count alone does not solve the sustained-load
limit; the next investigation should inspect server request threads, database pool limits,
and response/connection behavior before comparing Redis.

## Decision

Redis will be considered only after a larger dataset and concurrent load are measured,
then compared with a repeatable cache-enabled run.
