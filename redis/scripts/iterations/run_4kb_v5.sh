#!/bin/bash
#===============================================================================
# Redis 4KB Block Size Test v5 — Fire-and-forget dual client
#
# Fixes: Previous versions had SSH pipe overhead killing client 2 performance.
# Solution: Deploy memtier as nohup background procs on node 102, then collect.
#
# Config: 16 inst/node, io-threads 8, pipeline=50, 4KB data
# Servers: 104, 107 (node 103 DOWN)
# Clients: 101 (local), 102 (fire-and-forget SSH)
#===============================================================================
set +e

MEMTIER="/usr/local/bin/memtier_benchmark"

# Server addresses (node 103 is DOWN)
SERVERS_NIC1=(200.0.0.104 200.0.0.107)
SERVERS_NIC2=(220.0.0.104 220.0.0.107)
ALL_NODES=(200.0.0.101 200.0.0.102 200.0.0.104 200.0.0.107)

CLIENT2="200.0.0.102"

# Parameters
PIPELINE=50
DATA_SIZE=16384
RATIO="1:1"
TEST_TIME=60
INST_PER_NODE=16
IO_THREADS=8
PROCS_PER_NIC=8
THREADS=16
CLIENTS=25

RESULTS_DIR="/root/redis-scaling-test/results_16kb"
mkdir -p "$RESULTS_DIR"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
REPORT="${RESULTS_DIR}/report_${TIMESTAMP}.txt"

#===============================================================================
stop_all() {
    for node in "${SERVERS_NIC1[@]}"; do
        ssh "$node" 'pkill -9 redis-server 2>/dev/null; rm -rf /tmp/redis-run' 2>/dev/null &
    done
    pkill -9 memtier 2>/dev/null
    ssh "$CLIENT2" 'pkill -9 memtier 2>/dev/null; rm -f /tmp/bench_*.txt' 2>/dev/null &
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
        ssh "$node" "nohup mpstat -P ALL 5 20 > /tmp/cpu_bench.txt 2>/dev/null &" 2>/dev/null &
    done
    # Also local
    nohup mpstat -P ALL 5 20 > /tmp/cpu_bench.txt 2>/dev/null &
    wait
}

collect_cpu() {
    echo ""
    echo "=== CPU Utilization Summary ===" | tee -a "$REPORT"
    for node in "${ALL_NODES[@]}"; do
        local label=$(echo "$node" | awk -F. '{print $4}')
        local data=$(ssh "$node" 'grep "     all" /tmp/cpu_bench.txt 2>/dev/null | tail -n +2' 2>/dev/null | grep -v "oneAPI\|::\|bash\|args\|advisor\|ccl\|compiler\|dal\|debug\|dev-\|dnnl\|dpcpp\|dpl\|ipp\|mkl\|mpi\|tbb\|umf\|vtune\|initialized\|setvars\|latest")
        if [[ -n "$data" ]]; then
            local avg_idle=$(echo "$data" | awk '{sum+=$NF; n++} END{if(n>0) printf "%.1f", sum/n; else print "N/A"}')
            local avg_usr=$(echo "$data" | awk '{sum+=$4; n++} END{if(n>0) printf "%.1f", sum/n; else print "N/A"}')
            local avg_sys=$(echo "$data" | awk '{sum+=$6; n++} END{if(n>0) printf "%.1f", sum/n; else print "N/A"}')
            local avg_si=$(echo "$data" | awk '{sum+=$9; n++} END{if(n>0) printf "%.1f", sum/n; else print "N/A"}')
            local total=$(echo "100 - $avg_idle" | bc 2>/dev/null || echo "?")
            echo "  Node ${label}: ${total}% used (usr=${avg_usr}% sys=${avg_sys}% softirq=${avg_si}% idle=${avg_idle}%)" | tee -a "$REPORT"
        else
            echo "  Node ${label}: NO DATA" | tee -a "$REPORT"
        fi
    done
}

