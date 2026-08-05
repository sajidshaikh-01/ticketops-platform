# Distributed Observability in TicketOps

## 1. Introduction

TicketOps is a cloud-native event ticket booking platform built as a
collection of independently deployable microservices running on Kubernetes.
The platform manages event discovery, seat reservation, booking
confirmation, and asynchronous notification processing, following GitOps
deployment practices on Amazon EKS.

TicketOps is composed of three backend services — `events-api`, `admin-api`,
and `bookings-worker` — running on Amazon EKS (`ticketops-dev`,
`us-east-1`). Communication between services is a mix of synchronous HTTP
calls and asynchronous Redis-backed job queues. This document describes the
observability layer built on top of that platform: what problem it solves,
how it's architected, how it was implemented, and how it was validated.

It's written as an engineering design document rather than a setup guide.
The goal is to capture not just the final configuration, but the reasoning
behind each decision, the specific problem each layer of the stack solves,
and the evidence that it actually works — so it can stand on its own for
anyone (including a future version of me) trying to understand *why* the
system looks the way it does.

By the end of Phase 7, TicketOps has three pillars of observability:

- **Metrics** — kube-prometheus-stack, scraping application and cluster
  metrics via ServiceMonitors, visualized in Grafana.
- **Logs** — Loki (S3 backend, IRSA) with Fluent Bit as the log shipper,
  aggregating structured JSON logs from every pod.
- **Traces** — Grafana Tempo (S3 backend, IRSA) fed by an OpenTelemetry
  Collector, providing distributed request tracing across service and
  transport boundaries.

This document focuses on the third pillar — tracing — since it was the most
architecturally involved: it required not just instrumenting each service,
but manually propagating trace context across a boundary (Redis) that has no
built-in concept of a trace.

Unlike a traditional monolithic application, where a request is processed
start to finish within a single process, TicketOps intentionally separates
synchronous request handling (`events-api`) from asynchronous booking
confirmation (`bookings-worker`) using Redis as a queue. This architectural
decision significantly improves responsiveness — the client gets a booking
confirmation without waiting on notification dispatch — but it also
introduces a challenge for request visibility: the work for a single
booking now spans two processes with no shared execution context. That
challenge is what the rest of this document addresses.

## 2. What is Observability?

Observability is the ability to answer questions about a system's internal
state *without having predicted the question in advance*. That's the
distinction that matters in practice: monitoring tells you whether a known
failure mode has happened (CPU is high, error rate spiked, a health check is
failing); observability lets you investigate a failure mode you didn't
anticipate, by exploring the data rather than checking a pre-built
dashboard.

The three pillars — metrics, logs, and traces — each answer a different
class of question:

| Pillar  | Answers                                          | Example question |
|---------|---------------------------------------------------|-------------------|
| Metrics | "How much / how often / how fast, over time?"     | Is p99 booking latency degrading? |
| Logs    | "What happened, in detail, at this point in time?" | What was the exact error when booking `TKT-420673` failed? |
| Traces  | "How did a single request move through the system, and where did the time go?" | Why did this booking take 4 seconds — which service, which hop, was slow? |

None of the three substitutes for the others. Metrics tell you *that*
something is wrong; logs tell you *what* happened in one place; traces tell
you *where in a multi-service journey* it happened. TicketOps needed all
three, but traces were the missing piece for a specific reason covered next.

## 3. Why Logs Alone Were Not Enough

Before this phase, TicketOps already had structured JSON logging in every
service (see the `booking created`, `booking job completed`, etc. log lines
throughout `bookings.service.ts` and `bookings-processor.service.ts`) and
those logs were centralized in Loki. For a single-service bug, that's
usually enough — grep the logs, find the error, done.

The booking flow, however, is not single-service. A single booking request
crosses three independent execution contexts:

```
Browser
   │  HTTP POST /api/bookings
   ▼
events-api          (synchronous — creates the booking, holds seat locks,
   │                  writes to Postgres, then LPUSHes a job)
   ▼
Redis Queue          (bookings:queue — a plain list, no tracing concept)
   │
   ▼
bookings-worker      (asynchronous — BRPOPs the job, sends the
                       confirmation notification, marks it complete)
```

Each of those three hops logs independently, with its own timestamps and no
shared identifier connecting them. Given a slow or failed booking, the
logs alone could tell us *that* `events-api` created booking `TKT-420673` at
09:34:00.083Z, and separately *that* `bookings-worker` completed a job with
the same booking reference at 09:34:01.101Z — but confirming those two log
lines were the *same request*, and seeing exactly how much of that ~1
second gap was Redis queueing versus worker processing versus notification
dispatch, meant manually correlating timestamps and booking references by
eye. That falls apart fast under real load, with many concurrent bookings
interleaving in the log stream.

