#!/bin/bash

REDIS_DIR=~/redis-7.2.10
PORT=7000

ANNOUNCE_IP="220.0.0.101"

BASE_DIR=~/redis-cluster-test
NODE_DIR=$BASE_DIR/$PORT

echo "Starting Redis node on $ANNOUNCE_IP:$PORT"

mkdir -p $NODE_DIR

echo "Stopping any Redis on port $PORT..."
pid=$(lsof -t -i:$PORT 2>/dev/null)
if [ ! -z "$pid" ]; then
  kill $pid
  sleep 1
fi

echo "Cleaning old cluster files..."
rm -f $NODE_DIR/nodes.conf
rm -f $NODE_DIR/dump.rdb
rm -f $NODE_DIR/appendonly.aof

echo "Starting Redis..."

$REDIS_DIR/src/redis-server \
  --port $PORT \
  --bind 0.0.0.0 \
  --protected-mode no \
  --dir $NODE_DIR \
  --cluster-enabled yes \
  --cluster-config-file nodes.conf \
  --cluster-node-timeout 5000 \
  --cluster-announce-ip $ANNOUNCE_IP \
  --cluster-announce-port $PORT \
  --cluster-announce-bus-port $((PORT+10000)) \
  --appendonly no \
  --save "" \
  --maxclients 200000 \
  --daemonize yes

sleep 1

echo "Redis started:"
$REDIS_DIR/src/redis-cli -p $PORT ping
