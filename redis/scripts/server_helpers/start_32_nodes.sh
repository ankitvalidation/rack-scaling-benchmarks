#!/bin/bash

REDIS_DIR=~/redis-7.2.10
START_PORT=7000
END_PORT=7031

# CHANGE THIS PER MACHINE
ANNOUNCE_IP="220.0.0.101"

BASE_DIR=~/redis-cluster-32

echo "Starting 32 Redis nodes on $ANNOUNCE_IP"

mkdir -p $BASE_DIR

echo "Stopping any existing Redis servers..."
pkill redis-server
sleep 2

echo "Cleaning old cluster files..."
rm -rf $BASE_DIR
mkdir -p $BASE_DIR

echo "Starting Redis nodes..."
for port in $(seq $START_PORT $END_PORT); do
  NODE_DIR=$BASE_DIR/$port
  mkdir -p $NODE_DIR

  $REDIS_DIR/src/redis-server \
    --port $port \
    --bind 0.0.0.0 \
    --protected-mode no \
    --dir $NODE_DIR \
    --cluster-enabled yes \
    --cluster-config-file nodes.conf \
    --cluster-node-timeout 5000 \
    --cluster-announce-ip $ANNOUNCE_IP \
    --cluster-announce-port $port \
    --cluster-announce-bus-port $((port+10000)) \
    --appendonly no \
    --save "" \
    --maxclients 200000 \
    --daemonize yes
done

sleep 3

echo "Sanity check:"
for port in $(seq $START_PORT $END_PORT); do
  $REDIS_DIR/src/redis-cli -p $port ping || echo "Port $port failed"
done
