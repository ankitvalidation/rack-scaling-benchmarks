#!/bin/bash
#===============================================================================
# Supermicro FatTwin Comparison Test
#
# Replicates the exact Supermicro benchmark config for direct comparison:
#   - Cluster mode, 108 shards total (54/node × 2 nodes)
#   - memtier: --pipeline=8 --threads=64 --clients=1 --data-size=512
#   - Persistence: appendfsync everysec (local storage)
#   - Test all 3 workloads: 100% GET, 100% SET, 70/30 GET/SET
#
# Their result: 1.63M ops/sec peak (3:7 ratio, RAM hits, 10Gbps network)
# Our hardware: 200Gbps NICs, 160 cores/node, 320 cores total (vs 336 vCores)
#
# Also runs scaled version (multiple procs) to show full hardware potential
#===============================================================================
set +e

MEMTIER="/usr/local/bin/memtier_benchmark"
REDIS_CLI="/usr/local/bin/redis-cli"

# Servers: 104, 107 (2 nodes × 54 instances = 108 total)
# Clients: 101 (local), 102
SERVERS=(200.0.0.104 200.0.0.107)
CLIENT2="200.0.0.102"

# Match Supermicro params exactly
PIPELINE=8
DATA_SIZE=512
THREADS=64
CLIENTS_PER_THREAD=1
TEST_TIME=60
INST_PER_NODE=54   # 108 total shards (matching their 108 primary shards)

# Local persistence (fair comparison — they used local SSD)
DATA_DIR="/tmp/redis-bench-data"

RESULTS_DIR="/root/redis-scaling-test/results_supermicro_compare"
rm -rf "$RESULTS_DIR"
mkdir -p "$RESULTS_DIR"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
REPORT="${RESULTS_DIR}/report_${TIMESTAMP}.txt"

#===============================================================================
stop_all() {
    for node in "${SERVERS[@]}"; do
        ssh "$node" "pkill -9 redis-server 2>/dev/null; rm -rf /tmp/redis-cluster ${DATA_DIR}" 2>/dev/null &
    done
    pkill -9 memtier 2>/dev/null
    ssh "$CLIENT2" 'pkill -9 memtier 2>/dev/null' 2>/dev/null &
    wait; sleep 1
}

start_instances() {
    local NODE=$1 N=$2
    ssh "$NODE" "
        pkill -9 redis-server 2>/dev/null; sleep 0.5
        rm -rf /tmp/redis-cluster ${DATA_DIR}
        mkdir -p /tmp/redis-cluster ${DATA_DIR}
        for i in \$(seq 0 $((N-1))); do
            PORT=\$((7000 + i))
            mkdir -p /tmp/redis-cluster/\$PORT ${DATA_DIR}/\$PORT
            redis-server --port \$PORT --bind 0.0.0.0 --protected-mode no \
                --dir ${DATA_DIR}/\$PORT \
                --cluster-enabled yes --cluster-config-file /tmp/redis-cluster/\$PORT/nodes.conf \
                --cluster-node-timeout 5000 \
                --appendonly yes --appendfsync everysec --save '' \
                --maxclients 200000 --tcp-backlog 65535 --hz 100 \
                --daemonize yes 2>/dev/null
        done
        echo \"\$(pgrep -c redis-server) on \$(hostname -s)\"
    " 2>&1 | grep " on "
}

create_cluster() {
    echo "  Creating 108-shard cluster (54/node × 2 nodes)..."
    local CLUSTER_ARGS=""
    for node in "${SERVERS[@]}"; do
        for p in $(seq 0 $((INST_PER_NODE-1))); do
            CLUSTER_ARGS="${CLUSTER_ARGS} ${node}:$((7000+p))"
        done
    done
    $REDIS_CLI --cluster create $CLUSTER_ARGS --cluster-replicas 0 --cluster-yes 2>&1 | tail -3
    sleep 5
    # Wait for cluster to stabilize
    for i in $(seq 1 10); do
        local STATE=$($REDIS_CLI -h ${SERVERS[0]} -p 7000 cluster info 2>/dev/null | grep cluster_state | tr -d '\r')
        if [[ "$STATE" == *"ok"* ]]; then break; fi
        sleep 2
    done
    echo "  $($REDIS_CLI -h ${SERVERS[0]} -p 7000 cluster info 2>/dev/null | grep cluster_state | tr -d '\r')"
    echo "  $($REDIS_CLI -h ${SERVERS[0]} -p 7000 cluster info 2>/dev/null | grep cluster_known_nodes | tr -d '\r')"
}

