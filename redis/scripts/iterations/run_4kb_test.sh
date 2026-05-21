#!/bin/bash
#===============================================================================
# Redis 4KB Block Size Test — Network Saturation + CPU Measurement
#
# Based on v8 (best config: 96 inst/node, dual-NIC, 2 clients, 3 servers)
# Change: --data-size=4096 (4KB) instead of 256B
# Added: mpstat collection on ALL nodes during benchmark
#===============================================================================
set +e

MEMTIER="/usr/local/bin/memtier_benchmark"

# Dual-NIC server addresses (node 103 is DOWN)
SERVERS_NIC1=(200.0.0.104 200.0.0.107)
SERVERS_NIC2=(220.0.0.104 220.0.0.107)
ALL_NODES=(200.0.0.101 200.0.0.102 200.0.0.104 200.0.0.107)

# Client 2 addresses (for SSH)
CLIENT2_NIC1="200.0.0.102"

# Parameters
PIPELINE=50
DATA_SIZE=4096
RATIO="1:1"
TEST_TIME=60
INST_PER_NODE=16
IO_THREADS=8

RESULTS_DIR="/root/redis-scaling-test/results_4kb"
mkdir -p "$RESULTS_DIR"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
REPORT="${RESULTS_DIR}/report_${TIMESTAMP}.txt"

#===============================================================================
stop_all() {
    for node in "${SERVERS_NIC1[@]}"; do
        ssh "$node" 'pkill -9 redis-server 2>/dev/null; rm -rf /tmp/redis-run' 2>/dev/null &
    done
    pkill -9 memtier 2>/dev/null
    ssh "$CLIENT2_NIC1" 'pkill -9 memtier 2>/dev/null' 2>/dev/null &
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
                --appendonly no --save '' --maxclients 200000 \
                --tcp-backlog 65535 --hz 100 \
                --io-threads ${IO_THREADS} --io-threads-do-reads yes \
                --daemonize yes 2>/dev/null
        done
        echo \"\$(pgrep -c redis-server) on \$(hostname -s)\"
    " 2>&1 | grep " on "
}

start_cpu_monitoring() {
    echo "  Starting CPU monitoring on all nodes..."
    for node in "${ALL_NODES[@]}"; do
        local label=$(echo "$node" | awk -F. '{print $4}')
        ssh "$node" "mpstat -P ALL 5 20 > /tmp/cpu_bench.txt 2>/dev/null &" &
    done
    wait
    echo "  mpstat running (5s interval, 20 samples = 100s coverage)"
}

stop_cpu_monitoring() {
    echo "  Collecting CPU data from all nodes..."
    for node in "${ALL_NODES[@]}"; do
        local label=$(echo "$node" | awk -F. '{print $4}')
        ssh "$node" 'pkill -f "mpstat" 2>/dev/null; sleep 1'
        scp "${node}:/tmp/cpu_bench.txt" "${RESULTS_DIR}/cpu_node${label}_${TIMESTAMP}.txt" 2>/dev/null
    done
}

summarize_cpu() {
    echo ""
    echo "=== CPU Utilization Summary ==="
    echo "=== CPU Utilization Summary ===" >> "$REPORT"
    for node in "${ALL_NODES[@]}"; do
        local label=$(echo "$node" | awk -F. '{print $4}')
        local f="${RESULTS_DIR}/cpu_node${label}_${TIMESTAMP}.txt"
        if [[ -f "$f" ]]; then
            # Get average across all "all" (aggregate) lines, skip the first sample
            local avg_usr=$(grep "     all" "$f" | tail -n +2 | awk '{sum+=$4; n++} END{if(n>0) printf "%.1f", sum/n; else print "N/A"}')
            local avg_sys=$(grep "     all" "$f" | tail -n +2 | awk '{sum+=$6; n++} END{if(n>0) printf "%.1f", sum/n; else print "N/A"}')
            local avg_idle=$(grep "     all" "$f" | tail -n +2 | awk '{sum+=$13; n++} END{if(n>0) printf "%.1f", sum/n; else print "N/A"}')
            local avg_softirq=$(grep "     all" "$f" | tail -n +2 | awk '{sum+=$9; n++} END{if(n>0) printf "%.1f", sum/n; else print "N/A"}')
            local total_used=$(echo "100 - $avg_idle" | bc 2>/dev/null || echo "N/A")
            echo "  Node ${label}: ${total_used}% used (usr=${avg_usr}% sys=${avg_sys}% softirq=${avg_softirq}% idle=${avg_idle}%)"
            echo "  Node ${label}: ${total_used}% used (usr=${avg_usr}% sys=${avg_sys}% softirq=${avg_softirq}% idle=${avg_idle}%)" >> "$REPORT"
        else
            echo "  Node ${label}: NO DATA"
        fi
    done
}

