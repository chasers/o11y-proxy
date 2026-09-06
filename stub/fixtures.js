'use strict';

// Canned fixtures for the Phase 0 stub server. Three scenarios, each with a distinct
// trace_id, so /v1/context can be routed deterministically from a sampled record.
//
//   A — db-pool     : logs-first (error spike -> sample -> context)
//   B — gateway-lat : metrics-first (latency spike -> traces -> context)
//   C — bad-deploy  : errors-first (Sentry issue spike -> sample -> context)

const TRACE_A = 'a1b2c3d4e5f60708192a3b4c5d6e7f80'; // DB connection pool exhaustion
const TRACE_B = 'b2c3d4e5f60718293a4b5c6d7e8f9001'; // Slow downstream payment gateway
const TRACE_C = 'c3d4e5f6071829304a5b6c7d8e9f0a12'; // Bad deploy introduces nil error

const SOURCES = {
  sources: [
    {
      name: 'app_logs',
      backend: 'clickhouse',
      signal: 'logs',
      capabilities: {
        signals: ['logs'],
        operators: ['eq', 'neq', 'gte', 'lte', 'contains', 'regex', 'in', 'exists'],
        modes: ['summary', 'sample', 'full'],
        raw: true,
        max_window: '7d',
      },
    },
    {
      name: 'otel_traces',
      backend: 'clickhouse',
      signal: 'traces',
      capabilities: {
        signals: ['traces'],
        operators: ['eq', 'neq', 'gte', 'lte', 'contains', 'regex', 'in', 'exists'],
        modes: ['summary', 'sample', 'full'],
        raw: true,
        max_window: '7d',
      },
    },
    {
      name: 'prod_errors',
      backend: 'sentry',
      signal: 'errors',
      capabilities: {
        signals: ['errors'],
        operators: ['eq', 'neq', 'contains', 'in'],
        modes: ['summary', 'sample', 'full'],
        raw: false,
        max_window: '90d',
      },
    },
    {
      name: 'prod_metrics',
      backend: 'victoriametrics',
      signal: 'metrics',
      capabilities: {
        signals: ['metrics'],
        operators: ['eq', 'neq', 'regex'],
        modes: ['summary', 'full'],
        raw: true,
        max_window: 'infinity',
      },
    },
  ],
};

const SCHEMAS = {
  app_logs: {
    name: 'app_logs',
    fields: [
      { canonical: 'timestamp', native: 'Timestamp', type: 'datetime', filterable: true, cardinality: 'high', sample_values: [] },
      { canonical: 'severity', native: 'SeverityText', type: 'string', filterable: true, cardinality: 'low', sample_values: ['info', 'warn', 'error', 'fatal'] },
      { canonical: 'body', native: 'Body', type: 'string', filterable: true, cardinality: 'high', sample_values: [] },
      { canonical: 'service', native: 'ServiceName', type: 'string', filterable: true, cardinality: 'low', sample_values: ['checkout-api', 'web', 'payments-worker'] },
      { canonical: 'trace_id', native: 'TraceId', type: 'string', filterable: true, cardinality: 'high', sample_values: [] },
      { canonical: 'attributes.db_pool', native: "LogAttributes['db_pool']", type: 'string', filterable: true, cardinality: 'low', sample_values: ['payments-db', 'orders-db'] },
    ],
  },
};

const HEALTHZ = {
  sources: {
    app_logs: { status: 'ok' },
    otel_traces: { status: 'ok' },
    prod_errors: { status: 'ok' },
    prod_metrics: { status: 'ok' },
  },
};

// ---- Scenario A: db-pool ---------------------------------------------------------

