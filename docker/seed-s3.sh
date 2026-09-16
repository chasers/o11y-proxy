#!/usr/bin/env bash
# Writes gzipped, newline-delimited CloudWatch-via-Firehose records into MinIO, under the
# Hive-style prefix a Firehose delivery stream produces
# (`cw/dt=YYYY-MM-DD/hour=HH/`) — so the S3 BackendCase test
# (test/o11y_proxy/backends/s3_minio_test.exs, `mix test --include s3_minio`) finds them
# inside its +/-1h window, and so the SQL in examples/cloudwatch-s3/README.md is the same
# SQL the local harness proves.
#
# Record shape is AWS's, verified against
# https://docs.aws.amazon.com/firehose/latest/dev/Message_extraction.html (2026-09-16):
# decompression on, message extraction *off*, so logGroup/logStream/owner survive and the
# events sit in a nested `logEvents` array.
#
# Requires `docker compose up -d` first (see docker-compose.yml) and the `mc` client.
set -euo pipefail

S3_ENDPOINT="${S3_ENDPOINT:-http://localhost:9010}"
S3_BUCKET="${S3_BUCKET:-o11y-logs}"
S3_KEY="${S3_KEY:-o11yproxy}"
S3_SECRET="${S3_SECRET:-o11yproxy}"

command -v mc >/dev/null || {
  echo "mc (MinIO client) not found: https://min.io/docs/minio/linux/reference/minio-mc.html" >&2
  exit 1
}

mc alias set o11y "$S3_ENDPOINT" "$S3_KEY" "$S3_SECRET" >/dev/null
mc mb --ignore-existing "o11y/$S3_BUCKET" >/dev/null

now_s=$(date -u +%s)
dt=$(date -u -d "@${now_s}" +%Y-%m-%d)
hour=$(date -u -d "@${now_s}" +%H)
workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT

# Two records, five events, spread over the last few minutes. `message` is Lambda's
# tab-delimited shape, which is what the example's severity heuristic keys off.
{
  cat <<JSON
{"owner":"111111111111","logGroup":"/aws/lambda/checkout-api","logStream":"2026/09/16/[\$LATEST]7d4f","subscriptionFilters":["to-s3"],"messageType":"DATA_MESSAGE","logEvents":[{"id":"31953106606966983378809025079804211143289615424298221560","timestamp":$(( (now_s - 120) * 1000 )),"message":"$(date -u -d "@$(( now_s - 120 ))" +%Y-%m-%dT%H:%M:%SZ)\treq-0b1c\tERROR\tpayments-db connection refused after 3 retries"},{"id":"31953106606966983378809025079804211143289615424298221561","timestamp":$(( (now_s - 115) * 1000 )),"message":"$(date -u -d "@$(( now_s - 115 ))" +%Y-%m-%dT%H:%M:%SZ)\treq-0b1c\tWARN\tpayments-db pool at 95% capacity"},{"id":"31953106606966983378809025079804211143289615424298221562","timestamp":$(( (now_s - 90) * 1000 )),"message":"$(date -u -d "@$(( now_s - 90 ))" +%Y-%m-%dT%H:%M:%SZ)\treq-0b1c\tINFO\tcheckout completed order=88213"}]}
{"owner":"111111111111","logGroup":"/aws/lambda/payments-api","logStream":"2026/09/16/[\$LATEST]3c1e","subscriptionFilters":["to-s3"],"messageType":"DATA_MESSAGE","logEvents":[{"id":"31953106606966983378809025079804211143289615424298221563","timestamp":$(( (now_s - 60) * 1000 )),"message":"$(date -u -d "@$(( now_s - 60 ))" +%Y-%m-%dT%H:%M:%SZ)\treq-9f22\tERROR\tpayments-db connection refused after 3 retries"},{"id":"31953106606966983378809025079804211143289615424298221564","timestamp":$(( (now_s - 30) * 1000 )),"message":"$(date -u -d "@$(( now_s - 30 ))" +%Y-%m-%dT%H:%M:%SZ)\treq-9f22\tINFO\tsettlement batch 4471 written"}]}
JSON
} | gzip > "$workdir/o11y-1-$(date -u -d "@${now_s}" +%Y-%m-%d-%H-%M-%S)-seed.gz"

mc cp "$workdir"/*.gz "o11y/$S3_BUCKET/cw/dt=$dt/hour=$hour/" >/dev/null

echo "Seeded s3://$S3_BUCKET/cw/dt=$dt/hour=$hour/ at $S3_ENDPOINT"
