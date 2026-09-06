'use strict';

// Phase 0 stub server: canned responses matching spec/openapi.json, routed just well
// enough to walk the three worked transcripts in spec/transcripts/. Not a real
// implementation — no adapters, no query engine. Node + built-ins only, no deps.

const http = require('http');
const fs = require('fs');
const path = require('path');
const F = require('./fixtures');

const PORT = process.env.PORT || 4000;
const OPENAPI_PATH = path.join(__dirname, '..', 'spec', 'openapi.json');

function sendJson(res, status, body) {
  const payload = JSON.stringify(body, null, 2);
  res.writeHead(status, { 'Content-Type': 'application/json' });
  res.end(payload);
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    let chunks = '';
    req.on('data', (c) => (chunks += c));
    req.on('end', () => {
      if (!chunks) return resolve({});
      try {
        resolve(JSON.parse(chunks));
      } catch (e) {
        reject(e);
      }
    });
    req.on('error', reject);
  });
}

function routeQuery(body) {
  const signal = body.signal;
  const mode = body.mode || 'summary';

  if (signal === 'logs') {
    if (mode === 'sample') return F.dbPoolLogsSample;
    // summary: narrow window heuristic vs wide window
    if (typeof body.from === 'string' && /now-(5|10|15|20)m/.test(body.from)) {
      return F.dbPoolLogsSummaryNarrow;
    }
    return F.dbPoolLogsSummaryWide;
  }

  if (signal === 'metrics') {
    return F.gatewayLatMetricsRaw;
  }

  if (signal === 'traces') {
    if (mode === 'sample') return F.gatewayLatTracesSample;
    return F.gatewayLatTracesSummary;
  }

  if (signal === 'errors') {
    if (mode === 'sample') return F.badDeployErrorsSample;
    return F.badDeployErrorsSummary;
  }

  return {
    data: [],
    meta: { sources_queried: body.sources || [], elapsed_ms: 1, truncated: false, total_matched: 0, returned: 0, cursor: null, native_queries: {} },
    errors: [{ source: 'proxy', code: 'invalid_query', message: `unrecognized signal: ${signal}`, retry_after_ms: null }],
  };
}

function routeContext(body) {
  if (body.trace_id === F.TRACE_A) return F.dbPoolContext;
  if (body.trace_id === F.TRACE_B) return F.gatewayLatContext;
  if (body.trace_id === F.TRACE_C) return F.badDeployContext;
  return {
    trace: [],
    logs: [],
    error: null,
    metrics: [],
    meta: { sources_queried: [], elapsed_ms: 5, truncated: false, total_matched: null, returned: null, cursor: null, native_queries: {} },
    errors: [{ source: 'proxy', code: 'invalid_query', message: 'no data for this trace_id in the stub', retry_after_ms: null }],
  };
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, `http://${req.headers.host}`);
  const { pathname } = url;

  try {
    if (req.method === 'GET' && pathname === '/v1/sources') {
      return sendJson(res, 200, F.SOURCES);
    }

    if (req.method === 'GET' && pathname === '/healthz') {
      return sendJson(res, 200, F.HEALTHZ);
    }

    if (req.method === 'GET' && pathname === '/openapi.json') {
      const spec = fs.readFileSync(OPENAPI_PATH, 'utf8');
      res.writeHead(200, { 'Content-Type': 'application/json' });
      return res.end(spec);
    }

    const schemaMatch = pathname.match(/^\/v1\/sources\/([^/]+)\/schema$/);
    if (req.method === 'GET' && schemaMatch) {
      const name = schemaMatch[1];
      const schema = F.SCHEMAS[name];
      if (!schema) return sendJson(res, 404, { error: 'not_found', message: `no such source: ${name}` });
      return sendJson(res, 200, schema);
    }

    if (req.method === 'POST' && pathname === '/v1/query') {
      const body = await readBody(req);
      return sendJson(res, 200, routeQuery(body));
    }

    if (req.method === 'POST' && pathname === '/v1/context') {
      const body = await readBody(req);
      return sendJson(res, 200, routeContext(body));
    }

    return sendJson(res, 404, { error: 'not_found', message: `no route for ${req.method} ${pathname}` });
  } catch (e) {
    return sendJson(res, 400, { error: 'bad_request', message: e.message });
  }
});

server.listen(PORT, '127.0.0.1', () => {
  console.log(`o11y-proxy stub listening on http://127.0.0.1:${PORT}`);
});