run_single_proc() {
    local LABEL=$1
    local RATIO=$2
    local ENTRY=${SERVERS[0]}

    echo "  memtier: --pipeline=$PIPELINE --threads=$THREADS --clients=$CLIENTS_PER_THREAD --data-size=$DATA_SIZE --ratio=$RATIO --cluster-mode"
    echo "  Single process from local node (matching Supermicro exactly)..."

    $MEMTIER --server="$ENTRY" --port=7000 \
        --protocol=redis --cluster-mode \
        --threads=$THREADS --clients=$CLIENTS_PER_THREAD --pipeline=$PIPELINE \
        --data-size=$DATA_SIZE --ratio=$RATIO --test-time=$TEST_TIME \
        --key-minimum=1 --key-maximum=10000000 --key-pattern=R:R \
        --hide-histogram > "${RESULTS_DIR}/${LABEL}_single_${TIMESTAMP}.txt" 2>/dev/null

    local OPS=$(grep "^Totals" "${RESULTS_DIR}/${LABEL}_single_${TIMESTAMP}.txt" | awk '{print $2}')
    local P99=$(grep "^Totals" "${RESULTS_DIR}/${LABEL}_single_${TIMESTAMP}.txt" | awk '{print $7}')
    local AVG=$(grep "^Totals" "${RESULTS_DIR}/${LABEL}_single_${TIMESTAMP}.txt" | awk '{print $5}')
    local OPS_INT=$(printf "%.0f" "$OPS" 2>/dev/null || echo "0")
    echo "  >>> ${OPS_INT} ops/sec | avg: ${AVG} ms | p99: ${P99} ms"
    echo "${LABEL} (single proc): ${OPS_INT} ops/sec | avg: ${AVG} ms | p99: ${P99} ms" >> "$REPORT"
}

run_scaled() {
    local LABEL=$1
    local RATIO=$2
    local NUM_PROCS=$3
    local ENTRY=${SERVERS[0]}

    echo "  Scaled: ${NUM_PROCS} local + ${NUM_PROCS} on client2 × --pipeline=$PIPELINE --threads=$THREADS --clients=$CLIENTS_PER_THREAD"

    # Launch local procs
    local PIDS=()
    for p in $(seq 1 $NUM_PROCS); do
        $MEMTIER --server="$ENTRY" --port=7000 \
            --protocol=redis --cluster-mode \
            --threads=$THREADS --clients=$CLIENTS_PER_THREAD --pipeline=$PIPELINE \
            --data-size=$DATA_SIZE --ratio=$RATIO --test-time=$TEST_TIME \
            --key-minimum=1 --key-maximum=10000000 --key-pattern=R:R \
            --hide-histogram > "${RESULTS_DIR}/${LABEL}_scaled_p${p}_${TIMESTAMP}.txt" 2>/dev/null &
        PIDS+=($!)
    done

    # Fire-and-forget procs on client2
    ssh "$CLIENT2" "
        for p in \$(seq 1 $NUM_PROCS); do
            nohup memtier_benchmark --server=$ENTRY --port=7000 \
                --protocol=redis --cluster-mode \
                --threads=$THREADS --clients=$CLIENTS_PER_THREAD --pipeline=$PIPELINE \
                --data-size=$DATA_SIZE --ratio=$RATIO --test-time=$TEST_TIME \
                --key-minimum=1 --key-maximum=10000000 --key-pattern=R:R \
                --hide-histogram > /tmp/bench_scaled_\${p}.txt 2>/dev/null &
        done
    " 2>/dev/null

    echo "  Waiting (${NUM_PROCS} local + ${NUM_PROCS} on client2)..."
    for pid in "${PIDS[@]}"; do wait "$pid" 2>/dev/null || true; done
    sleep 15  # Allow client2 to finish

    # Collect client2 results
    ssh "$CLIENT2" "grep '^Totals' /tmp/bench_scaled_*.txt 2>/dev/null" 2>/dev/null | \
        grep -v "oneAPI\|::\|args:\|advisor\|compiler\|initialized\|setvars" > "${RESULTS_DIR}/${LABEL}_c2_totals_${TIMESTAMP}.txt" 2>/dev/null

    # Aggregate local
    local TOTAL_OPS=0 COUNT=0 TOTAL_P99=0
    for f in "${RESULTS_DIR}/${LABEL}_scaled_p"*"_${TIMESTAMP}.txt"; do
        local OPS=$(grep "^Totals" "$f" 2>/dev/null | awk '{print $2}')
        local P99=$(grep "^Totals" "$f" 2>/dev/null | awk '{print $7}')
        if [[ -n "$OPS" && "$OPS" != "0.00" ]]; then
            TOTAL_OPS=$(echo "$TOTAL_OPS + $OPS" | bc)
            TOTAL_P99=$(echo "$TOTAL_P99 + $P99" | bc 2>/dev/null || true)
            COUNT=$((COUNT+1))
        fi
    done
    # Add client2
    while IFS= read -r line; do
        local OPS=$(echo "$line" | awk '{print $2}')
        local P99=$(echo "$line" | awk '{print $7}')
        if [[ -n "$OPS" && "$OPS" != "0.00" ]]; then
            TOTAL_OPS=$(echo "$TOTAL_OPS + $OPS" | bc)
            TOTAL_P99=$(echo "$TOTAL_P99 + $P99" | bc 2>/dev/null || true)
            COUNT=$((COUNT+1))
        fi
    done < <(grep "Totals" "${RESULTS_DIR}/${LABEL}_c2_totals_${TIMESTAMP}.txt" 2>/dev/null | awk '{print $0}')

    if [[ $COUNT -gt 0 ]]; then
        local AVG_P99=$(echo "scale=2; $TOTAL_P99 / $COUNT" | bc)
        local OPS_INT=$(printf "%.0f" "$TOTAL_OPS")
        echo "  >>> ${OPS_INT} ops/sec | p99: ${AVG_P99} ms  [${COUNT} procs total]"
        echo "${LABEL} (scaled ${COUNT} procs): ${OPS_INT} ops/sec | p99: ${AVG_P99} ms" >> "$REPORT"
    else
        echo "  >>> ERROR: no results collected"
    fi

    ssh "$CLIENT2" 'rm -f /tmp/bench_scaled_*.txt' 2>/dev/null
}

