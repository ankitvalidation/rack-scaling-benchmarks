#!/bin/bash
#===============================================================================
# Redis Cluster Scaling Benchmark v2
# 
# Key insight from v1: 1 node × 32 instances already hits 32M ops/sec, 
# saturating the client's 200G NIC. To show proper scaling, we use:
#   - Fixed memtier config (48 threads × 20 clients) to avoid client overload
#   - Both client NICs (200.0.0.x + 220.0.0.x) for higher-node tests
#
# Architecture:
#   Client:  101 (200.0.0.101 / 220.0.0.101, dual 200G NICs)
#   Servers: 103, 104, 106, 107, 102 (all have dual NICs)
#===============================================================================
set +e

REDIS_CLI="/usr/local/bin/redis-cli"
MEMTIER="/usr/local/bin/memtier_benchmark"

# Server nodes (order for scaling: 1,2,3,4,5 nodes)
ALL_SERVERS_200=(200.0.0.103 200.0.0.104 200.0.0.106 200.0.0.107 200.0.0.102)
ALL_SERVERS_220=(220.0.0.103 220.0.0.104 220.0.0.106 220.0.0.107 220.0.0.102)

# Memtier parameters
PIPELINE=20
DATA_SIZE=256
RATIO="1:1"
TEST_TIME=60

RESULTS_DIR="/root/redis-scaling-test/results"
mkdir -p "$RESULTS_DIR"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
REPORT="${RESULTS_DIR}/scaling_report_${TIMESTAMP}.csv"

# CSV header
echo "Test,Nodes,Instances_Per_Node,Total_Instances,Ops_Sec,Avg_Latency_ms,P99_Latency_ms,P999_Latency_ms,KB_Sec" > "$REPORT"

#===============================================================================
# Helper Functions
#===============================================================================

log() { echo "[$(date +%H:%M:%S)] $*"; }

stop_all_redis() {
    log "Stopping Redis on all nodes..."
    for node in "${ALL_SERVERS_200[@]}"; do
        ssh "$node" 'pkill -9 redis-server 2>/dev/null; rm -rf ~/redis-cluster-run' 2>/dev/null &
    done
    wait
    sleep 2
}

start_redis_on_node() {
    local NODE_200=$1
    local NODE_220=$2
    local NUM_INSTANCES=$3
    local START_PORT=7000

    # Start instances announcing on 200.0.0.x network
    ssh "$NODE_200" "
        mkdir -p ~/redis-cluster-run
        for i in \$(seq 0 $((NUM_INSTANCES - 1))); do
            PORT=\$((${START_PORT} + \$i))
            DIR=~/redis-cluster-run/\$PORT
            mkdir -p \$DIR
            redis-server \\
                --port \$PORT \\
                --bind 0.0.0.0 \\
                --protected-mode no \\
                --dir \$DIR \\
                --cluster-enabled yes \\
                --cluster-config-file nodes.conf \\
                --cluster-node-timeout 5000 \\
                --cluster-announce-ip $NODE_200 \\
                --cluster-announce-port \$PORT \\
                --cluster-announce-bus-port \$((\$PORT + 10000)) \\
                --appendonly no \\
                --save '' \\
                --maxclients 200000 \\
                --io-threads 1 \\
                --daemonize yes 2>/dev/null
        done
        sleep 1
        RUNNING=\$(pgrep -c redis-server 2>/dev/null)
        echo \"\$RUNNING instances running on \$(hostname)\"
    " 2>&1 | grep "instances running"
}

create_cluster() {
    local -n NODES_REF=$1
    local INSTANCES=$2

    local CLUSTER_ARGS=""
    for node in "${NODES_REF[@]}"; do
        for port in $(seq 7000 $((7000 + INSTANCES - 1))); do
            CLUSTER_ARGS="${CLUSTER_ARGS} ${node}:${port}"
        done
    done

    yes yes | $REDIS_CLI --cluster create $CLUSTER_ARGS --cluster-replicas 0 2>/dev/null | grep -E "slots|OK" | tail -2
    sleep 3
    
    local STATE=$($REDIS_CLI -c -h "${NODES_REF[0]}" -p 7000 cluster info 2>/dev/null | grep cluster_state | tr -d '\r')
    log "  $STATE"
}