This is precisely the gap distributed tracing closes: a single trace ID
that follows the request across all three hops, with each hop contributing
timed spans to the same waterfall.

**Before — three independent log streams:**

```
Browser
   │
events-api ──────► logs (events-api pod)
   │
Redis Queue
   │
bookings-worker ─► logs (bookings-worker pod)

No shared identifier.
Correlation across services done manually, by timestamp and booking
reference.
```

**After — one trace, one journey:**

```
Browser
   │
events-api
   │  inject(traceContext)
   ▼
Redis Queue
   │  extract(traceContext)
   ▼
bookings-worker
   │
   ▼
OTel Collector ──► Tempo ──► Grafana

Single Trace ID.
Complete request journey, one waterfall, queryable in Grafana.
```

The remainder of this document explains how distributed tracing was
designed, implemented, validated, and integrated into the existing
observability stack.

### Design Goals

The observability implementation for TicketOps was designed around the
following goals:

- End-to-end visibility across synchronous and asynchronous workflows.
- Vendor-neutral instrumentation using OpenTelemetry.
- Minimal changes to application business logic.
- GitOps-managed deployment through ArgoCD.
- Horizontally scalable collection architecture.

## 4. Architecture Overview

The tracing stack sits alongside the existing metrics and logging
infrastructure in the `monitoring` namespace, deployed via ArgoCD as two
separate applications (`tracing-dev` for Tempo, `otel-collector-dev` for the
Collector), following the same App-of-Apps GitOps pattern as the rest of
the observability stack.

At the simplest level, the pipeline looks like this:

```
Client
   │
Ingress
   │
events-api
   │
Redis
   │
bookings-worker
   │
   ▼
OpenTelemetry SDK
   │
   ▼
OTel Collector
   │
   ▼
Tempo
   │
   ▼
Grafana
```

The detailed view below shows how that maps onto actual Kubernetes
namespaces, services, and ports.

```
                    ticketops-dev namespace
   ┌─────────────────────────────────────────────────┐
   │  events-api      admin-api      bookings-worker  │
   │  (2 replicas)    (1 replica)    (1 replica)      │
   │       │               │               │          │
   │       │ OTLP/gRPC     │ OTLP/gRPC     │ OTLP/gRPC │
   │       └───────────────┴───────────────┘          │
   └───────────────────────┬───────────────────────────┘
                            │ :4317
                            ▼
                    monitoring namespace
              ┌──────────────────────────┐
              │   otel-collector          │
              │   (receivers → processors │
              │    → exporters)           │
              └────────────┬──────────────┘
                            │ OTLP/gRPC :4317
                            ▼
              ┌──────────────────────────┐
              │   Tempo (tracing-dev)     │
              │   backend: S3             │
              │   (ticketops-dev-tempo-   │
              │    traces bucket)         │
              └────────────┬──────────────┘
                            │
                            ▼
              ┌──────────────────────────┐
              │        Grafana            │
              │  TraceQL queries,         │
              │  trace waterfall UI       │
              └──────────────────────────┘
```

Each of the three instrumented services runs its own embedded OpenTelemetry
SDK and exports spans directly to the Collector over OTLP/gRPC. OTLP (the
OpenTelemetry Protocol) is the vendor-neutral wire protocol that
OpenTelemetry SDKs and Collectors use to exchange telemetry — it's what
makes the SDK, Collector, and Tempo interoperable without any
backend-specific glue. There's no sidecar involved. The Collector is a
single centralized deployment
(`fullnameOverride: otel-collector`, 1 replica, pinned to
`workload: monitoring` nodes) that receives from all three services, batches
and forwards to Tempo. Tempo persists trace data to S3
(`ticketops-dev-tempo-traces`) via an IRSA-scoped service account
(`ticketops-dev-tempo-role`), with a 24-hour retention window. Grafana reads
from Tempo as a datasource, which is what makes TraceQL querying and the
waterfall view possible.

This mirrors the shape of the logging pipeline (Fluent Bit → Loki → S3 →
Grafana) and the metrics pipeline (ServiceMonitors → Prometheus → Grafana):
one collection layer, one durable backend, one pane of glass in Grafana for
all three signal types.

## 5. Why OpenTelemetry?

A few options exist for instrumenting distributed tracing: vendor-specific
SDKs (e.g. Datadog APM, New Relic), or an open, vendor-neutral standard.
OpenTelemetry (OTel) was the natural fit for TicketOps for a few concrete
reasons:

- **Vendor neutrality.** OTel is a CNCF project, and the wire protocol
  (OTLP) is backend-agnostic. TicketOps happens to export to Tempo, but
  nothing in the application code is Tempo-specific — the same
  instrumentation would work unchanged against Jaeger, Honeycomb, or any
  other OTLP-compatible backend. That decoupling matters for a platform
  that's meant to demonstrate portable, non-proprietary infrastructure
  choices.