#===============================================================================
echo "==============================================================================="
echo " SUPERMICRO FATTWIN COMPARISON TEST"
echo " $(date)"
echo ""
echo " Their config: 3 nodes (336 vCores), 108 shards, pipeline=8, 64T×1C, 512B"
echo "               Persistence: appendfsync everysec (local SSD)"
echo "               Network: 10 Gbps"
echo "               Result: 1.63M ops/sec peak (70/30 GET/SET)"
echo ""
echo " Our config:   2 nodes (320 cores), 108 shards, SAME memtier params"
echo "               Persistence: appendfsync everysec (local /tmp)"
echo "               Network: 200 Gbps"
echo "==============================================================================="

{
echo "Supermicro FatTwin Comparison — $(date)"
echo ""
echo "THEIR CONFIG:"
echo "  Platform: Supermicro X12 FatTwin, 3 nodes"
echo "  CPU: Dual Xeon Gold 6330N (112 vCores/node = 336 total)"
echo "  Network: 10 Gbps"
echo "  Shards: 108 primary + 108 replica"
echo "  memtier: pipeline=8, threads=64, clients=1, data=512B"
echo "  Persistence: appendfsync everysec (local SSD)"
echo "  Peak: 1,630,000 ops/sec (70/30 GET/SET)"
echo ""
echo "OUR CONFIG:"
echo "  Platform: 160-core nodes × 2 (320 cores total)"
echo "  Network: 200 Gbps (20× theirs)"
echo "  Shards: 108 (54/node × 2 nodes, no replicas)"
echo "  memtier: SAME params (pipeline=8, threads=64, clients=1, data=512B)"
echo "  Persistence: appendfsync everysec (local storage)"
echo ""
echo "RESULTS:"
} > "$REPORT"

#-------------------------------------------------------------------------------
echo ""
echo "=== Setting up: 2 nodes × 54 instances = 108 cluster shards ==="
stop_all
sleep 2

for node in "${SERVERS[@]}"; do
    start_instances "$node" "$INST_PER_NODE"
done
sleep 3

create_cluster
sleep 3

#-------------------------------------------------------------------------------
echo ""
echo "=========================================="
echo " TEST 1: Single Process (Exact Supermicro Match)"
echo "=========================================="
echo "" >> "$REPORT"
echo "=== SINGLE PROCESS (exact Supermicro match) ===" >> "$REPORT"

echo ""
echo "--- 70/30 GET/SET (ratio=3:7) — their peak test ---"
run_single_proc "70_30_mix" "3:7"

echo ""
echo "--- 100% GET (ratio=0:1) ---"
run_single_proc "100_get" "0:1"

echo ""
echo "--- 100% SET (ratio=1:0) ---"
run_single_proc "100_set" "1:0"

#-------------------------------------------------------------------------------
echo ""
echo "=========================================="
echo " TEST 2: Scaled (full hardware potential)"
echo "         Same params, 3 procs each on 2 client nodes = 6 total"
echo "=========================================="
echo "" >> "$REPORT"
echo "=== SCALED (6 procs total, 2 clients) ===" >> "$REPORT"

echo ""
echo "--- 70/30 GET/SET (ratio=3:7) — scaled ---"
run_scaled "70_30_mix" "3:7" 3

echo ""
echo "--- 100% GET (ratio=0:1) — scaled ---"
run_scaled "100_get" "0:1" 3

echo ""
echo "--- 100% SET (ratio=1:0) — scaled ---"
run_scaled "100_set" "1:0" 3

#-------------------------------------------------------------------------------
stop_all

echo ""
echo "==============================================================================="
echo " COMPARISON COMPLETE — $(date)"
echo ""
echo "--- HEAD-TO-HEAD RESULTS ---"
cat "$REPORT"
echo ""
echo " Full report: ${REPORT}"
echo "==============================================================================="
