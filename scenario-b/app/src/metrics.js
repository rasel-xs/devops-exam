// Prometheus instrumentation. All six metrics the brief asks for, in one place.
//
// The single most important rule in this file is the `route` label: it is
// always the route PATTERN (`/api/notes/:id`), never the requested path
// (`/api/notes/48213`). Prometheus creates one time series per unique label
// combination, so labelling with the real path would create a series per note
// id -- 50,000 series from one endpoint, each with its own histogram buckets.
// That is "high cardinality", and it kills Prometheus far faster than traffic
// does. Same reasoning is why `tenant` is safe (5 values, bounded, and it is
// the dimension we actually want to slice by) and why user id would not be.
const client = require('prom-client');

const register = new client.Registry();
register.setDefaultLabels({ app: 'notes-api' });

// Node process/GC/heap metrics for free -- process_start_time_seconds from this
// is what catches a crash-looping container.
client.collectDefaultMetrics({ register });

const httpRequestsTotal = new client.Counter({
  name: 'http_requests_total',
  help: 'Total HTTP requests',
  labelNames: ['route', 'method', 'status', 'tenant'],
  registers: [register],
});

const httpRequestDuration = new client.Histogram({
  name: 'http_request_duration_seconds',
  help: 'HTTP request latency',
  labelNames: ['route', 'method', 'tenant'],
  // Buckets straddle the range that matters here: sub-10ms for /healthz, and
  // out to a full minute for the unbounded ?limit=5000 case. p95 is only as
  // accurate as the bucket it lands in, so there is deliberate resolution
  // around 50-500ms where the real endpoints live.
  //
  // 15/30/60 were added after B3 task 32. The original top bucket was 10s, and
  // panels A and H reported a p95 of exactly `10` for /api/notes and for the
  // acme tenant. That is not a measurement: when the quantile falls in the
  // +Inf bucket, histogram_quantile returns the highest FINITE boundary. The
  // dashboard was quietly reporting 10s for requests that actually ran past
  // 30s until curl gave up on them -- understating the worst case, which is
  // the one number a latency panel exists to show. A histogram can only ever
  // report what its buckets can express.
  buckets: [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10, 15, 30, 60],
  registers: [register],
});

const dbQueryDuration = new client.Histogram({
  name: 'db_query_duration_seconds',
  help: 'Database query latency by logical query name',
  labelNames: ['query_name'],
  buckets: [0.0005, 0.001, 0.0025, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5],
  registers: [register],
});

// THE N+1 DETECTOR. GET /api/notes?limit=20 will sit at 21 while every other
// route sits at 1 or 2. The 21 bucket boundary exists specifically so that
// shape is legible on a heatmap instead of being smeared across 10..50.
const dbQueriesPerRequest = new client.Histogram({
  name: 'db_queries_per_request',
  help: 'Number of DB queries issued while serving one HTTP request',
  labelNames: ['route'],
  buckets: [1, 2, 3, 5, 8, 13, 21, 34, 55, 100, 250, 1000],
  registers: [register],
});

// Catches the unbounded ?limit=50000.
const dbRowsReturned = new client.Histogram({
  name: 'db_rows_returned',
  help: 'Rows returned by a single query',
  labelNames: ['query_name'],
  buckets: [1, 5, 10, 20, 50, 100, 500, 1000, 5000, 20000, 50000],
  registers: [register],
});

// Saturation. A gauge, not a counter: it goes down as well as up.
const httpRequestsInFlight = new client.Gauge({
  name: 'http_requests_in_flight',
  help: 'HTTP requests currently being served',
  registers: [register],
});

module.exports = {
  client,
  register,
  httpRequestsTotal,
  httpRequestDuration,
  dbQueryDuration,
  dbQueriesPerRequest,
  dbRowsReturned,
  httpRequestsInFlight,
};
