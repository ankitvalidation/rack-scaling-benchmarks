#!/bin/bash
#===============================================================================
# Redis Cluster Horizontal Scaling — 32 instances per node
#
# Problem solved: memtier --cluster-mode opens connections to ALL cluster nodes.
# With 96 nodes × many procs × many threads × many clients = connection explosion.
# Solution: use fewer, larger memtier procs that cover all nodes internally.
#
# Architecture:
#   - Start 32 Redis cluster-enabled instances on each server node
#   - Create one cluster with all instances (redis-cli --cluster create)
#   - Run memtier with --cluster-mode (auto-discovers all nodes)
#   - Use FEW procs with moderate threads to avoid N² connection blowup
#
# Connection math for 96-node cluster:
#   Each memtier proc opens (threads × clients) connections to EACH cluster node
#   4 threads × 25 clients × 96 nodes = 9,600 connections per proc
#   4 procs total = 38,400 connections — manageable
#===============================================================================
set +e

MEMTIER="/usr/local/bin/memtier_benchmark"
REDIS_CLI="/usr/local/bin/redis-cli"

SERVERS_3=(200.0.0.103 200.0.0.104 200.0.0.107)
SERVERS_4=(200.0.0.103 200.0.0.104 200.0.0.107 200.0.0.102)
SERVERS_5=(200.0.0.103 200.0.0.104 200.0.0.107 200.0.0.102 200.0.0.101)
SERVERS_220=(220.0.0.103 220.0.0.104 220.0.0.107 220.0.0.102 220.0.0.101)

INST_PER_NODE=32
START_PORT=7000
END_PORT=$((START_PORT + INST_PER_NODE - 1))

PIPELINE=20
DATA_SIZE=256
RATIO="1:1"
TEST_TIME=60

RESULTS_DIR="/root/redis-scaling-test/results_cluster32"
rm -rf "$RESULTS_DIR"
mkdir -p "$RESULTS_DIR"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
REPORT="${RESULTS_DIR}/report_${TIMESTAMP}.txt"

#===============================================================================
stop_all() {
    for node in 200.0.0.103 200.0.0.104 200.0.0.107 200.0.0.102; do
        ssh "$node" 'pkill -9 redis-server; rm -rf /tmp/redis-cluster' 2>/dev/null &
    done
    pkill -9 redis-server 2>/dev/null
    pkill -9 memtier 2>/dev/null
    rm -rf /tmp/redis-cluster 2>/dev/null
    wait; sleep 1
}

start_nodes() {
    local NODE=$1
    ssh "$NODE" "
        pkill -9 redis-server 2>/dev/null; rm -rf /tmp/redis-cluster; mkdir -p /tmp/redis-cluster
        for i in \$(seq ${START_PORT} ${END_PORT}); do
            mkdir -p /tmp/redis-cluster/\$i
            redis-server --port \$i --bind 0.0.0.0 --protected-mode no \
                --dir /tmp/redis-cluster/\$i \
                --cluster-enabled yes \
                --cluster-config-file /tmp/redis-cluster/\$i/nodes.conf \
                --cluster-node-timeout 5000 \
                --appendonly no --save '' --maxclients 200000 \
                --tcp-backlog 65535 --hz 100 --daemonize yes 2>/dev/null
        done
        echo \"\$(pgrep -c redis-server) on \$(hostname -s)\"
    " 2>&1 | grep " on "
}

start_nodes_local() {
    pkill -9 redis-server 2>/dev/null; rm -rf /tmp/redis-cluster; mkdir -p /tmp/redis-cluster
    for i in $(seq ${START_PORT} ${END_PORT}); do
        mkdir -p /tmp/redis-cluster/$i
        redis-server --port $i --bind 0.0.0.0 --protected-mode no \
            --dir /tmp/redis-cluster/$i \
            --cluster-enabled yes \
            --cluster-config-file /tmp/redis-cluster/$i/nodes.conf \
            --cluster-node-timeout 5000 \
            --appendonly no --save '' --maxclients 200000 \
            --tcp-backlog 65535 --hz 100 --daemonize yes 2>/dev/null
    done
    echo "  $(pgrep -c redis-server) on $(hostname -s)"
}

create_full_cluster() {
    local NODES=("$@")
    local CLUSTER_ARGS=""
    for node in "${NODES[@]}"; do
        for port in $(seq ${START_PORT} ${END_PORT}); do
            CLUSTER_ARGS="${CLUSTER_ARGS} ${node}:${port}"
        done
    done
    local TOTAL=$(echo $CLUSTER_ARGS | wc -w)
    echo "  Creating cluster with ${TOTAL} members..."
    $REDIS_CLI --cluster create $CLUSTER_ARGS --cluster-replicas 0 --cluster-yes 2>&1 | tail -3
    sleep 5
    echo "  $($REDIS_CLI -h "${NODES[0]}" -p $START_PORT cluster info 2>/dev/null | grep cluster_state)"
    echo "  $($REDIS_CLI -h "${NODES[0]}" -p $START_PORT cluster info 2>/dev/null | grep cluster_known_nodes)"
}

