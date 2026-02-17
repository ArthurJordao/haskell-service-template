# Changelog for `haskell-service-lib`

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to the
[Haskell Package Versioning Policy](https://pvp.haskell.org/).

## Unreleased

### Added
- Modular observability system with **automatic** metrics collection
  - **`Service.Metrics.Core`** - Base metric types (Counter, Gauge, Histogram)
  - **`Service.Metrics.Http`** - HTTP metrics: request counts, duration histograms, active requests
    - `metricsMiddleware` for automatic HTTP instrumentation
    - Automatic path normalization to reduce cardinality
  - **`Service.Metrics.Kafka`** - Kafka metrics: messages consumed, processing duration, DLQ messages
    - **Automatic instrumentation** - no manual wrapping needed!
    - Metrics collected transparently in `consumerLoop`
  - **`Service.Metrics.Database`** - Database metrics: query duration, connection pool stats, query errors
    - **Automatic instrumentation** - no manual wrapping needed!
    - Metrics collected transparently in `runSqlPoolWithCid`
  - **`Service.Metrics.Optional`** - Optional type classes with no-op defaults
    - Services work with or without metrics
    - Overlapping instances provide real metrics when available
  - **`Service.Metrics`** - Combined container that re-exports all modules
  - Prometheus-compatible text format export via `/metrics` endpoint
  - Thread-safe in-memory metrics using STM
  - Documentation in OBSERVABILITY.md

## 0.1.0.0 - YYYY-MM-DD
