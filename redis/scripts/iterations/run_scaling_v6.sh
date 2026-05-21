#!/bin/bash
#===============================================================================
# Redis Scaling Benchmark v6 — Standalone Instances (No Cluster Mode)
#
# Shows horizontal + vertical scaling using independent Redis instances.
# Each instance is standalone → no cluster topology discovery overhead.
# Client runs one memtier per server-node → results summed.
#
# Architecture:
#   Client:  200.0.0.101 (160 cores)
#   Servers: 200.0.0.103, 200.0.0.104, 200.0.0.107, 200.0.0.102
#
# Tests:
#   1. Node Scaling: 1→4 nodes, 32 instances/node
#   2. Density Scaling: 3 nodes, 1→160 instances/node
#===============================================================================
set +e

MEMTIER="/usr/local/bin/memtier_benchmark"
ALL_SERVERS=(200.0.0.103 200.0.0.104 200.0.0.107 200.0.0.102)

# Memtier parameters
PIPELINE=20
DATA_SIZE=256
RATIO="1:1"
TEST_TIME=60

RESULTS_DIR="/root/redis-scaling-test/results_v6"
mkdir -p "$RESULTS_DIR"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
REPORT="${RESULTS_DIR}/report_${TIMESTAMP}.txt"

#===============================================================================
# Functions
#===============================================================================

stop_all_redis() {
    for node in "${ALL_SERVERS[@]}"; do
        ssh "$node" 'pkill -9 redis-server 2>/dev/null; rm -rf /tmp/redis-run' 2>/dev/null &
    done
    wait; sleep 1
}

start_instances() {
    # Start N standalone Redis instances on a node (no cluster)
    local NODE=$1
    local N=$2
    ssh "$NODE" "
        rm -rf /tmp/redis-run; mkdir -p /tmp/redis-run
        for i in \$(seq 0 $((N-1))); do
            PORT=\$((7000 + \$i))
            mkdir -p /tmp/redis-run/\$PORT
            redis-server --port \$PORT --bind 0.0.0.0 --protected-mode no \
                --dir /tmp/redis-run/\$PORT \
                --appendonly no --save '' --maxclients 200000 \
                --daemonize yes 2>/dev/null
        done
        sleep 1
        echo \"\$(pgrep -c redis-server) running on \$(hostname -s)\"
    " 2>&1 | grep "running on"
}

