#!/bin/bash
#===============================================================================
# Redis Cluster Horizontal Scaling v9b — Fixed client loading
#
# 1 instance per node, scale nodes 3→4→5 in Redis Cluster mode.
# Client always node 101 with enough procs to saturate all server instances.
# Node 101 also runs Redis for 5-node test (1 core out of 160 — negligible).
#===============================================================================
set +e

MEMTIER="/usr/local/bin/memtier_benchmark"
REDIS_CLI="/usr/local/bin/redis-cli"

ALL_SERVERS=(200.0.0.103 200.0.0.104 200.0.0.107 200.0.0.102 200.0.0.101)
ALL_SERVERS_220=(220.0.0.103 220.0.0.104 220.0.0.107 220.0.0.102 220.0.0.101)
PORT=7000

PIPELINE=20
DATA_SIZE=256
RATIO="1:1"
TEST_TIME=60

RESULTS_DIR="/root/redis-scaling-test/results_v9b"
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

start_standalone() {
    local NODE=$1
    ssh "$NODE" "
        rm -rf /tmp/redis-cluster; mkdir -p /tmp/redis-cluster/${PORT}
        redis-server --port ${PORT} --bind 0.0.0.0 --protected-mode no \
            --dir /tmp/redis-cluster/${PORT} \
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
    echo "  Creating cluster:${CLUSTER_NODES}"
    $REDIS_CLI --cluster create $CLUSTER_NODES --cluster-replicas 0 --cluster-yes 2>&1 | tail -3
    sleep 3
    $REDIS_CLI -h "${NODES[0]}" -p $PORT cluster info 2>/dev/null | grep cluster_state
}

add_node_to_cluster() {
    local NEW_NODE=$1
    local EXISTING_NODE=$2
    echo "  Adding ${NEW_NODE}:${PORT}..."
    $REDIS_CLI --cluster add-node "${NEW_NODE}:${PORT}" "${EXISTING_NODE}:${PORT}" 2>&1 | tail -2
    sleep 2
    echo "  Rebalancing..."
    $REDIS_CLI --cluster rebalance "${EXISTING_NODE}:${PORT}" --cluster-use-empty-masters 2>&1 | tail -3
    sleep 5
    $REDIS_CLI -h "${EXISTING_NODE}" -p $PORT cluster info 2>/dev/null | grep cluster_state
}

