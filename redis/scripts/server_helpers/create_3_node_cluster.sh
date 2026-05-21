#!/bin/bash

REDIS_DIR=~/redis-7.2.10
START_PORT=7000
END_PORT=7031          # 160 per server; use 7031 if you want 32

HOSTS=(
  220.0.0.101
  220.0.0.103
  220.0.0.104
)

echo "Creating Redis cluster..."

ARGS=""
for host in "${HOSTS[@]}"; do
  for port in $(seq $START_PORT $END_PORT); do
    ARGS="$ARGS $host:$port"
  done
done

yes yes | "$REDIS_DIR/src/redis-cli" --cluster create $ARGS --cluster-replicas 0

echo
echo "Cluster info:"
"$REDIS_DIR/src/redis-cli" -c -h 220.0.0.101 -p 7000 cluster info
