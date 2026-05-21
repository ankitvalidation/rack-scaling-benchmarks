#!/bin/bash

REDIS_DIR=~/redis-7.2.10

echo "Creating Redis cluster..."

yes yes | $REDIS_DIR/src/redis-cli --cluster create \
220.0.0.101:7000 \
220.0.0.103:7000 \
220.0.0.104:7000 \
--cluster-replicas 0

echo
echo "Cluster info:"
$REDIS_DIR/src/redis-cli -c -h 220.0.0.101 -p 7000 cluster info