#===============================================================================
echo "==============================================================================="
echo " Redis 4KB Block Size Test — Network Saturation"
echo " $(date)"
echo " Clients: 101 + 102 (both NICs: 200.0.0.x + 220.0.0.x)"
echo " Servers: 104, 107 (both NICs) — node 103 DOWN"
echo " Config: ${INST_PER_NODE} inst/node, pipeline=${PIPELINE}, data=${DATA_SIZE}B, ratio=${RATIO}"
echo " Duration: ${TEST_TIME}s"
echo "==============================================================================="

{
echo "Redis 4KB Block Size Test — $(date)"
echo "Clients: 101+102 (dual-NIC: 200.0.0.x + 220.0.0.x)"
echo "Servers: 104, 107 (dual-NIC) — node 103 DOWN"
echo "Config: ${INST_PER_NODE} inst/node, pipeline=${PIPELINE}, data=${DATA_SIZE}B, ratio=${RATIO}"
echo ""
} > "$REPORT"

#-------------------------------------------------------------------------------
echo ""
echo "=== Starting Redis instances: 2 nodes × ${INST_PER_NODE} = $((2*INST_PER_NODE)) total ==="

stop_all
for node in "${SERVERS_NIC1[@]}"; do
    start_instances "$node" "$INST_PER_NODE"
done
sleep 2

#-------------------------------------------------------------------------------
echo ""
echo "=== Running 4KB benchmark (${INST_PER_NODE} inst/node, dual-NIC, 2 clients) ==="

# Start CPU monitoring BEFORE benchmark
start_cpu_monitoring

sleep 2

# Launch memtier — 3× more procs than v8 to saturate 4KB
PROCS_PER_NIC=8
THREADS=16
CLIENTS=25
TOTAL_PROCS=$((PROCS_PER_NIC * 2 * 2 * 2))  # per_nic × 2nics × 2clients × 2servers
TOTAL_CONNS=$((TOTAL_PROCS * THREADS * CLIENTS))

echo "  Config: 2 clients × 2 NICs × ${PROCS_PER_NIC} procs/nic/server × 2 servers = ${TOTAL_PROCS} procs"
echo "  Connections: ${TOTAL_CONNS} | Threads: ${THREADS} | Clients/thread: ${CLIENTS}"
echo "  Data size: ${DATA_SIZE} bytes (4KB) | Pipeline: ${PIPELINE}"

PIDS=()
P=0

for srv_idx in 0 1 2; do
    SRV_NIC1="${SERVERS_NIC1[$srv_idx]}"
    SRV_NIC2="${SERVERS_NIC2[$srv_idx]}"

    PORT_STEP=$((INST_PER_NODE / PROCS_PER_NIC))
    [[ $PORT_STEP -lt 1 ]] && PORT_STEP=1

    # --- CLIENT 1 (local) → NIC1 ---
    for j in $(seq 0 $((PROCS_PER_NIC - 1))); do
        P=$((P+1))
        PORT=$((7000 + j * PORT_STEP))
        [[ $PORT -ge $((7000 + INST_PER_NODE)) ]] && PORT=$((7000 + INST_PER_NODE - 1))
        $MEMTIER --server="$SRV_NIC1" --port="$PORT" --protocol=redis \
            --threads="$THREADS" --clients="$CLIENTS" --pipeline="$PIPELINE" \
            --data-size="$DATA_SIZE" --ratio="$RATIO" --test-time="$TEST_TIME" \
            --key-minimum=1 --key-maximum=10000000 --key-pattern=R:R \
            --hide-histogram > "${RESULTS_DIR}/4kb_c1n1_p${P}_${TIMESTAMP}.txt" 2>/dev/null &
        PIDS+=($!)
    done

    # --- CLIENT 1 (local) → NIC2 ---
    for j in $(seq 0 $((PROCS_PER_NIC - 1))); do
        P=$((P+1))
        PORT=$((7000 + j * PORT_STEP + PORT_STEP/2))
        [[ $PORT -ge $((7000 + INST_PER_NODE)) ]] && PORT=$((7000 + INST_PER_NODE - 1))
        $MEMTIER --server="$SRV_NIC2" --port="$PORT" --protocol=redis \
            --threads="$THREADS" --clients="$CLIENTS" --pipeline="$PIPELINE" \
            --data-size="$DATA_SIZE" --ratio="$RATIO" --test-time="$TEST_TIME" \
            --key-minimum=1 --key-maximum=10000000 --key-pattern=R:R \
            --hide-histogram > "${RESULTS_DIR}/4kb_c1n2_p${P}_${TIMESTAMP}.txt" 2>/dev/null &
        PIDS+=($!)
    done

    # --- CLIENT 2 (remote) → NIC1 ---
    for j in $(seq 0 $((PROCS_PER_NIC - 1))); do
        P=$((P+1))
        PORT=$((7000 + j * PORT_STEP + PORT_STEP/4))
        [[ $PORT -ge $((7000 + INST_PER_NODE)) ]] && PORT=$((7000 + INST_PER_NODE - 1))
        ssh "$CLIENT2_NIC1" "
            memtier_benchmark --server=$SRV_NIC1 --port=$PORT --protocol=redis \
                --threads=$THREADS --clients=$CLIENTS --pipeline=$PIPELINE \
                --data-size=$DATA_SIZE --ratio=$RATIO --test-time=$TEST_TIME \
                --key-minimum=1 --key-maximum=10000000 --key-pattern=R:R \
                --hide-histogram 2>/dev/null
        " > "${RESULTS_DIR}/4kb_c2n1_p${P}_${TIMESTAMP}.txt" 2>/dev/null &
        PIDS+=($!)
    done

    # --- CLIENT 2 (remote) → NIC2 ---
    for j in $(seq 0 $((PROCS_PER_NIC - 1))); do
        P=$((P+1))
        PORT=$((7000 + j * PORT_STEP + 3*PORT_STEP/4))
        [[ $PORT -ge $((7000 + INST_PER_NODE)) ]] && PORT=$((7000 + INST_PER_NODE - 1))
        ssh "$CLIENT2_NIC1" "
            memtier_benchmark --server=$SRV_NIC2 --port=$PORT --protocol=redis \
                --threads=$THREADS --clients=$CLIENTS --pipeline=$PIPELINE \
                --data-size=$DATA_SIZE --ratio=$RATIO --test-time=$TEST_TIME \
                --key-minimum=1 --key-maximum=10000000 --key-pattern=R:R \
                --hide-histogram 2>/dev/null
        " > "${RESULTS_DIR}/4kb_c2n2_p${P}_${TIMESTAMP}.txt" 2>/dev/null &
        PIDS+=($!)
    done
