#!/bin/bash
#===============================================================================
# Redis Cluster Horizontal Scaling Benchmark v9
#
# TRUE horizontal scaling: Redis Cluster mode with data sharding.
# Tests 1 instance per node, scaling the number of nodes.
#
# Architecture:
#   Client: Node 101 (single client sufficient — 1 inst/node ≈ 2M ops, won't bottleneck)
#   Servers: 103, 104, 107, 102, 101 (up to 5 nodes in cluster)
#
# Redis Cluster requires minimum 3 master nodes.
# Test points:
#   - Standalone baseline: 1 node × 1 instance (no cluster)
#   - Cluster: 3 nodes × 1 instance (minimum cluster)
#   - Cluster: 4 nodes × 1 instance
#   - Cluster: 5 nodes × 1 instance
#
# memtier uses --cluster-mode to handle MOVED/ASK redirects transparently.
#===============================================================================
set +e

MEMTIER="/usr/local/bin/memtier_benchmark"
REDIS_CLI="/usr/local/bin/redis-cli"

# Server nodes in order of addition
ALL_SERVERS=(200.0.0.103 200.0.0.104 200.0.0.107 200.0.0.102 200.0.0.101)
ALL_SERVERS_220=(220.0.0.103 220.0.0.104 220.0.0.107 220.0.0.102 220.0.0.101)

CLIENT_LOCAL="200.0.0.101"
# For high-node-count tests, use node 102 as 2nd client when it's not a server
# For 3-node test: 102 available as client
# For 4-5 node tests: 102 is a server, use only local client

PORT=7000

# Parameters — match v8 for comparison
PIPELINE=20
DATA_SIZE=256
RATIO="1:1"
TEST_TIME=60

RESULTS_DIR="/root/redis-scaling-test/results_v9_cluster"
mkdir -p "$RESULTS_DIR"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
REPORT="${RESULTS_DIR}/report_${TIMESTAMP}.txt"

#===============================================================================
stop_all() {
    for node in "${ALL_SERVERS[@]}"; do
        ssh "$node" 'pkill -9 redis-server 2>/dev/null; rm -rf /tmp/redis-cluster' 2>/dev/null &
    done
    pkill -9 redis-server 2>/dev/null
    pkill -9 memtier 2>/dev/null
    rm -rf /tmp/redis-cluster 2>/dev/null
    wait; sleep 1
}

start_instance() {
    local NODE=$1
    ssh "$NODE" "
        rm -rf /tmp/redis-cluster; mkdir -p /tmp/redis-cluster/${PORT}
        redis-server --port ${PORT} --bind 0.0.0.0 --protected-mode no \
            --dir /tmp/redis-cluster/${PORT} \
            --cluster-enabled yes --cluster-config-file nodes.conf \
            --cluster-node-timeout 5000 \
            --appendonly no --save '' --maxclients 200000 \
            --tcp-backlog 65535 --hz 100 --daemonize yes 2>/dev/null
        sleep 0.5
        echo \"\$(pgrep -c redis-server) redis on \$(hostname -s)\"
    " 2>&1 | grep "redis on"
}

create_cluster() {
    local NODES=("$@")
    local CLUSTER_NODES=""
    for node in "${NODES[@]}"; do
        CLUSTER_NODES="$CLUSTER_NODES ${node}:${PORT}"
    done
    
    echo "  Creating cluster with:${CLUSTER_NODES}"
    $REDIS_CLI --cluster create $CLUSTER_NODES --cluster-replicas 0 --cluster-yes 2>&1 | tail -5
    
    # Wait for cluster to stabilize
    sleep 3
    
    # Verify cluster is OK
    local STATUS=$($REDIS_CLI -h "${NODES[0]}" -p $PORT cluster info 2>/dev/null | grep cluster_state)
    echo "  Cluster state: $STATUS"
}

add_node_to_cluster() {
    local NEW_NODE=$1
    local EXISTING_NODE=$2
    
    echo "  Adding ${NEW_NODE}:${PORT} to cluster..."
    $REDIS_CLI --cluster add-node "${NEW_NODE}:${PORT}" "${EXISTING_NODE}:${PORT}" 2>&1 | tail -3
    sleep 2
    
    # Rebalance slots
    echo "  Rebalancing slots..."
    $REDIS_CLI --cluster rebalance "${EXISTING_NODE}:${PORT}" --cluster-use-empty-masters 2>&1 | tail -5
    sleep 3
    
    local STATUS=$($REDIS_CLI -h "${EXISTING_NODE}" -p $PORT cluster info 2>/dev/null | grep cluster_state)
    echo "  Cluster state: $STATUS"
}

