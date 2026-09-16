# Querying CloudWatch Logs from S3

CloudWatch Logs Insights is fine until you want the logs from six weeks ago, or want them
in the same query as your ClickHouse traces. This sets up a one-way street — log group →
S3 — and points the `s3` backend at the result, so old log groups answer the same
`o11y-proxy query` as everything else.

The route is **log group → subscription filter → Amazon Data Firehose → S3**. Firehose
decompresses the CloudWatch payload for you, so no Lambda is involved.

> **Verification status.** The `o11y.yaml` and the SQL below are exercised on every run of
> `test/o11y_proxy/backends/s3_minio_test.exs` against MinIO, using the record shape from
> AWS's [message extraction
> docs](https://docs.aws.amazon.com/firehose/latest/dev/Message_extraction.html) (read
> 2026-09-16). The `aws` commands themselves are written from documentation and have
> **not** been run against a live account — expect to correct an argument name or two, and
> please send the fix.

---

## 1. A bucket

```sh
export BUCKET=acme-logs-archive
export REGION=us-east-1

aws s3api create-bucket --bucket "$BUCKET" --region "$REGION"
```

## 2. A role Firehose can use to write to it

```sh
cat > /tmp/firehose-trust.json <<'JSON'
{"Version":"2012-10-17","Statement":[{"Effect":"Allow",
 "Principal":{"Service":"firehose.amazonaws.com"},"Action":"sts:AssumeRole"}]}
JSON

aws iam create-role --role-name o11y-firehose-to-s3 \
  --assume-role-policy-document file:///tmp/firehose-trust.json

cat > /tmp/firehose-policy.json <<JSON
{"Version":"2012-10-17","Statement":[{"Effect":"Allow",
 "Action":["s3:AbortMultipartUpload","s3:GetBucketLocation","s3:GetObject",
           "s3:ListBucket","s3:ListBucketMultipartUploads","s3:PutObject"],
 "Resource":["arn:aws:s3:::$BUCKET","arn:aws:s3:::$BUCKET/*"]}]}
JSON

aws iam put-role-policy --role-name o11y-firehose-to-s3 \
  --policy-name write-archive --policy-document file:///tmp/firehose-policy.json
```

## 3. The delivery stream

Two things here matter more than the rest.

**The prefix is Hive-style.** `dt=.../hour=...` is what lets DuckDB skip objects instead of
reading the bucket. Without it every query for "the last hour" pays to scan every log line
you have ever archived. This is the single most important line in the file.

**Decompression is on, message extraction is off.** Extraction would throw away `logGroup`,
`logStream` and `owner` — which are your service name and your attributes.

```sh
export ROLE_ARN=$(aws iam get-role --role-name o11y-firehose-to-s3 \
  --query 'Role.Arn' --output text)

aws firehose create-delivery-stream \
  --delivery-stream-name o11y-logs-archive \
  --delivery-stream-type DirectPut \
  --extended-s3-destination-configuration "{
    \"RoleARN\": \"$ROLE_ARN\",
    \"BucketARN\": \"arn:aws:s3:::$BUCKET\",
    \"Prefix\": \"cw/dt=!{timestamp:yyyy-MM-dd}/hour=!{timestamp:HH}/\",
    \"ErrorOutputPrefix\": \"cw-errors/!{firehose:error-output-type}/\",
    \"CompressionFormat\": \"GZIP\",
    \"BufferingHints\": {\"SizeInMBs\": 64, \"IntervalInSeconds\": 60},
    \"ProcessingConfiguration\": {
      \"Enabled\": true,
      \"Processors\": [
        {\"Type\": \"Decompression\",
         \"Parameters\": [{\"ParameterName\": \"CompressionFormat\",
                          \"ParameterValue\": \"GZIP\"}]},
        {\"Type\": \"AppendDelimiterToRecord\",
         \"Parameters\": [{\"ParameterName\": \"Delimiter\",
                          \"ParameterValue\": \"\\\\n\"}]}
      ]
    }
  }"
```

`AppendDelimiterToRecord` is what makes the objects genuinely newline-delimited. Without
it records can run together and `read_json`'s `newline_delimited` format sees one
malformed line.

## 4. A role CloudWatch Logs can use to reach Firehose, and the subscription