run_cluster_bench() {
    local LABEL=$1
    local ENTRY=$2
    local ENTRY_220=$3
    local NUM_NODES=$4

    # Key insight: with --cluster-mode, memtier connects to ALL cluster nodes.
    # For 96 nodes: 4 threads × 25 clients × 96 = 9,600 conns per proc.
    # Use 4 procs (2 per NIC) = ~38K total connections. Reasonable.
    local THREADS=4
    local CLIENTS=25
    local PROCS_PER_NIC=2
    local PIDS=()
    local P=0

    # NIC1
    for j in $(seq 1 $PROCS_PER_NIC); do
        P=$((P+1))
        $MEMTIER --server="$ENTRY" --port=$START_PORT --protocol=redis --cluster-mode \
            --threads=$THREADS --clients=$CLIENTS --pipeline=$PIPELINE \
            --data-size=$DATA_SIZE --ratio=$RATIO --test-time=$TEST_TIME \
            --key-minimum=1 --key-maximum=10000000 --key-pattern=R:R \
            --hide-histogram > "${RESULTS_DIR}/${LABEL}_n1_p${P}_${TIMESTAMP}.txt" 2>/dev/null &
        PIDS+=($!)
    done

    # NIC2
    for j in $(seq 1 $PROCS_PER_NIC); do
        P=$((P+1))
        $MEMTIER --server="$ENTRY_220" --port=$START_PORT --protocol=redis --cluster-mode \
            --threads=$THREADS --clients=$CLIENTS --pipeline=$PIPELINE \
            --data-size=$DATA_SIZE --ratio=$RATIO --test-time=$TEST_TIME \
            --key-minimum=1 --key-maximum=10000000 --key-pattern=R:R \
            --hide-histogram > "${RESULTS_DIR}/${LABEL}_n2_p${P}_${TIMESTAMP}.txt" 2>/dev/null &
        PIDS+=($!)
    done

    local TOTAL_PROCS=${#PIDS[@]}
    local CLUSTER_MEMBERS=$((NUM_NODES * INST_PER_NODE))
    local CONNS_PER_PROC=$((THREADS * CLIENTS * CLUSTER_MEMBERS))
    local TOTAL_CONNS=$((TOTAL_PROCS * CONNS_PER_PROC))
    echo "  Procs: $TOTAL_PROCS (${THREADS}T × ${CLIENTS}C × ${CLUSTER_MEMBERS} cluster nodes = ${CONNS_PER_PROC}/proc)"
    echo "  Total connections: $TOTAL_CONNS"
    echo "  Waiting for cluster discovery + ${TEST_TIME}s test..."

    for pid in "${PIDS[@]}"; do wait "$pid" 2>/dev/null || true; done

    # Aggregate
    local TOTAL_OPS=0 TOTAL_P99=0 COUNT=0
    for f in "${RESULTS_DIR}/${LABEL}_"*"_${TIMESTAMP}.txt"; do
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
        echo "  >>> $OPS_INT ops/sec | p99: ${AVG_P99} ms | per-node: $PER_NODE [${COUNT}/${TOTAL_PROCS}]"
        echo "${LABEL} | $OPS_INT | p99: ${AVG_P99} ms | ${PER_NODE}/node | ${COUNT}/${TOTAL_PROCS} procs" >> "$REPORT"
    else
        echo "  >>> ERROR: no valid results"
        echo "${LABEL} | ERROR" >> "$REPORT"
    fi
}

#===============================================================================
echo "==============================================================================="
echo " Redis Cluster 32 inst/node — Horizontal Scaling"
echo " $(date)"
echo " Params: ${INST_PER_NODE} inst/node, pipeline=${PIPELINE}, data=${DATA_SIZE}B"
echo "==============================================================================="

{
echo "Redis Cluster 32 inst/node — $(date)"
echo "pipeline=${PIPELINE}, data=${DATA_SIZE}B, ratio=${RATIO}, time=${TEST_TIME}s"
echo ""
} > "$REPORT"

#--- 3 nodes × 32 = 96 cluster members ---
echo ""
echo "--- 3 nodes × 32 instances = 96 cluster members ---"
stop_all
for node in "${SERVERS_3[@]}"; do start_nodes "$node"; done
sleep 3
create_full_cluster "${SERVERS_3[@]}"
sleep 10
run_cluster_bench "cluster_3n_32i" "${SERVERS_3[0]}" "${SERVERS_220[0]}" 3

#--- 4 nodes × 32 = 128 cluster members ---
echo ""
echo "--- 4 nodes × 32 instances = 128 cluster members ---"
stop_all
for node in "${SERVERS_4[@]}"; do start_nodes "$node"; done
sleep 3
create_full_cluster "${SERVERS_4[@]}"
sleep 10
run_cluster_bench "cluster_4n_32i" "${SERVERS_4[0]}" "${SERVERS_220[0]}" 4

#--- 5 nodes × 32 = 160 cluster members ---
echo ""
echo "--- 5 nodes × 32 instances = 160 cluster members ---"
stop_all
for node in "${SERVERS_4[@]}"; do start_nodes "$node"; done
start_nodes_local
sleep 3
create_full_cluster "${SERVERS_5[@]}"
sleep 10
run_cluster_bench "cluster_5n_32i" "${SERVERS_5[0]}" "${SERVERS_220[0]}" 5

#-------------------------------------------------------------------------------
stop_all
echo ""
echo "==============================================================================="
echo " COMPLETE — $(date)"
echo "==============================================================================="
echo ""
cat "$REPORT"
