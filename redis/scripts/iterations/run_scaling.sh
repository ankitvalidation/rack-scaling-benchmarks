#!/bin/bash
#===============================================================================
# Redis Cluster Scaling Benchmark
# Shows horizontal (node) and vertical (density) scaling on 200G network
#
# Architecture:
#   Client:  200.0.0.101 (memtier_benchmark, 160 cores)
#   Servers: 200.0.0.103, 200.0.0.104, 200.0.0.106, 200.0.0.107
#
# Tests:
#   1. Node Scaling: 1→4 nodes × 32 instances/node (fixed density)
#   2. Density Scaling: 3 nodes × 1→32 instances/node (fixed nodes)
#===============================================================================
set +e

REDIS_SERVER="/usr/local/bin/redis-server"
REDIS_CLI="/usr/local/bin/redis-cli"
MEMTIER="/usr/local/bin/memtier_benchmark"

# Network: use 200.0.0.x (same as SSH, 200Gbps NIC)
# Node 106 is down - using 103, 104, 107, 102 as servers
ALL_SERVERS=(200.0.0.103 200.0.0.104 200.0.0.107 200.0.0.102)
CLIENT_IP=200.0.0.101

# Memtier parameters (matching prior tests)
PIPELINE=20
DATA_SIZE=256
RATIO="1:1"
TEST_TIME=60
KEY_PATTERN="R:R"

RESULTS_DIR="/root/redis-scaling-test/results"
mkdir -p "$RESULTS_DIR"

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
REPORT="${RESULTS_DIR}/scaling_report_${TIMESTAMP}.txt"

#===============================================================================
# Helper Functions
#===============================================================================

stop_all_redis() {
    echo "  Stopping Redis on all nodes..."
    for node in "${ALL_SERVERS[@]}"; do
        ssh "$node" 'pkill -9 redis-server 2>/dev/null; rm -rf ~/redis-cluster-run' 2>/dev/null &
    done
    wait
    sleep 2
}

start_redis_instances() {
    local NODE=$1
    local NUM_INSTANCES=$2
    local START_PORT=7000

    ssh "$NODE" "
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
                --cluster-announce-ip $NODE \\
                --cluster-announce-port \$PORT \\
                --cluster-announce-bus-port \$((\$PORT + 10000)) \\
                --appendonly no \\
                --save '' \\
                --maxclients 200000 \\
                --io-threads 1 \\
                --daemonize yes 2>/dev/null
        done
        echo \$(pgrep -c redis-server) instances running
    " 2>&1 | grep -v "^::" | grep -v "oneAPI\|BASH_\|bash:\|args:\|setvars\|advisor\|ccl\|compiler\|dal\|debugger\|dev-util\|dnnl\|dpcpp\|dpl\|ipp\|mkl\|mpi\|tbb\|umf\|vtune\|initialized\|WARNING\|force\|config=\|help\|POSIX\|SETVARS\|toolkits\|usage:"
}

create_cluster() {
    local NODES=("$@")
    local INSTANCES_PER_NODE=$NUM_INST

    echo "  Creating cluster with ${#NODES[@]} nodes × ${INSTANCES_PER_NODE} instances..."
    
    local CLUSTER_ARGS=""
    for node in "${NODES[@]}"; do
        for port in $(seq 7000 $((7000 + INSTANCES_PER_NODE - 1))); do
            CLUSTER_ARGS="${CLUSTER_ARGS} ${node}:${port}"
        done
    done

    yes yes | $REDIS_CLI --cluster create $CLUSTER_ARGS --cluster-replicas 0 --cluster-yes 2>/dev/null | tail -3
    sleep 5
    
    # Verify cluster
    local INFO=$($REDIS_CLI -c -h "${NODES[0]}" -p 7000 cluster info 2>/dev/null | grep cluster_state || echo "unknown")
    echo "  Cluster state: $INFO"
}

