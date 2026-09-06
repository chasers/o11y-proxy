#!/usr/bin/env bash
# Pushes a handful of http_requests_total samples for checkout-api, spread across the
# last few minutes, via VictoriaMetrics' Prometheus-exposition import endpoint — so the
# VictoriaMetrics BackendCase test (test/o11y_proxy/backends/victoria_metrics_test.exs,
# `mix test --include victoriametrics`) finds them inside its +/-1h window. Requires
# `docker compose up -d` first (see docker-compose.yml).
set -euo pipefail

VM_URL="${VM_URL:-http://localhost:8428}"
now_ms=$(date +%s%3N)

{
  for i in $(seq 0 11); do
    ts=$(( now_ms - i * 30000 ))
    value=$(( 1000 + i * 7 ))
    echo "http_requests_total{service=\"checkout-api\",route=\"/checkout\"} ${value} ${ts}"
  done
} | curl -sf "$VM_URL/api/v1/import/prometheus" --data-binary @-

echo "Seeded http_requests_total{service=\"checkout-api\"} at $VM_URL"