```sh
cat > /tmp/cwl-trust.json <<JSON
{"Version":"2012-10-17","Statement":[{"Effect":"Allow",
 "Principal":{"Service":"logs.$REGION.amazonaws.com"},"Action":"sts:AssumeRole"}]}
JSON

aws iam create-role --role-name o11y-cwl-to-firehose \
  --assume-role-policy-document file:///tmp/cwl-trust.json

aws iam put-role-policy --role-name o11y-cwl-to-firehose \
  --policy-name put-records --policy-document "{
    \"Version\": \"2012-10-17\",
    \"Statement\": [{\"Effect\": \"Allow\",
      \"Action\": [\"firehose:PutRecord\", \"firehose:PutRecordBatch\"],
      \"Resource\": \"$(aws firehose describe-delivery-stream \
        --delivery-stream-name o11y-logs-archive \
        --query 'DeliveryStreamDescription.DeliveryStreamARN' --output text)\"}]}"

aws logs put-subscription-filter \
  --log-group-name /aws/lambda/checkout-api \
  --filter-name to-s3 \
  --filter-pattern "" \
  --destination-arn "$(aws firehose describe-delivery-stream \
     --delivery-stream-name o11y-logs-archive \
     --query 'DeliveryStreamDescription.DeliveryStreamARN' --output text)" \
  --role-arn "$(aws iam get-role --role-name o11y-cwl-to-firehose \
     --query 'Role.Arn' --output text)"
```

An empty `--filter-pattern` means every event. Repeat the last command per log group.

## 5. Wait for the buffer, then look

Firehose flushes on 64MB or 60 seconds, whichever comes first.

```sh
aws s3 ls "s3://$BUCKET/cw/" --recursive | head
```

You should see `cw/dt=2026-09-16/hour=14/o11y-logs-archive-1-...gz`.

---

## 6. Point o11y-proxy at it

Copy [`o11y.yaml`](o11y.yaml) next to your own config, or paste its `sources:` entry in.
Then:

```sh
o11y-proxy sources
o11y-proxy schema cw_logs

o11y-proxy query --signal logs --from -24h --mode summary
o11y-proxy query --signal logs --from -24h --mode full --limit 20 \
  --filter 'body~connection refused'
```

`--mode summary` first is not a style preference: it returns ~50 bucketed rows instead of
raw log lines, which is both cheaper to scan and far more useful for finding *when* a
thing started.

## What the records look like, and what the config does about it

Firehose writes one JSON object per record, with the events nested in a `logEvents` array:

```json
{
  "owner": "111111111111",
  "logGroup": "/aws/lambda/checkout-api",
  "logStream": "2026/09/16/[$LATEST]7d4f",
  "messageType": "DATA_MESSAGE",
  "logEvents": [
    {"id": "3195310660...", "timestamp": 1789580641000,
     "message": "2026-09-16T17:00:00Z\treq-0b1c\tERROR\tpayments-db connection refused"}
  ]
}
```

That is not a log table, so the source declares a `transform`: a SELECT over the raw scan
(exposed as `scan`) that produces the flat columns `mapping` then names. `UNNEST(logEvents)`
turns one object into one row per event, and the `logGroup`/`logStream`/`owner` metadata
rides along as `service` and attributes.

**The severity column is a text heuristic and you should replace it.** CloudWatch messages
are free-form; the `CASE` in `o11y.yaml` greps for `ERROR`/`WARN`/`FATAL`, which works for
Lambda's tab-delimited default and for most log libraries, and quietly calls everything
else `info`. If your application logs structured JSON, the honest version is:

```sql
lower(coalesce(json_extract_string(e.message, '$.level'), 'info')) AS level
```

## Cost

Three things, in rough order of how much they will surprise you:

1. **Firehose ingestion**, per GB, forever, on everything the subscription matches. Use
   `--filter-pattern` to subscribe to less if a log group is chatty.
2. **S3 GET requests** from queries. This is what `hints.hive_date_column` is for — with
   it, a one-hour query opens the objects under one `dt=` prefix; without it, all of them.
   Check `meta.native_queries` in any response: the `WHERE CAST("dt" AS DATE) BETWEEN`
   clause should be inside the `scan` CTE.
3. **S3 storage.** A lifecycle rule to Glacier after 90 days is the usual answer, but note
   that DuckDB cannot read an object in Glacier without a restore, so the source stops
   answering for that range.

## Making it faster: convert to Parquet

Gzipped JSON is what Firehose gives you cheaply; Parquet is what you want to query
repeatedly. Once a day is old enough to be complete, rewrite it — column pruning and
predicate pushdown then do far more work than partition pruning alone:

```sql
COPY (
  SELECT to_timestamp(e.timestamp / 1000) AS ts, logGroup AS service, e.message AS message
  FROM read_json('s3://acme-logs-archive/cw/dt=2026-09-16/**/*.gz',
                 format = 'newline_delimited', union_by_name = true),
       UNNEST(logEvents) AS u(e)
) TO 's3://acme-logs-archive/parquet/dt=2026-09-16/' (FORMAT parquet);
```

Run that with the `duckdb` CLI, not through o11y-proxy — the proxy is read-only on purpose
and rejects `COPY`. Then add a second source with `format: parquet` over
`s3://acme-logs-archive/parquet/**/*.parquet`, and give the two different `name`s so a
query can pick.