run_memtier() {
    local TARGET_NODE=$1
    local TARGET_PORT=$2
    local NUM_PROCS=$3    # Number of parallel memtier processes
    local THREADS=$4      # Threads per process
    local CLIENTS=$5      # Clients per thread
    local LABEL=$6
    
    echo "  Running memtier: ${NUM_PROCS} processes × ${THREADS} threads × ${CLIENTS} clients, pipeline=${PIPELINE}, time=${TEST_TIME}s..."
    echo "  Total connections: $((NUM_PROCS * THREADS * CLIENTS)), in-flight: $((NUM_PROCS * THREADS * CLIENTS * PIPELINE))"
    
    local PIDS=()
    for p in $(seq 1 "$NUM_PROCS"); do
        local OUTFILE="${RESULTS_DIR}/${LABEL}_p${p}_${TIMESTAMP}.txt"
        $MEMTIER \
            --server="$TARGET_NODE" \
            --port="$TARGET_PORT" \
            --protocol=redis \
            --cluster-mode \
            --threads="$THREADS" \
            --clients="$CLIENTS" \
            --pipeline="$PIPELINE" \
            --data-size="$DATA_SIZE" \
            --ratio="$RATIO" \
            --test-time="$TEST_TIME" \
            --key-pattern="$KEY_PATTERN" \
            --key-minimum=1 \
            --key-maximum=10000000 \
            --hide-histogram \
            > "$OUTFILE" 2>/dev/null &
        PIDS+=($!)
    done
    
    # Wait for all processes
    for pid in "${PIDS[@]}"; do
        wait "$pid" 2>/dev/null || true
    done
    
    # Aggregate results: sum ops/sec, average latencies
    local TOTAL_OPS=0
    local TOTAL_P99=0
    local COUNT=0
    for p in $(seq 1 "$NUM_PROCS"); do
        local OUTFILE="${RESULTS_DIR}/${LABEL}_p${p}_${TIMESTAMP}.txt"
        local LINE=$(grep "^Totals" "$OUTFILE" 2>/dev/null | tail -1)
        if [[ -n "$LINE" ]]; then
            # Totals format: Totals  OPS/sec  SETS/sec  GETS/sec  AvgLat  AvgSetLat  p99Lat ...
            local OPS=$(echo "$LINE" | awk '{print $2}')
            local P99=$(echo "$LINE" | awk '{print $7}')
            if [[ "$OPS" != "0.00" && -n "$OPS" ]]; then
                TOTAL_OPS=$(echo "$TOTAL_OPS + $OPS" | bc)
                TOTAL_P99=$(echo "$TOTAL_P99 + $P99" | bc)
                COUNT=$((COUNT + 1))
            fi
        fi
    done
    
    if [[ $COUNT -gt 0 ]]; then
        local AVG_P99=$(echo "scale=2; $TOTAL_P99 / $COUNT" | bc)
        local OPS_INT=$(echo "$TOTAL_OPS" | cut -d. -f1)
        local OPS_FMT=$(printf "%'d" "$OPS_INT" 2>/dev/null || echo "$OPS_INT")
        local RESULT_LINE="${OPS_FMT} ops/sec | p99 ${AVG_P99} ms (${COUNT} procs summed)"
        echo "  >>> $RESULT_LINE"
        echo "$RESULT_LINE" > "${RESULTS_DIR}/${LABEL}_SUMMARY_${TIMESTAMP}.txt"
    else
        echo "  >>> ERROR: No results collected"
    fi
    echo ""
}

extract_results() {
    local OUTFILE=$1
    # Extract from the "Totals" line: Ops/sec, Avg Latency, p99 Latency
    grep "^Totals" "$OUTFILE" | tail -1 | awk '{printf "  Ops/sec: %s | Avg Latency: %s ms | p99: %s ms\n", $2, $5, $7}'
}

#===============================================================================
# Main Test Execution
#===============================================================================

echo "==============================================================================="
echo " Redis Cluster Scaling Benchmark"
echo " Date: $(date)"
echo " Client: ${CLIENT_IP} (160 cores)"
echo " Servers: ${ALL_SERVERS[*]}"
echo " Parameters: pipeline=${PIPELINE} data-size=${DATA_SIZE} ratio=${RATIO} time=${TEST_TIME}s"
echo "==============================================================================="
echo ""

{
echo "Redis Cluster Scaling Benchmark Results"
echo "Date: $(date)"
echo "Client: ${CLIENT_IP} (160 cores)"
echo "Parameters: pipeline=${PIPELINE}, data-size=${DATA_SIZE}B, ratio=${RATIO}, time=${TEST_TIME}s"
echo ""
echo "==============================================================================="
echo "TEST 1: NODE SCALING (32 instances per node, servers: 103,104,107,102)"
echo "==============================================================================="
} | tee "$REPORT"