const dbPoolLogsSummaryWide = {
  data: [
    { bucket: '2026-09-05T19:00:00Z', severity: 'error', service: 'checkout-api', count: 3 },
    { bucket: '2026-09-05T19:15:00Z', severity: 'error', service: 'checkout-api', count: 2 },
    { bucket: '2026-09-05T19:30:00Z', severity: 'error', service: 'checkout-api', count: 4 },
    { bucket: '2026-09-05T19:45:00Z', severity: 'error', service: 'checkout-api', count: 187 },
    { bucket: '2026-09-05T20:00:00Z', severity: 'error', service: 'checkout-api', count: 142 },
  ],
  meta: {
    sources_queried: ['app_logs'],
    elapsed_ms: 84,
    truncated: false,
    total_matched: 338,
    returned: 5,
    cursor: null,
    native_queries: {
      app_logs:
        "SELECT toStartOfInterval(Timestamp, INTERVAL 900 SECOND) AS bucket, SeverityText, ServiceName, count() FROM otel.otel_logs WHERE Timestamp BETWEEN {from:DateTime64} AND {to:DateTime64} AND SeverityText >= {severity:String} AND ServiceName = {service:String} GROUP BY bucket, SeverityText, ServiceName ORDER BY bucket DESC LIMIT 50",
    },
  },
  errors: [],
};

const dbPoolLogsSummaryNarrow = {
  data: [
    { bucket: '2026-09-05T19:45:00Z', severity: 'error', service: 'checkout-api', count: 187 },
    { bucket: '2026-09-05T19:50:00Z', severity: 'error', service: 'checkout-api', count: 94 },
  ],
  meta: {
    sources_queried: ['app_logs'],
    elapsed_ms: 41,
    truncated: false,
    total_matched: 281,
    returned: 2,
    cursor: null,
    native_queries: {
      app_logs:
        "SELECT toStartOfInterval(Timestamp, INTERVAL 300 SECOND) AS bucket, SeverityText, ServiceName, count() FROM otel.otel_logs WHERE Timestamp BETWEEN {from:DateTime64} AND {to:DateTime64} AND SeverityText >= {severity:String} AND ServiceName = {service:String} GROUP BY bucket, SeverityText, ServiceName ORDER BY bucket DESC LIMIT 50",
    },
  },
  errors: [],
};

const dbPoolLogsSample = {
  data: [
    {
      timestamp: '2026-09-05T19:46:12Z',
      severity: 'error',
      body: 'connection pool timeout: could not obtain connection from payments-db pool within 5000ms',
      service: 'checkout-api',
      trace_id: TRACE_A,
      span_id: 'a3b4c5d6e7f80102',
      attributes: { db_pool: 'payments-db', pool_size: 20, pool_in_use: 20 },
      source: 'app_logs',
    },
    {
      timestamp: '2026-09-05T19:47:03Z',
      severity: 'error',
      body: 'connection pool timeout: could not obtain connection from payments-db pool within 5000ms',
      service: 'checkout-api',
      trace_id: 'd4e5f60718293a4b5c6d7e8f9001a2b3',
      span_id: 'b4c5d6e7f8010203',
      attributes: { db_pool: 'payments-db', pool_size: 20, pool_in_use: 20 },
      source: 'app_logs',
    },
  ],
  meta: {
    sources_queried: ['app_logs'],
    elapsed_ms: 63,
    truncated: false,
    total_matched: 281,
    returned: 2,
    cursor: null,
    native_queries: {
      app_logs:
        "SELECT Timestamp, SeverityText, Body, ServiceName, TraceId, SpanId, LogAttributes FROM otel.otel_logs WHERE Timestamp BETWEEN {from:DateTime64} AND {to:DateTime64} AND SeverityText >= {severity:String} AND ServiceName = {service:String} ORDER BY Timestamp DESC LIMIT 50",
    },
  },
  errors: [],
};

