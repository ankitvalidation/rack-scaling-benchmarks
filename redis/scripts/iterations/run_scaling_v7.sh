#!/bin/bash
#===============================================================================
# Redis Scaling Benchmark v7 — Dual-Client, Standalone Instances
#
# Uses TWO client machines (101 + 102) to avoid single-client bottleneck.
# Each server node runs standalone Redis instances (no cluster overhead).
# Results from both clients are summed.
#
# Architecture:
#   Clients: 200.0.0.101 (local), 200.0.0.102 (remote)  — 320 cores total
#   Servers: 200.0.0.103, 200.0.0.104, 200.0.0.107
#
# Tests:
#   1. Node Scaling: 1→3 server nodes, 32 instances/node, both clients
#   2. Density Scaling: 3 nodes, 1→160 instances/node
#===============================================================================
set +e

MEMTIER="/usr/local/bin/memtier_benchmark"
CLIENT2="200.0.0.102"
SERVERS=(200.0.0.103 200.0.0.104 200.0.0.107)

# Parameters — 256B data, pipeline=20, 1:1 ratio (matching prior benchmarks)
PIPELINE=20
DATA_SIZE=256
RATIO="1:1"
TEST_TIME=60

RESULTS_DIR="/root/redis-scaling-test/results_v7"
mkdir -p "$RESULTS_DIR"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
REPORT="${RESULTS_DIR}/report_${TIMESTAMP}.txt"

#===============================================================================
stop_all() {
    for node in "${SERVERS[@]}"; do
        ssh "$node" 'pkill -9 redis-server 2>/dev/null; rm -rf /tmp/redis-run' 2>/dev/null &
    done
    pkill -9 memtier 2>/dev/null
    ssh "$CLIENT2" 'pkill -9 memtier 2>/dev/null' 2>/dev/null &
    wait; sleep 1
}

start_instances() {
    local NODE=$1 N=$2
    ssh "$NODE" "
        rm -rf /tmp/redis-run; mkdir -p /tmp/redis-run
        for i in \$(seq 0 $((N-1))); do
            PORT=\$((7000 + \$i))
            mkdir -p /tmp/redis-run/\$PORT
            redis-server --port \$PORT --bind 0.0.0.0 --protected-mode no \
                --dir /tmp/redis-run/\$PORT \
                --appendonly no --save '' --maxclients 200000 --daemonize yes 2>/dev/null
        done
        echo \"\$(pgrep -c redis-server) on \$(hostname -s)\"
    " 2>&1 | grep " on "
}