run_benchmark() {
    local TARGET=$1
    local PORT=$2  
    local THREADS=$3
    local CLIENTS=$4
    local LABEL=$5
    local OUTFILE="${RESULTS_DIR}/${LABEL}_${TIMESTAMP}.txt"

    log "  memtier: target=$TARGET threads=${THREADS} clients=${CLIENTS} pipeline=${PIPELINE} time=${TEST_TIME}s"
    
    $MEMTIER \
        --server="$TARGET" \
        --port="$PORT" \
        --protocol=redis \
        --cluster-mode \
        --threads="$THREADS" \
        --clients="$CLIENTS" \
        --pipeline="$PIPELINE" \
        --data-size="$DATA_SIZE" \
        --ratio="$RATIO" \
        --test-time="$TEST_TIME" \
        --key-pattern="R:R" \
        --key-minimum=1 \
        --key-maximum=10000000 \
        --hide-histogram \
        2>/dev/null > "$OUTFILE"
    
    # Parse results from the Totals line
    local TOTALS=$(grep "^Totals" "$OUTFILE" | tail -1)
    if [[ -n "$TOTALS" ]]; then
        local OPS=$(echo "$TOTALS" | awk '{print $2}')
        local AVG_LAT=$(echo "$TOTALS" | awk '{print $7}')
        local P99=$(echo "$TOTALS" | awk '{print $9}')
        local P999=$(echo "$TOTALS" | awk '{print $10}')
        local KBSEC=$(echo "$TOTALS" | awk '{print $NF}')
        printf "  %-40s | %'15.0f ops/sec | avg %8.2f ms | p99 %8.2f ms | %'.0f KB/s\n" \
            "$LABEL" "$OPS" "$AVG_LAT" "$P99" "$KBSEC"
        echo "${LABEL},${NUM_NODES_CUR},${NUM_INST},${TOTAL_INST},${OPS},${AVG_LAT},${P99},${P999},${KBSEC}" >> "$REPORT"
    else
        log "  WARNING: No results in $OUTFILE"
        echo "${LABEL},${NUM_NODES_CUR},${NUM_INST},${TOTAL_INST},0,0,0,0,0" >> "$REPORT"
    fi
}

#===============================================================================
echo "==============================================================================="
echo " Redis Cluster Scaling Benchmark v2"  
echo " $(date)"
echo " Client: 101 (dual 200G NICs: 200.0.0.101 + 220.0.0.101)"
echo " Servers: 103, 104, 106, 107, 102"
echo " Params: pipeline=${PIPELINE}, data=${DATA_SIZE}B, ratio=${RATIO}, time=${TEST_TIME}s"
echo "==============================================================================="
echo ""

#===============================================================================
# TEST 1: Node Scaling - 32 instances per node, 1→5 nodes
#===============================================================================
echo "======== TEST 1: NODE SCALING (32 instances/node, add nodes) ========"
NUM_INST=32

# Fixed memtier config: 48 threads, 20 clients (safe for cluster-mode)
THREADS=48
CLIENTS=20

for NUM_NODES_CUR in 1 2 3 4 5; do
    SERVERS_200=("${ALL_SERVERS_200[@]:0:$NUM_NODES_CUR}")
    SERVERS_220=("${ALL_SERVERS_220[@]:0:$NUM_NODES_CUR}")
    TOTAL_INST=$((NUM_NODES_CUR * NUM_INST))
    
    LABEL="node_${NUM_NODES_CUR}x${NUM_INST}"
    echo ""
    log "=== ${NUM_NODES_CUR} node(s) × ${NUM_INST} instances = ${TOTAL_INST} total ==="
    
    stop_all_redis
    
    for idx in $(seq 0 $((NUM_NODES_CUR - 1))); do
        start_redis_on_node "${SERVERS_200[$idx]}" "${SERVERS_220[$idx]}" "$NUM_INST"
    done
    sleep 2
    
    create_cluster SERVERS_200 "$NUM_INST"
    
    run_benchmark "${SERVERS_200[0]}" 7000 "$THREADS" "$CLIENTS" "$LABEL"
done

#===============================================================================
# TEST 2: Density Scaling - 3 nodes, 1→160 instances per node
#===============================================================================
echo ""
echo ""
echo "======== TEST 2: DENSITY SCALING (3 nodes, scale instances/node) ========"
NUM_NODES_CUR=3

for NUM_INST in 1 8 16 32 64 128 160; do
    SERVERS_200=("${ALL_SERVERS_200[@]:0:3}")
    SERVERS_220=("${ALL_SERVERS_220[@]:0:3}")
    TOTAL_INST=$((3 * NUM_INST))
    
    # Adapt client load to server capacity
    if (( NUM_INST <= 1 )); then
        THREADS=4; CLIENTS=50
    elif (( NUM_INST <= 8 )); then
        THREADS=24; CLIENTS=20
    elif (( NUM_INST <= 32 )); then
        THREADS=48; CLIENTS=20
    else
        THREADS=64; CLIENTS=15
    fi
    
    LABEL="density_3x${NUM_INST}"
    echo ""
    log "=== 3 nodes × ${NUM_INST} instances = ${TOTAL_INST} total ==="
    
    stop_all_redis
    
    for idx in 0 1 2; do
        start_redis_on_node "${SERVERS_200[$idx]}" "${SERVERS_220[$idx]}" "$NUM_INST"
    done
    sleep 2
    
    create_cluster SERVERS_200 "$NUM_INST"
    
    run_benchmark "${SERVERS_200[0]}" 7000 "$THREADS" "$CLIENTS" "$LABEL"
done

#===============================================================================
stop_all_redis

echo ""
echo "==============================================================================="
echo " COMPLETE - Results in: ${REPORT}"
echo "==============================================================================="
echo ""
column -t -s',' "$REPORT"