const dbPoolContext = {
  trace: [
    {
      timestamp: '2026-09-05T19:46:11Z',
      severity: 'info',
      body: 'POST /checkout',
      service: 'checkout-api',
      trace_id: TRACE_A,
      span_id: 'a3b4c5d6e7f80100',
      attributes: { 'span.kind': 'server', duration_ms: 5012 },
      source: 'otel_traces',
    },
    {
      timestamp: '2026-09-05T19:46:11Z',
      severity: 'info',
      body: 'db.connection.acquire payments-db',
      service: 'checkout-api',
      trace_id: TRACE_A,
      span_id: 'a3b4c5d6e7f80102',
      attributes: { 'span.kind': 'client', duration_ms: 5000, db_pool: 'payments-db' },
      source: 'otel_traces',
    },
  ],
  logs: [
    {
      timestamp: '2026-09-05T19:46:12Z',
      severity: 'error',
      body: 'connection pool timeout: could not obtain connection from payments-db pool within 5000ms',
      service: 'checkout-api',
      trace_id: TRACE_A,
      span_id: 'a3b4c5d6e7f80102',
      attributes: { db_pool: 'payments-db', pool_size: 20, pool_in_use: 20 },
      source: 'app_logs',
    },
  ],
  error: {
    issue_id: '4521099',
    title: 'PoolTimeoutError: payments-db',
    culprit: 'Checkout.process/2',
    level: 'error',
    count: 331,
    first_seen: '2026-09-05T19:44:50Z',
    last_seen: '2026-09-05T20:01:30Z',
    permalink: 'https://sentry.io/organizations/my-org/issues/4521099/',
  },
  metrics: [
    {
      name: 'db_pool_in_use',
      labels: { service: 'checkout-api', pool: 'payments-db' },
      points: [
        [1757100600000, 12],
        [1757101200000, 18],
        [1757101800000, 20],
        [1757102400000, 20],
      ],
    },
  ],
  meta: {
    sources_queried: ['otel_traces', 'app_logs', 'prod_errors', 'prod_metrics'],
    elapsed_ms: 212,
    truncated: false,
    total_matched: null,
    returned: null,
    cursor: null,
    native_queries: {
      otel_traces: `SELECT * FROM otel.otel_traces WHERE TraceId = {trace_id:String} ORDER BY Timestamp ASC LIMIT 50`,
      app_logs: `SELECT * FROM otel.otel_logs WHERE TraceId = {trace_id:String} ORDER BY Timestamp ASC LIMIT 50`,
      prod_errors: `GET /api/0/organizations/my-org/events/?field=trace&query=trace:${TRACE_A}`,
      prod_metrics: `GET /api/v1/query_range?query=db_pool_in_use{service="checkout-api"}&start=...&end=...`,
    },
  },
  errors: [],
};

// ---- Scenario B: gateway-lat ------------------------------------------------------

const gatewayLatMetricsRaw = {
  data: [
    {
      name: 'http_request_duration_seconds:p99',
      labels: { service: 'checkout-api', route: '/checkout' },
      points: [
        [1757095200000, 0.31],
        [1757098800000, 0.34],
        [1757102400000, 2.87],
        [1757106000000, 3.12],
      ],
    },
  ],
  meta: {
    sources_queried: ['prod_metrics'],
    elapsed_ms: 58,
    truncated: false,
    total_matched: null,
    returned: 1,
    cursor: null,
    native_queries: {
      prod_metrics:
        'GET /api/v1/query_range?query=histogram_quantile(0.99,+rate(http_request_duration_seconds_bucket{service%3D"checkout-api"}[5m]))&start=...&end=...&step=1h',
    },
  },
  errors: [],
};

const gatewayLatTracesSummary = {
  data: [
    { bucket: '2026-09-05T18:00:00Z', service: 'checkout-api', count: 4 },
    { bucket: '2026-09-05T19:00:00Z', service: 'checkout-api', count: 6 },
    { bucket: '2026-09-05T20:00:00Z', service: 'checkout-api', count: 211 },
  ],
  meta: {
    sources_queried: ['otel_traces'],
    elapsed_ms: 77,
    truncated: false,
    total_matched: 221,
    returned: 3,
    cursor: null,
    native_queries: {
      otel_traces:
        "SELECT toStartOfInterval(Timestamp, INTERVAL 3600 SECOND) AS bucket, ServiceName, count() FROM otel.otel_traces WHERE Timestamp BETWEEN {from:DateTime64} AND {to:DateTime64} AND ServiceName = {service:String} AND SpanAttributes['duration_ms'] >= {duration_ms:Float64} GROUP BY bucket, ServiceName ORDER BY bucket DESC LIMIT 50",
    },
  },
  errors: [],
};