run_test() {
    # Run memtier from BOTH clients, targeting all server nodes
    # Each client runs PROCS_PER_NODE processes per server node
    local LABEL=$1
    local INST_PER_NODE=$2
    shift 2
    local NODES=("$@")
    local NUM_NODES=${#NODES[@]}
    local TOTAL_INST=$((NUM_NODES * INST_PER_NODE))
    
    # Determine how many memtier procs per client per node
    # Each memtier targets one port. We run multiple to cover more instances.
    # Cap procs per client: use enough to saturate but not too many
    local PROCS_PER_CLIENT_PER_NODE=5
    if [[ $INST_PER_NODE -le 4 ]]; then
        PROCS_PER_CLIENT_PER_NODE=$INST_PER_NODE
    elif [[ $INST_PER_NODE -le 8 ]]; then
        PROCS_PER_CLIENT_PER_NODE=4
    fi
    
    local TOTAL_PROCS_PER_CLIENT=$((PROCS_PER_CLIENT_PER_NODE * NUM_NODES))
    local THREADS=16
    local CLIENTS=25

    echo "  Config: 2 clients × ${TOTAL_PROCS_PER_CLIENT} procs × ${THREADS}T × ${CLIENTS}C"
    echo "  Total connections: $((2 * TOTAL_PROCS_PER_CLIENT * THREADS * CLIENTS))"
    
    # Start LOCAL memtier processes (client 101)
    local PIDS=()
    local P=0
    for node in "${NODES[@]}"; do
        local PORT_STEP=$((INST_PER_NODE / PROCS_PER_CLIENT_PER_NODE))
        [[ $PORT_STEP -lt 1 ]] && PORT_STEP=1
        for j in $(seq 0 $((PROCS_PER_CLIENT_PER_NODE - 1))); do
            P=$((P+1))
            local PORT=$((7000 + j * PORT_STEP))
            $MEMTIER --server="$node" --port="$PORT" --protocol=redis \
                --threads="$THREADS" --clients="$CLIENTS" --pipeline="$PIPELINE" \
                --data-size="$DATA_SIZE" --ratio="$RATIO" --test-time="$TEST_TIME" \
                --key-minimum=1 --key-maximum=10000000 --key-pattern=R:R \
                --hide-histogram > "${RESULTS_DIR}/${LABEL}_c1_p${P}_${TIMESTAMP}.txt" 2>/dev/null &
            PIDS+=($!)
        done
    done
    
    # Start REMOTE memtier processes (client 102)
    P=0
    for node in "${NODES[@]}"; do
        local PORT_STEP=$((INST_PER_NODE / PROCS_PER_CLIENT_PER_NODE))
        [[ $PORT_STEP -lt 1 ]] && PORT_STEP=1
        for j in $(seq 0 $((PROCS_PER_CLIENT_PER_NODE - 1))); do
            P=$((P+1))
            local PORT=$((7000 + j * PORT_STEP + PORT_STEP/2))
            [[ $PORT -ge $((7000 + INST_PER_NODE)) ]] && PORT=$((7000 + INST_PER_NODE - 1))
            # Run memtier on client2 via SSH, save output remotely
            ssh "$CLIENT2" "
                memtier_benchmark --server=$node --port=$PORT --protocol=redis \
                    --threads=$THREADS --clients=$CLIENTS --pipeline=$PIPELINE \
                    --data-size=$DATA_SIZE --ratio=$RATIO --test-time=$TEST_TIME \
                    --key-minimum=1 --key-maximum=10000000 --key-pattern=R:R \
                    --hide-histogram 2>/dev/null
            " > "${RESULTS_DIR}/${LABEL}_c2_p${P}_${TIMESTAMP}.txt" 2>/dev/null &
            PIDS+=($!)
        done
    done
    
    echo "  Waiting for ${#PIDS[@]} memtier processes (${TEST_TIME}s + overhead)..."
    for pid in "${PIDS[@]}"; do wait "$pid" 2>/dev/null || true; done
    
    # Aggregate ALL results
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
        local OPS_NICE=$(printf "%'.0f" "$TOTAL_OPS" 2>/dev/null || echo "$TOTAL_OPS")
        echo "  >>> ${OPS_NICE} ops/sec | p99: ${AVG_P99} ms  [${COUNT} procs]"
        echo "${LABEL} | ${OPS_NICE} ops/sec | p99: ${AVG_P99} ms | ${COUNT} procs" >> "$REPORT"
    else
        echo "  >>> ERROR: no valid results"
        echo "${LABEL} | ERROR" >> "$REPORT"
    fi
}

#===============================================================================
echo "==============================================================================="
echo " Redis Scaling Benchmark v7 — Dual-Client"
echo " $(date)"
echo " Clients: 200.0.0.101 + 200.0.0.102 (160 cores each)"
echo " Servers: ${SERVERS[*]}"
echo " Params: pipeline=${PIPELINE}, data=${DATA_SIZE}B, ratio=${RATIO}, time=${TEST_TIME}s"
echo "==============================================================================="

{
echo "Redis Scaling v7 — $(date)"
echo "Clients: 101+102 (160 cores each), Servers: 103,104,107"
echo "Params: pipeline=${PIPELINE}, data=${DATA_SIZE}B, ratio=${RATIO}, time=${TEST_TIME}s"
echo ""
} > "$REPORT"

#-------------------------------------------------------------------------------
echo ""
echo "======= TEST 1: NODE SCALING (32 instances/node) ======="
echo "=== TEST 1: NODE SCALING (32 inst/node) ===" >> "$REPORT"

for NUM_NODES in 1 2 3; do
    ACTIVE_SERVERS=("${SERVERS[@]:0:$NUM_NODES}")
    echo ""
    echo "--- ${NUM_NODES} node(s) × 32 instances = $((NUM_NODES*32)) total ---"
    
    stop_all
    for node in "${ACTIVE_SERVERS[@]}"; do
        start_instances "$node" 32
    done
    sleep 2
    
    run_test "T1_${NUM_NODES}n_32i" 32 "${ACTIVE_SERVERS[@]}"
done

#-------------------------------------------------------------------------------
echo ""
echo "======= TEST 2: DENSITY SCALING (3 nodes) ======="
echo "" >> "$REPORT"
echo "=== TEST 2: DENSITY (3 nodes, variable inst) ===" >> "$REPORT"

for INST in 1 4 8 16 32 64 128 160; do
    echo ""
    echo "--- 3 nodes × ${INST} instances = $((3*INST)) total ---"
    
    stop_all
    for node in "${SERVERS[@]}"; do
        start_instances "$node" "$INST"
    done
    sleep 2
    
    run_test "T2_3n_${INST}i" "$INST" "${SERVERS[@]}"
done

#-------------------------------------------------------------------------------
stop_all

echo ""
echo "==============================================================================="
echo " COMPLETE"
echo "==============================================================================="
echo ""
cat "$REPORT"
echo ""
echo "Full results: $RESULTS_DIR"