#===============================================================================
echo "==============================================================================="
echo " Redis 16KB Test — Fire-and-Forget Dual Client"
echo " $(date)"
echo " Servers: 104, 107 | ${INST_PER_NODE} inst/node | io-threads=${IO_THREADS}"
echo " Clients: 101 (local) + 102 (fire-and-forget)"
echo " Params: pipeline=${PIPELINE}, data=${DATA_SIZE}B, ratio=${RATIO}, time=${TEST_TIME}s"
echo "==============================================================================="

{
echo "Redis 16KB Test — $(date)"
echo "Servers: 104, 107 (dual-NIC) | ${INST_PER_NODE} inst/node | io-threads=${IO_THREADS}"
echo "Clients: 101 (local) + 102 (fire-and-forget)"
echo "Params: pipeline=${PIPELINE}, data=${DATA_SIZE}B, ratio=${RATIO}, time=${TEST_TIME}s"
echo ""
} > "$REPORT"

#-------------------------------------------------------------------------------
echo ""
echo "=== Starting Redis: 2 nodes × ${INST_PER_NODE} = $((2*INST_PER_NODE)) instances ==="
stop_all
for node in "${SERVERS_NIC1[@]}"; do
    start_instances "$node" "$INST_PER_NODE"
done
sleep 2

#-------------------------------------------------------------------------------
echo ""
echo "=== Deploying memtier on client 2 (node 102) ==="

# Clean remote results
ssh "$CLIENT2" 'rm -f /tmp/bench_*.txt' 2>/dev/null

# Fire-and-forget: launch memtier procs on node 102 as background processes
C2_PROCS=0
for srv_idx in 0 1; do
    SRV_NIC1="${SERVERS_NIC1[$srv_idx]}"
    SRV_NIC2="${SERVERS_NIC2[$srv_idx]}"
    PORT_STEP=$((INST_PER_NODE / PROCS_PER_NIC))
    [[ $PORT_STEP -lt 1 ]] && PORT_STEP=1

    # Client 2 → NIC1
    for j in $(seq 0 $((PROCS_PER_NIC - 1))); do
        C2_PROCS=$((C2_PROCS+1))
        PORT=$((7000 + j * PORT_STEP))
        [[ $PORT -ge $((7000 + INST_PER_NODE)) ]] && PORT=$((7000 + INST_PER_NODE - 1))
        ssh "$CLIENT2" "nohup memtier_benchmark --server=$SRV_NIC1 --port=$PORT --protocol=redis \
            --threads=$THREADS --clients=$CLIENTS --pipeline=$PIPELINE \
            --data-size=$DATA_SIZE --ratio=$RATIO --test-time=$TEST_TIME \
            --key-minimum=1 --key-maximum=10000000 --key-pattern=R:R \
            --hide-histogram > /tmp/bench_c2n1_${C2_PROCS}.txt 2>/dev/null &" 2>/dev/null
    done

    # Client 2 → NIC2
    for j in $(seq 0 $((PROCS_PER_NIC - 1))); do
        C2_PROCS=$((C2_PROCS+1))
        PORT=$((7000 + j * PORT_STEP + PORT_STEP/2))
        [[ $PORT -ge $((7000 + INST_PER_NODE)) ]] && PORT=$((7000 + INST_PER_NODE - 1))
        ssh "$CLIENT2" "nohup memtier_benchmark --server=$SRV_NIC2 --port=$PORT --protocol=redis \
            --threads=$THREADS --clients=$CLIENTS --pipeline=$PIPELINE \
            --data-size=$DATA_SIZE --ratio=$RATIO --test-time=$TEST_TIME \
            --key-minimum=1 --key-maximum=10000000 --key-pattern=R:R \
            --hide-histogram > /tmp/bench_c2n2_${C2_PROCS}.txt 2>/dev/null &" 2>/dev/null
    done
done
echo "  Deployed ${C2_PROCS} memtier procs on node 102 (fire-and-forget)"

sleep 3  # Let client 2 start up

#-------------------------------------------------------------------------------
echo ""
echo "=== Starting CPU monitoring ==="
start_cpu_monitoring

sleep 2

#-------------------------------------------------------------------------------
echo ""
echo "=== Launching local memtier (client 1, node 101) ==="

C1_PIDS=()
C1_PROCS=0