const gatewayLatTracesSample = {
  data: [
    {
      timestamp: '2026-09-05T20:03:41Z',
      severity: 'info',
      body: 'POST /checkout',
      service: 'checkout-api',
      trace_id: TRACE_B,
      span_id: 'b2c3d4e5f6070000',
      attributes: { duration_ms: 3120, 'span.kind': 'server' },
      source: 'otel_traces',
    },
  ],
  meta: {
    sources_queried: ['otel_traces'],
    elapsed_ms: 51,
    truncated: false,
    total_matched: 221,
    returned: 1,
    cursor: null,
    native_queries: {
      otel_traces:
        "SELECT * FROM otel.otel_traces WHERE Timestamp BETWEEN {from:DateTime64} AND {to:DateTime64} AND ServiceName = {service:String} AND SpanAttributes['duration_ms'] >= {duration_ms:Float64} ORDER BY Timestamp DESC LIMIT 20",
    },
  },
  errors: [],
};

const gatewayLatContext = {
  trace: [
    {
      timestamp: '2026-09-05T20:03:41Z',
      severity: 'info',
      body: 'POST /checkout',
      service: 'checkout-api',
      trace_id: TRACE_B,
      span_id: 'b2c3d4e5f6070000',
      attributes: { duration_ms: 3120, 'span.kind': 'server' },
      source: 'otel_traces',
    },
    {
      timestamp: '2026-09-05T20:03:41Z',
      severity: 'info',
      body: 'POST https://api.payment-gateway.example/v1/charges',
      service: 'checkout-api',
      trace_id: TRACE_B,
      span_id: 'b2c3d4e5f6070001',
      attributes: { duration_ms: 3081, 'span.kind': 'client', 'peer.service': 'payment-gateway' },
      source: 'otel_traces',
    },
  ],
  logs: [
    {
      timestamp: '2026-09-05T20:03:44Z',
      severity: 'warn',
      body: 'payment-gateway responded in 3081ms (p99 budget 500ms)',
      service: 'checkout-api',
      trace_id: TRACE_B,
      span_id: 'b2c3d4e5f6070001',
      attributes: { 'peer.service': 'payment-gateway' },
      source: 'app_logs',
    },
  ],
  error: null,
  metrics: [
    {
      name: 'http_request_duration_seconds:p99',
      labels: { service: 'checkout-api', route: '/checkout' },
      points: [
        [1757102400000, 2.87],
        [1757106000000, 3.12],
      ],
    },
  ],
  meta: {
    sources_queried: ['otel_traces', 'app_logs', 'prod_errors', 'prod_metrics'],
    elapsed_ms: 198,
    truncated: false,
    total_matched: null,
    returned: null,
    cursor: null,
    native_queries: {
      otel_traces: `SELECT * FROM otel.otel_traces WHERE TraceId = {trace_id:String} ORDER BY Timestamp ASC LIMIT 50`,
      app_logs: `SELECT * FROM otel.otel_logs WHERE TraceId = {trace_id:String} ORDER BY Timestamp ASC LIMIT 50`,
      prod_errors: `GET /api/0/organizations/my-org/events/?field=trace&query=trace:${TRACE_B}`,
      prod_metrics: `GET /api/v1/query_range?query=http_request_duration_seconds:p99{service="checkout-api"}&start=...&end=...`,
    },
  },
  errors: [
    { source: 'prod_errors', code: 'invalid_query', message: 'no matching issue for this trace_id', retry_after_ms: null },
  ],
};

// ---- Scenario C: bad-deploy ---------------------------------------------------------

const badDeployErrorsSummary = {
  data: [
    { bucket: '2026-09-05T16:00:00Z', severity: 'error', service: 'checkout-api', count: 1 },
    { bucket: '2026-09-05T17:00:00Z', severity: 'error', service: 'checkout-api', count: 2 },
    { bucket: '2026-09-05T18:00:00Z', severity: 'error', service: 'checkout-api', count: 164 },
    { bucket: '2026-09-05T19:00:00Z', severity: 'error', service: 'checkout-api', count: 201 },
  ],
  meta: {
    sources_queried: ['prod_errors'],
    elapsed_ms: 302,
    truncated: false,
    total_matched: 368,
    returned: 4,
    cursor: null,
    native_queries: {
      prod_errors:
        'GET /api/0/projects/my-org/my-project/issues/?query=is:unresolved+level:error&statsPeriod=6h',
    },
  },
  errors: [],
};