done

echo "  Launched ${#PIDS[@]} memtier processes, waiting ${TEST_TIME}s + overhead..."
for pid in "${PIDS[@]}"; do wait "$pid" 2>/dev/null || true; done
echo "  Benchmark complete."

#-------------------------------------------------------------------------------
# Stop CPU monitoring and collect
sleep 2
stop_cpu_monitoring

#-------------------------------------------------------------------------------
# Aggregate results
echo ""
echo "=== Results ==="
echo "=== Results ===" >> "$REPORT"

TOTAL_OPS=0
TOTAL_P99=0
TOTAL_BW=0
COUNT=0

for f in "${RESULTS_DIR}/4kb_c"*"_${TIMESTAMP}.txt"; do
    OPS=$(grep "^Totals" "$f" 2>/dev/null | awk '{print $2}')
    P99=$(grep "^Totals" "$f" 2>/dev/null | awk '{print $7}')
    BW=$(grep "^Totals" "$f" 2>/dev/null | awk '{print $8}')
    if [[ -n "$OPS" && "$OPS" != "0.00" ]]; then
        TOTAL_OPS=$(echo "$TOTAL_OPS + $OPS" | bc)
        TOTAL_P99=$(echo "$TOTAL_P99 + $P99" | bc 2>/dev/null || echo "$TOTAL_P99")
        TOTAL_BW=$(echo "$TOTAL_BW + $BW" | bc 2>/dev/null || echo "$TOTAL_BW")
        COUNT=$((COUNT+1))
    fi
done

if [[ $COUNT -gt 0 ]]; then
    AVG_P99=$(echo "scale=2; $TOTAL_P99 / $COUNT" | bc)
    OPS_INT=$(printf "%.0f" "$TOTAL_OPS")
    # Calculate throughput: ops × 4KB (data only)
    THROUGHPUT_GBS=$(echo "scale=2; $TOTAL_OPS * $DATA_SIZE / 1073741824" | bc)
    THROUGHPUT_GBPS=$(echo "scale=1; $THROUGHPUT_GBS * 8" | bc)

    echo "  Ops/sec:      ${OPS_INT}"
    echo "  Avg p99:      ${AVG_P99} ms"
    echo "  Data Thpt:    ${THROUGHPUT_GBS} GB/s (${THROUGHPUT_GBPS} Gbps) — payload only"
    echo "  Valid procs:  ${COUNT} / ${TOTAL_PROCS}"
    echo ""
    echo "  Ops/sec: ${OPS_INT}" >> "$REPORT"
    echo "  Avg p99: ${AVG_P99} ms" >> "$REPORT"
    echo "  Data Throughput: ${THROUGHPUT_GBS} GB/s (${THROUGHPUT_GBPS} Gbps) payload" >> "$REPORT"
    echo "  Procs: ${COUNT}/${TOTAL_PROCS}" >> "$REPORT"
    echo "" >> "$REPORT"
else
    echo "  ERROR: no valid results from any process!"
    echo "  ERROR: no results" >> "$REPORT"
fi

#-------------------------------------------------------------------------------
# CPU summary
summarize_cpu

#-------------------------------------------------------------------------------
stop_all

echo ""
echo "==============================================================================="
echo " COMPLETE — $(date)"
echo " Report: ${REPORT}"
echo " CPU data: ${RESULTS_DIR}/cpu_node*_${TIMESTAMP}.txt"
echo "==============================================================================="