run_cluster_test() {
    local LABEL=$1
    local TARGET_NODE=$2  # Any node in cluster — memtier discovers topology
    local NUM_CLIENTS=$3  # How many client machines
    
    # Use dual-NIC, multiple procs to maximize throughput
    # For cluster mode: each memtier discovers all nodes automatically
    local PROCS_PER_NIC=3
    local THREADS=16
    local CLIENTS=25
    
    local PIDS=()
    local P=0
    
    # Client 1 (local) — NIC1
    for j in $(seq 1 $PROCS_PER_NIC); do
        P=$((P+1))
        $MEMTIER --server="$TARGET_NODE" --port="$PORT" --protocol=redis --cluster-mode \
            --threads="$THREADS" --clients="$CLIENTS" --pipeline="$PIPELINE" \
            --data-size="$DATA_SIZE" --ratio="$RATIO" --test-time="$TEST_TIME" \
            --key-minimum=1 --key-maximum=10000000 --key-pattern=R:R \
            --hide-histogram > "${RESULTS_DIR}/${LABEL}_c1n1_p${P}_${TIMESTAMP}.txt" 2>/dev/null &
        PIDS+=($!)
    done
    
    # Client 1 (local) — NIC2 (use 220.0.0.x address of target)
    local TARGET_IDX=-1
    for i in "${!ALL_SERVERS[@]}"; do
        if [[ "${ALL_SERVERS[$i]}" == "$TARGET_NODE" ]]; then
            TARGET_IDX=$i
            break
        fi
    done
    local TARGET_220="${ALL_SERVERS_220[$TARGET_IDX]}"
    
    for j in $(seq 1 $PROCS_PER_NIC); do
        P=$((P+1))
        $MEMTIER --server="$TARGET_220" --port="$PORT" --protocol=redis --cluster-mode \
            --threads="$THREADS" --clients="$CLIENTS" --pipeline="$PIPELINE" \
            --data-size="$DATA_SIZE" --ratio="$RATIO" --test-time="$TEST_TIME" \
            --key-minimum=1 --key-maximum=10000000 --key-pattern=R:R \
            --hide-histogram > "${RESULTS_DIR}/${LABEL}_c1n2_p${P}_${TIMESTAMP}.txt" 2>/dev/null &
        PIDS+=($!)
    done
    
    # Client 2 (node 102) — only if available (not in server pool for this test)
    if [[ "$NUM_CLIENTS" -ge 2 ]]; then
        for j in $(seq 1 $PROCS_PER_NIC); do
            P=$((P+1))
            ssh 200.0.0.102 "
                memtier_benchmark --server=$TARGET_NODE --port=$PORT --protocol=redis --cluster-mode \
                    --threads=$THREADS --clients=$CLIENTS --pipeline=$PIPELINE \
                    --data-size=$DATA_SIZE --ratio=$RATIO --test-time=$TEST_TIME \
                    --key-minimum=1 --key-maximum=10000000 --key-pattern=R:R \
                    --hide-histogram 2>/dev/null
            " > "${RESULTS_DIR}/${LABEL}_c2n1_p${P}_${TIMESTAMP}.txt" 2>/dev/null &
            PIDS+=($!)
        done
        for j in $(seq 1 $PROCS_PER_NIC); do
            P=$((P+1))
            ssh 200.0.0.102 "
                memtier_benchmark --server=$TARGET_220 --port=$PORT --protocol=redis --cluster-mode \
                    --threads=$THREADS --clients=$CLIENTS --pipeline=$PIPELINE \
                    --data-size=$DATA_SIZE --ratio=$RATIO --test-time=$TEST_TIME \
                    --key-minimum=1 --key-maximum=10000000 --key-pattern=R:R \
                    --hide-histogram 2>/dev/null
            " > "${RESULTS_DIR}/${LABEL}_c2n2_p${P}_${TIMESTAMP}.txt" 2>/dev/null &
            PIDS+=($!)
        done
    fi
    
    local TOTAL_PROCS=${#PIDS[@]}
    local TOTAL_CONNS=$((TOTAL_PROCS * THREADS * CLIENTS))
    echo "  Procs: ${TOTAL_PROCS} | Connections: ${TOTAL_CONNS}"
    echo "  Waiting for ${TOTAL_PROCS} memtier processes (${TEST_TIME}s + overhead)..."
    
    for pid in "${PIDS[@]}"; do wait "$pid" 2>/dev/null || true; done
    
    # Aggregate results
    local TOTAL_OPS=0 TOTAL_P99=0 COUNT=0
    for f in "${RESULTS_DIR}/${LABEL}_c"*"_${TIMESTAMP}.txt"; do
        local OPS=$(grep "^Totals" "$f" 2>/dev/null | awk '{print $2}')
        local P99=$(grep "^Totals" "$f" 2>/dev/null | awk '{print $7}')
        if [[ -n "$OPS" && "$OPS" != "0.00" ]]; then
            TOTAL_OPS=$(echo "$TOTAL_OPS + $OPS" | bc)
            TOTAL_P99=$(echo "$TOTAL_P99 + $P99" | bc 2>/dev/null || echo "$TOTAL_P99")
            COUNT=$((COUNT+1))
        fi
    done
    
    if [[ $COUNT -gt 0 ]]; then
        local AVG_P99=$(echo "scale=2; $TOTAL_P99 / $COUNT" | bc)
        local OPS_INT=$(printf "%.0f" "$TOTAL_OPS")
        echo "  >>> ${OPS_INT} ops/sec | p99: ${AVG_P99} ms  [${COUNT} procs]"
        echo "${LABEL} | ${OPS_INT} ops/sec | p99: ${AVG_P99} ms | ${COUNT}/${TOTAL_PROCS} procs | ${TOTAL_CONNS} conns" >> "$REPORT"
    else
        echo "  >>> ERROR: no valid results"
        echo "${LABEL} | ERROR" >> "$REPORT"
    fi
}

run_standalone_test() {
    local LABEL=$1
    local SERVER=$2
    
    local PROCS=6
    local THREADS=16
    local CLIENTS=25
    local PIDS=()
    
    # Use both NICs for the standalone test too
    local TARGET_IDX=-1
    for i in "${!ALL_SERVERS[@]}"; do
        if [[ "${ALL_SERVERS[$i]}" == "$SERVER" ]]; then
            TARGET_IDX=$i; break
        fi
    done
    local SERVER_220="${ALL_SERVERS_220[$TARGET_IDX]}"
    
    for j in $(seq 1 3); do
        $MEMTIER --server="$SERVER" --port="$PORT" --protocol=redis \
            --threads="$THREADS" --clients="$CLIENTS" --pipeline="$PIPELINE" \
            --data-size="$DATA_SIZE" --ratio="$RATIO" --test-time="$TEST_TIME" \
            --key-minimum=1 --key-maximum=10000000 --key-pattern=R:R \
            --hide-histogram > "${RESULTS_DIR}/${LABEL}_n1_p${j}_${TIMESTAMP}.txt" 2>/dev/null &
        PIDS+=($!)
    done
    for j in $(seq 4 6); do
        $MEMTIER --server="$SERVER_220" --port="$PORT" --protocol=redis \
            --threads="$THREADS" --clients="$CLIENTS" --pipeline="$PIPELINE" \
            --data-size="$DATA_SIZE" --ratio="$RATIO" --test-time="$TEST_TIME" \
            --key-minimum=1 --key-maximum=10000000 --key-pattern=R:R \
            --hide-histogram > "${RESULTS_DIR}/${LABEL}_n2_p${j}_${TIMESTAMP}.txt" 2>/dev/null &
        PIDS+=($!)
    done
    
    local TOTAL_CONNS=$((PROCS * THREADS * CLIENTS))
    echo "  Procs: ${PROCS} | Connections: ${TOTAL_CONNS}"
    echo "  Waiting..."
    for pid in "${PIDS[@]}"; do wait "$pid" 2>/dev/null || true; done
    
    local TOTAL_OPS=0 TOTAL_P99=0 COUNT=0
    for f in "${RESULTS_DIR}/${LABEL}_n"*"_${TIMESTAMP}.txt"; do
        local OPS=$(grep "^Totals" "$f" 2>/dev/null | awk '{print $2}')
        local P99=$(grep "^Totals" "$f" 2>/dev/null | awk '{print $7}')
        if [[ -n "$OPS" && "$OPS" != "0.00" ]]; then
            TOTAL_OPS=$(echo "$TOTAL_OPS + $OPS" | bc)
            TOTAL_P99=$(echo "$TOTAL_P99 + $P99" | bc 2>/dev/null || echo "$TOTAL_P99")
            COUNT=$((COUNT+1))
        fi
    done
    
    if [[ $COUNT -gt 0 ]]; then
        local AVG_P99=$(echo "scale=2; $TOTAL_P99 / $COUNT" | bc)
        local OPS_INT=$(printf "%.0f" "$TOTAL_OPS")
        echo "  >>> ${OPS_INT} ops/sec | p99: ${AVG_P99} ms  [${COUNT} procs]"
        echo "${LABEL} | ${OPS_INT} ops/sec | p99: ${AVG_P99} ms | ${COUNT} procs | ${TOTAL_CONNS} conns" >> "$REPORT"
    else
        echo "  >>> ERROR: no valid results"
    fi
}

#===============================================================================
echo "==============================================================================="
echo " Redis Cluster Horizontal Scaling v9"
echo " $(date)"
echo " Client: 101 (+ 102 when not a server)"
echo " Server pool: ${ALL_SERVERS[*]}"
echo " 1 instance per node, scaling nodes"
echo " Params: pipeline=${PIPELINE}, data=${DATA_SIZE}B, ratio=${RATIO}, time=${TEST_TIME}s"
echo "==============================================================================="

{
echo "Redis Cluster Horizontal Scaling v9 — $(date)"
echo "1 instance (core) per node, scaling node count"
echo "Params: pipeline=${PIPELINE}, data=${DATA_SIZE}B, ratio=${RATIO}, time=${TEST_TIME}s"
echo ""
} > "$REPORT"

#-------------------------------------------------------------------------------
# TEST 0: Standalone baseline (1 node, no cluster)
echo ""
echo "--- Standalone: 1 node × 1 instance (no cluster) ---"
stop_all
ssh "${ALL_SERVERS[0]}" "
    rm -rf /tmp/redis-cluster; mkdir -p /tmp/redis-cluster/${PORT}
    redis-server --port ${PORT} --bind 0.0.0.0 --protected-mode no \
        --dir /tmp/redis-cluster/${PORT} \
        --appendonly no --save '' --maxclients 200000 \
        --tcp-backlog 65535 --hz 100 --daemonize yes 2>/dev/null
    echo \"\$(pgrep -c redis-server) redis on \$(hostname -s)\"
" 2>&1 | grep "redis on"
sleep 1

run_standalone_test "standalone_1n" "${ALL_SERVERS[0]}"

#-------------------------------------------------------------------------------
# TEST 1: 3-node cluster
echo ""
echo "--- Cluster: 3 nodes × 1 instance ---"
stop_all
for i in 0 1 2; do
    start_instance "${ALL_SERVERS[$i]}"
done
sleep 2
create_cluster "${ALL_SERVERS[0]}" "${ALL_SERVERS[1]}" "${ALL_SERVERS[2]}"
sleep 2

# Use 2 clients (node 102 is not a server in this test)
run_cluster_test "cluster_3n" "${ALL_SERVERS[0]}" 2

#-------------------------------------------------------------------------------
# TEST 2: 4-node cluster (add node 102)
echo ""
echo "--- Cluster: 4 nodes × 1 instance ---"
# Add 4th server (200.0.0.102)
start_instance "${ALL_SERVERS[3]}"
sleep 1
add_node_to_cluster "${ALL_SERVERS[3]}" "${ALL_SERVERS[0]}"
sleep 2

# Node 102 is now a server — only 1 client (101)
run_cluster_test "cluster_4n" "${ALL_SERVERS[0]}" 1

#-------------------------------------------------------------------------------
# TEST 3: 5-node cluster (add node 101 itself as server too)
echo ""
echo "--- Cluster: 5 nodes × 1 instance ---"
# Add 5th server (200.0.0.101 — local node, also the client)
start_instance "${ALL_SERVERS[4]}"
sleep 1
add_node_to_cluster "${ALL_SERVERS[4]}" "${ALL_SERVERS[0]}"
sleep 2

# Only local client (101 is both client and server — 1 Redis uses 1 core, plenty left)
run_cluster_test "cluster_5n" "${ALL_SERVERS[0]}" 1

#-------------------------------------------------------------------------------
stop_all

echo ""
echo "==============================================================================="
echo " COMPLETE — $(date)"
echo "==============================================================================="
echo ""
cat "$REPORT"
echo ""
echo "Full results: $RESULTS_DIR"