for srv_idx in 0 1; do
    SRV_NIC1="${SERVERS_NIC1[$srv_idx]}"
    SRV_NIC2="${SERVERS_NIC2[$srv_idx]}"
    PORT_STEP=$((INST_PER_NODE / PROCS_PER_NIC))
    [[ $PORT_STEP -lt 1 ]] && PORT_STEP=1

    # Client 1 → NIC1
    for j in $(seq 0 $((PROCS_PER_NIC - 1))); do
        C1_PROCS=$((C1_PROCS+1))
        PORT=$((7000 + j * PORT_STEP + PORT_STEP/4))
        [[ $PORT -ge $((7000 + INST_PER_NODE)) ]] && PORT=$((7000 + INST_PER_NODE - 1))
        $MEMTIER --server="$SRV_NIC1" --port="$PORT" --protocol=redis \
            --threads="$THREADS" --clients="$CLIENTS" --pipeline="$PIPELINE" \
            --data-size="$DATA_SIZE" --ratio="$RATIO" --test-time="$TEST_TIME" \
            --key-minimum=1 --key-maximum=10000000 --key-pattern=R:R \
            --hide-histogram > "${RESULTS_DIR}/4kb_c1n1_p${C1_PROCS}_${TIMESTAMP}.txt" 2>/dev/null &
        C1_PIDS+=($!)
    done

    # Client 1 → NIC2
    for j in $(seq 0 $((PROCS_PER_NIC - 1))); do
        C1_PROCS=$((C1_PROCS+1))
        PORT=$((7000 + j * PORT_STEP + 3*PORT_STEP/4))
        [[ $PORT -ge $((7000 + INST_PER_NODE)) ]] && PORT=$((7000 + INST_PER_NODE - 1))
        $MEMTIER --server="$SRV_NIC2" --port="$PORT" --protocol=redis \
            --threads="$THREADS" --clients="$CLIENTS" --pipeline="$PIPELINE" \
            --data-size="$DATA_SIZE" --ratio="$RATIO" --test-time="$TEST_TIME" \
            --key-minimum=1 --key-maximum=10000000 --key-pattern=R:R \
            --hide-histogram > "${RESULTS_DIR}/4kb_c1n2_p${C1_PROCS}_${TIMESTAMP}.txt" 2>/dev/null &
        C1_PIDS+=($!)
    done
done

TOTAL_PROCS=$((C1_PROCS + C2_PROCS))
TOTAL_CONNS=$((TOTAL_PROCS * THREADS * CLIENTS))
echo "  Client 1: ${C1_PROCS} procs | Client 2: ${C2_PROCS} procs | Total: ${TOTAL_PROCS}"
echo "  Total connections: ${TOTAL_CONNS}"
echo "  Waiting ${TEST_TIME}s + overhead..."

# Wait for local procs
for pid in "${C1_PIDS[@]}"; do wait "$pid" 2>/dev/null || true; done
echo "  Client 1 complete."

# Give client 2 extra time to finish
sleep 10
echo "  Collecting client 2 results..."

#-------------------------------------------------------------------------------
# Collect client 2 results
ssh "$CLIENT2" 'ls /tmp/bench_c2*.txt 2>/dev/null | wc -l' 2>/dev/null | grep -v "oneAPI\|::\|bash\|args\|advisor\|ccl\|compiler\|dal\|debug\|dev-\|dnnl\|dpcpp\|dpl\|ipp\|mkl\|mpi\|tbb\|umf\|vtune\|initialized\|setvars\|latest"

# Copy results from client 2
for i in $(seq 1 $C2_PROCS); do
    ssh "$CLIENT2" "cat /tmp/bench_c2n1_${i}.txt 2>/dev/null" 2>/dev/null | grep -v "oneAPI\|::\|bash\|args\|advisor\|ccl\|compiler\|dal\|debug\|dev-\|dnnl\|dpcpp\|dpl\|ipp\|mkl\|mpi\|tbb\|umf\|vtune\|initialized\|setvars\|latest" > "${RESULTS_DIR}/4kb_c2n1_p${i}_${TIMESTAMP}.txt" 2>/dev/null
    ssh "$CLIENT2" "cat /tmp/bench_c2n2_${i}.txt 2>/dev/null" 2>/dev/null | grep -v "oneAPI\|::\|bash\|args\|advisor\|ccl\|compiler\|dal\|debug\|dev-\|dnnl\|dpcpp\|dpl\|ipp\|mkl\|mpi\|tbb\|umf\|vtune\|initialized\|setvars\|latest" > "${RESULTS_DIR}/4kb_c2n2_p${i}_${TIMESTAMP}.txt" 2>/dev/null