- **Auto-instrumentation for Node.js.** `@opentelemetry/auto-instrumentations-node`
  automatically instruments common libraries (HTTP, Express/NestJS,
  Prisma/pg, ioredis, etc.) without hand-writing spans for every operation.
  For a NestJS monorepo with three services, this meant getting HTTP-level
  and database-level spans essentially for free, and reserving manual
  instrumentation for the one place it was actually needed: the Redis queue
  boundary (Section 11).
- **A real specification for cross-process propagation.** The problem
  described in Section 3 — connecting a span in `events-api` to a span in
  `bookings-worker` across a Redis message with no native tracing
  concept — needed a standard, interoperable way to serialize and
  deserialize trace context. OTel's `propagation.inject()` /
  `propagation.extract()` API, built on the W3C Trace Context spec, is
  exactly that (details in Sections 11–12).
- **Already OTLP-native downstream.** Tempo and the OTel Collector both
  speak OTLP natively, so there was no protocol translation layer to
  maintain.

## 6. OpenTelemetry Components

Three OTel building blocks are in play, and it's worth being precise about
what each one does, since they're easy to conflate:

**SDK (`@opentelemetry/sdk-node`)** — runs inside each Node.js process
(`events-api`, `admin-api`, `bookings-worker`). It's the thing that actually
creates spans, manages the active trace context, and exports finished spans
over OTLP. Each service has its own `tracing.ts` that configures and starts
the SDK, e.g. events-api's:

```typescript
const sdk = new NodeSDK({
  resource: resourceFromAttributes({
    [ATTR_SERVICE_NAME]: 'events-api',
    [ATTR_SERVICE_VERSION]: process.env.npm_package_version || '0.0.1',
  }),
  traceExporter: new OTLPTraceExporter({
    url:
      process.env.OTEL_EXPORTER_OTLP_ENDPOINT ||
      'http://otel-collector.monitoring.svc.cluster.local:4317',
  }),
  instrumentations: [getNodeAutoInstrumentations()],
});

sdk.start();
```

`admin-api` and `bookings-worker` use the identical pattern, differing only
in `ATTR_SERVICE_NAME`. This file is loaded via Node's `-r` preload flag
before the application entrypoint, so instrumentation is active before any
application code (including the HTTP server and Prisma client) initializes —
this is what lets auto-instrumentation patch those libraries transparently:

```dockerfile
CMD ["node", "-r", "./apps/events-api/dist/tracing.js", "apps/events-api/dist/main.js"]
```

None of the three services override `OTEL_EXPORTER_OTLP_ENDPOINT` via Helm
values — they all fall back to the in-cluster default,
`http://otel-collector.monitoring.svc.cluster.local:4317`, resolved through
Kubernetes DNS across the `ticketops-dev` → `monitoring` namespace
boundary.

**Collector (`otel-collector`)** — a standalone deployment that sits between
the instrumented services and Tempo. It is not required for tracing to
function — services could export directly to Tempo — but introducing a
Collector creates a stable abstraction layer that allows processors,
routing, sampling, batching, and backend changes without modifying
application code, which is why nearly every production OpenTelemetry
deployment includes one. Concretely, it centralizes a few concerns that
would otherwise be duplicated three times:

```yaml
service:
  pipelines:
    traces:
      receivers:  [otlp, jaeger, zipkin]
      processors: [memory_limiter, batch]
      exporters:  [otlp, debug]
```

- `receivers` accept OTLP (and, for future flexibility, Jaeger/Zipkin
  formats) from any service.
- `memory_limiter` protects the Collector itself from unbounded memory
  growth if Tempo is slow or unreachable.
- `batch` groups spans before export, reducing the number of network calls
  to Tempo.
- `exporters` forward to Tempo over OTLP (`tracing-dev-tempo.monitoring.svc.cluster.local:4317`,
  insecure/plaintext inside the cluster) and, for local debugging, to
  `debug` (stdout).

**Backend (Tempo)** — the durable store and query engine. Tempo receives
batched spans from the Collector and persists them to S3
(`ticketops-dev-tempo-traces`), and exposes a TraceQL query API that Grafana
uses to render the waterfall view and run ad hoc trace searches (Section
14 covers actual TraceQL usage).

Together: **SDK creates and exports spans → Collector receives, batches,
and forwards → Tempo stores and serves queries → Grafana visualizes.** Each
layer has exactly one job, which keeps the pipeline easy to reason about
when something isn't showing up as expected.

At this point, every service in TicketOps is capable of producing traces.
The remaining challenge was ensuring that a trace created in one service
could continue across an asynchronous Redis queue into another service.
The next section explains how that architecture was implemented.

---

*Continued in Part 3: Tempo Architecture, OpenTelemetry Collector, End-to-End Trace Flow.*