run_test() {
    local LABEL=$1
    local ENTRY_NODE=$2     # Entry point for cluster-mode discovery
    local CLUSTER_MODE=$3   # "yes" or "no"
    local NUM_NODES=$4
    
    # Scale procs with node count to properly load the cluster
    # Each node has 1 instance that can do ~2M. Use enough procs to push it.
    # 8 procs per node (4 per NIC) — each proc does ~400K in cluster mode
    local PROCS_PER_NIC=$((NUM_NODES * 2))
    [[ $PROCS_PER_NIC -gt 12 ]] && PROCS_PER_NIC=12
    
    local THREADS=16
    local CLIENTS=25
    local CLUSTER_FLAG=""
    [[ "$CLUSTER_MODE" == "yes" ]] && CLUSTER_FLAG="--cluster-mode"
    
    local PIDS=()
    local P=0
    
    # Find 220 address for entry node
    local TARGET_IDX=-1
    for i in "${!ALL_SERVERS[@]}"; do
        if [[ "${ALL_SERVERS[$i]}" == "$ENTRY_NODE" ]]; then
            TARGET_IDX=$i; break
        fi
    done
    local ENTRY_220="${ALL_SERVERS_220[$TARGET_IDX]}"
    
    # Launch from local client (101) — NIC1 (200.0.0.x)
    for j in $(seq 1 $PROCS_PER_NIC); do
        P=$((P+1))
        $MEMTIER --server="$ENTRY_NODE" --port="$PORT" --protocol=redis $CLUSTER_FLAG \
            --threads="$THREADS" --clients="$CLIENTS" --pipeline="$PIPELINE" \
            --data-size="$DATA_SIZE" --ratio="$RATIO" --test-time="$TEST_TIME" \
            --key-minimum=1 --key-maximum=10000000 --key-pattern=R:R \
            --hide-histogram > "${RESULTS_DIR}/${LABEL}_n1_p${P}_${TIMESTAMP}.txt" 2>/dev/null &
        PIDS+=($!)
    done
    
    # Launch from local client (101) — NIC2 (220.0.0.x)
    for j in $(seq 1 $PROCS_PER_NIC); do
        P=$((P+1))
        $MEMTIER --server="$ENTRY_220" --port="$PORT" --protocol=redis $CLUSTER_FLAG \
            --threads="$THREADS" --clients="$CLIENTS" --pipeline="$PIPELINE" \
            --data-size="$DATA_SIZE" --ratio="$RATIO" --test-time="$TEST_TIME" \
            --key-minimum=1 --key-maximum=10000000 --key-pattern=R:R \
            --hide-histogram > "${RESULTS_DIR}/${LABEL}_n2_p${P}_${TIMESTAMP}.txt" 2>/dev/null &
        PIDS+=($!)
    done
    
    local TOTAL_PROCS=${#PIDS[@]}
    local TOTAL_CONNS=$((TOTAL_PROCS * THREADS * CLIENTS))
    echo "  Procs: ${TOTAL_PROCS} (${PROCS_PER_NIC}/NIC × 2 NICs) | Conns: ${TOTAL_CONNS}"
    echo "  Waiting for ${TEST_TIME}s..."
    for pid in "${PIDS[@]}"; do wait "$pid" 2>/dev/null || true; done
    
    # Aggregate
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
        local PER_NODE=$((OPS_INT / NUM_NODES))
        echo "  >>> ${OPS_INT} ops/sec | p99: ${AVG_P99} ms | per-node: ${PER_NODE} [${COUNT}/${TOTAL_PROCS} procs]"
        echo "${LABEL} | ${OPS_INT} | p99: ${AVG_P99} ms | ${PER_NODE}/node | ${COUNT}/${TOTAL_PROCS} procs | ${TOTAL_CONNS} conns" >> "$REPORT"
    else
        echo "  >>> ERROR: no valid results"
        echo "${LABEL} | ERROR" >> "$REPORT"
    fi
}

#===============================================================================
echo "==============================================================================="
echo " Redis Cluster Horizontal Scaling v9b"
echo " $(date)"
echo " Client: 101 only (dual-NIC, scaled procs)"
echo " Servers: 103, 104, 107, 102, 101 — 1 instance each"
echo " Params: pipeline=${PIPELINE}, data=${DATA_SIZE}B, ratio=${RATIO}, time=${TEST_TIME}s"
echo "==============================================================================="

{
echo "Redis Cluster Horizontal Scaling v9b — $(date)"
echo "Client: 101 (dual-NIC), Servers: 1 instance/node"
echo "Params: pipeline=${PIPELINE}, data=${DATA_SIZE}B, ratio=${RATIO}, time=${TEST_TIME}s"
echo ""
} > "$REPORT"

#--- Standalone: 1 node ---
echo ""
echo "--- 1 node × 1 instance (standalone, no cluster) ---"
stop_all
start_standalone "${ALL_SERVERS[0]}"
sleep 1
run_test "standalone_1n" "${ALL_SERVERS[0]}" "no" 1

#--- Cluster: 3 nodes ---
echo ""
echo "--- 3 nodes × 1 instance (cluster) ---"
stop_all
for i in 0 1 2; do start_instance "${ALL_SERVERS[$i]}"; done
sleep 2
create_cluster "${ALL_SERVERS[0]}" "${ALL_SERVERS[1]}" "${ALL_SERVERS[2]}"
sleep 2
run_test "cluster_3n" "${ALL_SERVERS[0]}" "yes" 3

#--- Cluster: 4 nodes ---
echo ""
echo "--- 4 nodes × 1 instance (cluster) ---"
start_instance "${ALL_SERVERS[3]}"
sleep 1
add_node_to_cluster "${ALL_SERVERS[3]}" "${ALL_SERVERS[0]}"
sleep 2
run_test "cluster_4n" "${ALL_SERVERS[0]}" "yes" 4

#--- Cluster: 5 nodes ---
echo ""
echo "--- 5 nodes × 1 instance (cluster) ---"
# Start Redis on local node (101) — it's fine, uses 1 core
rm -rf /tmp/redis-cluster; mkdir -p /tmp/redis-cluster/${PORT}
redis-server --port ${PORT} --bind 0.0.0.0 --protected-mode no \
    --dir /tmp/redis-cluster/${PORT} \
    --cluster-enabled yes --cluster-config-file nodes.conf \
    --cluster-node-timeout 5000 \
    --appendonly no --save '' --maxclients 200000 \
    --tcp-backlog 65535 --hz 100 --daemonize yes 2>/dev/null
echo "  $(pgrep -c redis-server) redis on $(hostname -s)"
sleep 1
add_node_to_cluster "${ALL_SERVERS[4]}" "${ALL_SERVERS[0]}"
sleep 2
run_test "cluster_5n" "${ALL_SERVERS[0]}" "yes" 5

#-------------------------------------------------------------------------------
stop_all

echo ""
echo "==============================================================================="
echo " COMPLETE — $(date)"
echo "==============================================================================="
echo ""
cat "$REPORT"