done

#-------------------------------------------------------------------------------
echo ""
echo "=== Results ===" | tee -a "$REPORT"

TOTAL_OPS=0 TOTAL_P99=0 COUNT=0
C1_OPS=0 C2_OPS=0 C1_COUNT=0 C2_COUNT=0

# Client 1 results
for f in "${RESULTS_DIR}/4kb_c1"*"_${TIMESTAMP}.txt"; do
    OPS=$(grep "^Totals" "$f" 2>/dev/null | awk '{print $2}')
    P99=$(grep "^Totals" "$f" 2>/dev/null | awk '{print $7}')
    if [[ -n "$OPS" && "$OPS" != "0.00" ]]; then
        TOTAL_OPS=$(echo "$TOTAL_OPS + $OPS" | bc)
        C1_OPS=$(echo "$C1_OPS + $OPS" | bc)
        TOTAL_P99=$(echo "$TOTAL_P99 + $P99" | bc 2>/dev/null || true)
        COUNT=$((COUNT+1))
        C1_COUNT=$((C1_COUNT+1))
    fi
done

# Client 2 results
for f in "${RESULTS_DIR}/4kb_c2"*"_${TIMESTAMP}.txt"; do
    OPS=$(grep "^Totals" "$f" 2>/dev/null | awk '{print $2}')
    P99=$(grep "^Totals" "$f" 2>/dev/null | awk '{print $7}')
    if [[ -n "$OPS" && "$OPS" != "0.00" ]]; then
        TOTAL_OPS=$(echo "$TOTAL_OPS + $OPS" | bc)
        C2_OPS=$(echo "$C2_OPS + $OPS" | bc)
        TOTAL_P99=$(echo "$TOTAL_P99 + $P99" | bc 2>/dev/null || true)
        COUNT=$((COUNT+1))
        C2_COUNT=$((C2_COUNT+1))
    fi
done

if [[ $COUNT -gt 0 ]]; then
    AVG_P99=$(echo "scale=2; $TOTAL_P99 / $COUNT" | bc)
    OPS_INT=$(printf "%.0f" "$TOTAL_OPS")
    C1_INT=$(printf "%.0f" "$C1_OPS")
    C2_INT=$(printf "%.0f" "$C2_OPS")
    THROUGHPUT_GBS=$(echo "scale=2; $TOTAL_OPS * $DATA_SIZE / 1073741824" | bc)
    THROUGHPUT_GBPS=$(echo "scale=1; $THROUGHPUT_GBS * 8" | bc)

    echo "  Total Ops/sec:    ${OPS_INT}" | tee -a "$REPORT"
    echo "  Client 1 (101):   ${C1_INT} ops/sec (${C1_COUNT} procs)" | tee -a "$REPORT"
    echo "  Client 2 (102):   ${C2_INT} ops/sec (${C2_COUNT} procs)" | tee -a "$REPORT"
    echo "  Avg p99:          ${AVG_P99} ms" | tee -a "$REPORT"
    echo "  Data Throughput:  ${THROUGHPUT_GBS} GB/s (${THROUGHPUT_GBPS} Gbps) payload" | tee -a "$REPORT"
    echo "  Valid procs:      ${COUNT} / ${TOTAL_PROCS}" | tee -a "$REPORT"
    echo "" | tee -a "$REPORT"
else
    echo "  ERROR: no valid results" | tee -a "$REPORT"
fi

#-------------------------------------------------------------------------------
collect_cpu

#-------------------------------------------------------------------------------
stop_all

echo ""
echo "==============================================================================="
echo " COMPLETE — $(date)"
echo " Report: ${REPORT}"
echo "==============================================================================="