run_benchmark() {
    # Run memtier against each server node (one process per node)
    # Each process drives all instances on that node via port range
    local LABEL=$1
    shift
    local NODES=("$@")
    local NUM_NODES=${#NODES[@]}
    
    # Determine threads/clients per memtier process
    # With 160 cores on client, split evenly
    local THREADS_PER_PROC=$((160 / NUM_NODES))
    [[ $THREADS_PER_PROC -gt 50 ]] && THREADS_PER_PROC=50
    [[ $THREADS_PER_PROC -lt 8 ]] && THREADS_PER_PROC=8
    local CLIENTS=20

    echo "  Benchmark: ${NUM_NODES} memtier procs × ${THREADS_PER_PROC} threads × ${CLIENTS} clients, pipeline=${PIPELINE}"
    echo "  Total connections: $((NUM_NODES * THREADS_PER_PROC * CLIENTS))"
    
    local PIDS=()
    local P=0
    for node in "${NODES[@]}"; do
        P=$((P+1))
        local OUTFILE="${RESULTS_DIR}/${LABEL}_n${P}_${TIMESTAMP}.txt"
        # Connect to port 7000 on this node (memtier will only hit this one instance)
        # For multi-instance per node: run multiple memtier processes per node
        $MEMTIER \
            --server="$node" --port=7000 \
            --protocol=redis \
            --threads="$THREADS_PER_PROC" --clients="$CLIENTS" \
            --pipeline="$PIPELINE" --data-size="$DATA_SIZE" --ratio="$RATIO" \
            --test-time="$TEST_TIME" \
            --key-minimum=1 --key-maximum=10000000 --key-pattern=R:R \
            --hide-histogram \
            > "$OUTFILE" 2>/dev/null &
        PIDS+=($!)
    done
    
    for pid in "${PIDS[@]}"; do wait "$pid" 2>/dev/null || true; done
    
    # Aggregate
    local TOTAL_OPS=0; local TOTAL_P99=0; local COUNT=0
    for f in "${RESULTS_DIR}/${LABEL}_n"*"_${TIMESTAMP}.txt"; do
        local OPS=$(grep "^Totals" "$f" 2>/dev/null | awk '{print $2}')
        local P99=$(grep "^Totals" "$f" 2>/dev/null | awk '{print $7}')
        if [[ -n "$OPS" && "$OPS" != "0.00" ]]; then
            TOTAL_OPS=$(echo "$TOTAL_OPS + $OPS" | bc)
            TOTAL_P99=$(echo "$TOTAL_P99 + $P99" | bc)
            COUNT=$((COUNT+1))
        fi
    done
    
    if [[ $COUNT -gt 0 ]]; then
        local AVG_P99=$(echo "scale=2; $TOTAL_P99 / $COUNT" | bc)
        local OPS_NICE=$(printf "%'.0f" "$TOTAL_OPS" 2>/dev/null || echo "$TOTAL_OPS")
        echo "  >>> ${OPS_NICE} ops/sec | p99: ${AVG_P99} ms  [${COUNT} nodes]"
        echo "${LABEL}: ${OPS_NICE} ops/sec | p99: ${AVG_P99} ms  [${COUNT} nodes]" >> "$REPORT"
    else
        echo "  >>> ERROR: 0 results"
        echo "${LABEL}: ERROR" >> "$REPORT"
    fi
}

run_benchmark_multi_instance() {
    # For density tests: run one memtier per INSTANCE (not per node)
    # to actually saturate all instances on the node
    local LABEL=$1
    local INST_PER_NODE=$2
    shift 2
    local NODES=("$@")
    local NUM_NODES=${#NODES[@]}
    local TOTAL_INST=$((NUM_NODES * INST_PER_NODE))
    
    # Scale memtier processes: one per node, but with enough threads
    # Each memtier targets ONE port, so we need INST_PER_NODE × NUM_NODES processes
    # But that's too many for high density. Cap at reasonable number.
    # Strategy: run min(TOTAL_INST, 20) memtier processes, distributed across instances
    local MAX_PROCS=20
    local PROCS_PER_NODE=$INST_PER_NODE
    [[ $PROCS_PER_NODE -gt $((MAX_PROCS / NUM_NODES)) ]] && PROCS_PER_NODE=$((MAX_PROCS / NUM_NODES))
    [[ $PROCS_PER_NODE -lt 1 ]] && PROCS_PER_NODE=1
    
    local TOTAL_PROCS=$((PROCS_PER_NODE * NUM_NODES))
    # Distribute client threads across processes
    local THREADS_PER_PROC=$((150 / TOTAL_PROCS))
    [[ $THREADS_PER_PROC -gt 32 ]] && THREADS_PER_PROC=32
    [[ $THREADS_PER_PROC -lt 2 ]] && THREADS_PER_PROC=2
    local CLIENTS=20

    echo "  Benchmark: ${TOTAL_PROCS} procs (${PROCS_PER_NODE}/node) × ${THREADS_PER_PROC}T × ${CLIENTS}C, pipeline=${PIPELINE}"
    
    local PIDS=()
    local P=0
    for node in "${NODES[@]}"; do
        # Spread processes across ports on this node
        local PORT_STEP=$((INST_PER_NODE / PROCS_PER_NODE))
        [[ $PORT_STEP -lt 1 ]] && PORT_STEP=1
        for j in $(seq 0 $((PROCS_PER_NODE - 1))); do
            P=$((P+1))
            local PORT=$((7000 + j * PORT_STEP))
            local OUTFILE="${RESULTS_DIR}/${LABEL}_p${P}_${TIMESTAMP}.txt"
            $MEMTIER \
                --server="$node" --port="$PORT" \
                --protocol=redis \
                --threads="$THREADS_PER_PROC" --clients="$CLIENTS" \
                --pipeline="$PIPELINE" --data-size="$DATA_SIZE" --ratio="$RATIO" \
                --test-time="$TEST_TIME" \
                --key-minimum=1 --key-maximum=10000000 --key-pattern=R:R \
                --hide-histogram \
                > "$OUTFILE" 2>/dev/null &
            PIDS+=($!)
        done
    done
    
    for pid in "${PIDS[@]}"; do wait "$pid" 2>/dev/null || true; done
    
    # Aggregate
    local TOTAL_OPS=0; local TOTAL_P99=0; local COUNT=0
    for f in "${RESULTS_DIR}/${LABEL}_p"*"_${TIMESTAMP}.txt"; do
        local OPS=$(grep "^Totals" "$f" 2>/dev/null | awk '{print $2}')
        local P99=$(grep "^Totals" "$f" 2>/dev/null | awk '{print $7}')
        if [[ -n "$OPS" && "$OPS" != "0.00" ]]; then
            TOTAL_OPS=$(echo "$TOTAL_OPS + $OPS" | bc)
            TOTAL_P99=$(echo "$TOTAL_P99 + $P99" | bc)
            COUNT=$((COUNT+1))
        fi
    done
    
    if [[ $COUNT -gt 0 ]]; then
        local AVG_P99=$(echo "scale=2; $TOTAL_P99 / $COUNT" | bc)
        local OPS_NICE=$(printf "%'.0f" "$TOTAL_OPS" 2>/dev/null || echo "$TOTAL_OPS")
        echo "  >>> ${OPS_NICE} ops/sec | p99: ${AVG_P99} ms  [${COUNT} procs]"
        echo "${LABEL}: ${OPS_NICE} ops/sec | p99: ${AVG_P99} ms  [${COUNT}/${TOTAL_PROCS} procs]" >> "$REPORT"
    else
        echo "  >>> ERROR: 0 results"
        echo "${LABEL}: ERROR" >> "$REPORT"
    fi
}

#===============================================================================
# Main
#===============================================================================
echo "==============================================================================="
echo " Redis Scaling Benchmark v6 (Standalone Instances)"
echo " $(date)"
echo " Client: 200.0.0.101 (160 cores)"  
echo " Servers: ${ALL_SERVERS[*]}"
echo " Params: pipeline=${PIPELINE}, data=${DATA_SIZE}B, ratio=${RATIO}, time=${TEST_TIME}s"
echo "==============================================================================="

{
echo "Redis Scaling Benchmark v6 — $(date)"
echo "Params: pipeline=${PIPELINE}, data=${DATA_SIZE}B, ratio=${RATIO}, time=${TEST_TIME}s"
echo ""
} > "$REPORT"

#-------------------------------------------------------------------------------
# TEST 1: Node Scaling — 32 instances per node, 1→4 nodes
#-------------------------------------------------------------------------------
echo ""
echo "======= TEST 1: NODE SCALING (32 instances/node) ======="
echo "" >> "$REPORT"
echo "=== TEST 1: NODE SCALING (32 instances/node) ===" >> "$REPORT"

for NUM_NODES in 1 2 3 4; do
    SERVERS=("${ALL_SERVERS[@]:0:$NUM_NODES}")
    echo ""
    echo "--- ${NUM_NODES} node(s) × 32 instances = $((NUM_NODES*32)) total ---"
    
    stop_all_redis
    for node in "${SERVERS[@]}"; do
        start_instances "$node" 32
    done
    sleep 2
    
    run_benchmark_multi_instance "T1_${NUM_NODES}nodes_32inst" 32 "${SERVERS[@]}"
done

#-------------------------------------------------------------------------------
# TEST 2: Density Scaling — 3 nodes, 1→160 instances/node
#-------------------------------------------------------------------------------
echo ""
echo "======= TEST 2: DENSITY SCALING (3 nodes, variable instances) ======="
echo "" >> "$REPORT"
echo "=== TEST 2: DENSITY SCALING (3 nodes) ===" >> "$REPORT"

DENSITY_SERVERS=("${ALL_SERVERS[@]:0:3}")

for INST in 1 4 8 16 32 64 128 160; do
    echo ""
    echo "--- 3 nodes × ${INST} instances = $((3*INST)) total ---"
    
    stop_all_redis
    for node in "${DENSITY_SERVERS[@]}"; do
        start_instances "$node" "$INST"
    done
    sleep 2
    
    run_benchmark_multi_instance "T2_3nodes_${INST}inst" "$INST" "${DENSITY_SERVERS[@]}"
done

#-------------------------------------------------------------------------------
# Cleanup
#-------------------------------------------------------------------------------
stop_all_redis

echo ""
echo "==============================================================================="
echo " COMPLETE — Results in: $REPORT"
echo "==============================================================================="
cat "$REPORT"