const badDeployErrorsSample = {
  data: [
    {
      timestamp: '2026-09-05T18:02:14Z',
      severity: 'error',
      body: "KeyError: key :discount_pct not found in %{code: \"WELCOME10\"}",
      service: 'checkout-api',
      trace_id: TRACE_C,
      span_id: null,
      attributes: { issue_id: '4521310', release: 'checkout-api@2026.09.05-3', culprit: 'Checkout.Pricing.apply_discount/2' },
      source: 'prod_errors',
    },
  ],
  meta: {
    sources_queried: ['prod_errors'],
    elapsed_ms: 288,
    truncated: false,
    total_matched: 368,
    returned: 1,
    cursor: null,
    native_queries: {
      prod_errors:
        'GET /api/0/issues/4521310/events/latest/',
    },
  },
  errors: [],
};

const badDeployContext = {
  trace: [
    {
      timestamp: '2026-09-05T18:02:13Z',
      severity: 'info',
      body: 'POST /checkout',
      service: 'checkout-api',
      trace_id: TRACE_C,
      span_id: 'c3d4e5f607180000',
      attributes: { 'span.kind': 'server', duration_ms: 42 },
      source: 'otel_traces',
    },
  ],
  logs: [
    {
      timestamp: '2026-09-05T18:02:14Z',
      severity: 'error',
      body: "KeyError: key :discount_pct not found in %{code: \"WELCOME10\"}",
      service: 'checkout-api',
      trace_id: TRACE_C,
      span_id: 'c3d4e5f607180000',
      attributes: { release: 'checkout-api@2026.09.05-3' },
      source: 'app_logs',
    },
  ],
  error: {
    issue_id: '4521310',
    title: "KeyError: key :discount_pct not found in %{code: \"WELCOME10\"}",
    culprit: 'Checkout.Pricing.apply_discount/2',
    level: 'error',
    count: 368,
    first_seen: '2026-09-05T18:00:55Z',
    last_seen: '2026-09-05T20:04:00Z',
    permalink: 'https://sentry.io/organizations/my-org/issues/4521310/',
  },
  metrics: [
    {
      name: 'http_requests_errors_total',
      labels: { service: 'checkout-api', route: '/checkout' },
      points: [
        [1757095200000, 1],
        [1757098800000, 164],
        [1757102400000, 201],
      ],
    },
  ],
  meta: {
    sources_queried: ['otel_traces', 'app_logs', 'prod_errors', 'prod_metrics'],
    elapsed_ms: 231,
    truncated: false,
    total_matched: null,
    returned: null,
    cursor: null,
    native_queries: {
      otel_traces: `SELECT * FROM otel.otel_traces WHERE TraceId = {trace_id:String} ORDER BY Timestamp ASC LIMIT 50`,
      app_logs: `SELECT * FROM otel.otel_logs WHERE TraceId = {trace_id:String} ORDER BY Timestamp ASC LIMIT 50`,
      prod_errors: `GET /api/0/issues/4521310/`,
      prod_metrics: `GET /api/v1/query_range?query=http_requests_errors_total{service="checkout-api"}&start=...&end=...`,
    },
  },
  errors: [],
};

module.exports = {
  TRACE_A,
  TRACE_B,
  TRACE_C,
  SOURCES,
  SCHEMAS,
  HEALTHZ,
  dbPoolLogsSummaryWide,
  dbPoolLogsSummaryNarrow,
  dbPoolLogsSample,
  dbPoolContext,
  gatewayLatMetricsRaw,
  gatewayLatTracesSummary,
  gatewayLatTracesSample,
  gatewayLatContext,
  badDeployErrorsSummary,
  badDeployErrorsSample,
  badDeployContext,
};