#-------------------------------------------------------------------------------
# TEST 1: Node Scaling - 32 instances per node, 1→5 nodes
# Client: multiple memtier processes to avoid single-process bottleneck
#-------------------------------------------------------------------------------
NUM_INST=32

for NUM_NODES in 1 2 3 4; do
    SERVERS=("${ALL_SERVERS[@]:0:$NUM_NODES}")
    TOTAL_INSTANCES=$((NUM_NODES * NUM_INST))
    
    # Scale memtier processes with nodes (each proc ~32M max)
    # Use NUM_NODES processes, each with 32 threads × 20 clients
    NUM_PROCS=$NUM_NODES
    CLIENT_THREADS=32
    CLIENT_CONNS=20
    
    LABEL="node_scaling_${NUM_NODES}n_${NUM_INST}i"
    
    echo ""
    echo "--- ${NUM_NODES} node(s) × ${NUM_INST} instances = ${TOTAL_INSTANCES} total ---"
    
    stop_all_redis
    
    # Start instances on each node
    for node in "${SERVERS[@]}"; do
        start_redis_instances "$node" "$NUM_INST"
    done
    sleep 3
    
    # Create cluster
    create_cluster "${SERVERS[@]}"
    
    # Run benchmark with multiple memtier processes
    run_memtier "${SERVERS[0]}" 7000 "$NUM_PROCS" "$CLIENT_THREADS" "$CLIENT_CONNS" "$LABEL"
    
    echo "  Config: ${NUM_NODES}n×${NUM_INST}i" | tee -a "$REPORT"
    cat "${RESULTS_DIR}/${LABEL}_SUMMARY_${TIMESTAMP}.txt" 2>/dev/null | tee -a "$REPORT"
done

{
echo ""
echo "==============================================================================="
echo "TEST 2: DENSITY SCALING (3 nodes, 1→32 instances per node)"
echo "==============================================================================="
} | tee -a "$REPORT"

#-------------------------------------------------------------------------------
# TEST 2: Density Scaling - 3 nodes, variable instances per node
# Scale memtier processes to match server capacity
#-------------------------------------------------------------------------------
DENSITY_SERVERS=("${ALL_SERVERS[@]:0:3}")

for NUM_INST in 1 8 16 32 64 128 160; do
    TOTAL_INSTANCES=$((3 * NUM_INST))
    
    # Scale memtier processes: 1 proc per ~32 server instances, min 1
    NUM_PROCS=$(( (TOTAL_INSTANCES + 31) / 32 ))
    [[ $NUM_PROCS -lt 1 ]] && NUM_PROCS=1
    [[ $NUM_PROCS -gt 15 ]] && NUM_PROCS=15
    CLIENT_THREADS=32
    CLIENT_CONNS=20
    [[ $NUM_INST -le 1 ]] && CLIENT_THREADS=4 && CLIENT_CONNS=50 && NUM_PROCS=1
    
    LABEL="density_scaling_3n_${NUM_INST}i"
    
    echo ""
    echo "--- 3 nodes × ${NUM_INST} instances = ${TOTAL_INSTANCES} total ---"
    
    stop_all_redis
    
    for node in "${DENSITY_SERVERS[@]}"; do
        start_redis_instances "$node" "$NUM_INST"
    done
    sleep 3
    
    create_cluster "${DENSITY_SERVERS[@]}"
    
    run_memtier "${DENSITY_SERVERS[0]}" 7000 "$NUM_PROCS" "$CLIENT_THREADS" "$CLIENT_CONNS" "$LABEL"
    
    echo "  Config: 3n×${NUM_INST}i" | tee -a "$REPORT"
    cat "${RESULTS_DIR}/${LABEL}_SUMMARY_${TIMESTAMP}.txt" 2>/dev/null | tee -a "$REPORT"
done

#-------------------------------------------------------------------------------
# Cleanup and Summary
#-------------------------------------------------------------------------------
stop_all_redis

echo ""
echo "===============================================================================" | tee -a "$REPORT"
echo " SUMMARY" | tee -a "$REPORT"
echo "===============================================================================" | tee -a "$REPORT"
echo "" | tee -a "$REPORT"
echo "Full results in: ${RESULTS_DIR}/" | tee -a "$REPORT"
echo "Report: ${REPORT}" | tee -a "$REPORT"
echo "" 
echo "Done!"
