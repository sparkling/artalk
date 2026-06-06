#!/bin/bash
# AWS (ECS Fargate) entrypoint: Litestream-supervised Artalk (single writer).
#
# The task disk is ephemeral (ADR-0038 in sparkling/opda): restore the SQLite
# DB from S3 if a replica exists, then run Artalk under
# `litestream replicate -exec` so the WAL streams to S3 continuously and the
# process pair lives and dies together. Exactly one task runs at a time (the
# ECS service enforces stop-old-then-start-new), so there is never a second
# writer.
#
# Credentials/region come from the Fargate task role + AWS_REGION (standard
# SDK chain — nothing configured here).
set -e

: "${LITESTREAM_BUCKET:?LITESTREAM_BUCKET is required (the opda-comments stack sets it)}"

DB_PATH="${ATK_DB_FILE:-/data/artalk.db}"
mkdir -p /data "$(dirname "$DB_PATH")"

# Default config on the ephemeral disk (regenerated every boot); all real
# settings arrive as ATK_* environment variables from the task definition.
if [ ! -e /data/artalk.yml ]; then
    artalk-go gen conf /data/artalk.yml
    echo "$(date) [info][docker-aws] Generated config at /data/artalk.yml (env vars override)"
fi

cat > /etc/litestream.yml <<EOF
dbs:
  - path: ${DB_PATH}
    replicas:
      - type: s3
        bucket: ${LITESTREAM_BUCKET}
        path: artalk
        region: ${AWS_REGION:-eu-west-2}
EOF

litestream restore -if-db-not-exists -if-replica-exists "$DB_PATH"
echo "$(date) [info][docker-aws] Litestream restore done; starting Artalk under replication"

exec litestream replicate -exec "artalk-go server --config /data/artalk.yml --host 0.0.0.0 --port 23366"
