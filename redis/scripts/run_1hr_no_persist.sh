#!/bin/bash
#===============================================================================
# Redis 16KB Single-NIC Saturation — 1 HOUR (NO PERSISTENCE)
#
# Pure in-memory throughput test. No AOF, no RDB, no NFS.
# Same config as the 60s test that achieved 155 Gb/s (77.5% NIC saturation).
#
# Config: 16 inst/node, io-threads 8, pipeline=50, 16KB data
# Servers: 104, 107 (200.0.0.x ONLY)
# Clients: 101 (local), 102 (fire-and-forget) — both via 200.0.0.x only
#===============================================================================
set +e

MEMTIER="/usr/local/bin/memtier_benchmark"

SERVERS=(200.0.0.104 200.0.0.107)
CLIENT2="200.0.0.102"

# Parameters
PIPELINE=50
DATA_SIZE=16384
RATIO="1:1"
TEST_TIME=3600
INST_PER_NODE=16
IO_THREADS=8
PROCS_PER_SERVER=16
THREADS=16
CLIENTS=25

RESULTS_DIR="/root/redis-scaling-test/results_16kb_1nic_1hr_nopersist"
rm -rf "$RESULTS_DIR"
mkdir -p "$RESULTS_DIR"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
REPORT="${RESULTS_DIR}/report_${TIMESTAMP}.txt"

#===============================================================================
stop_all() {
    for node in "${SERVERS[@]}"; do
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
                --appendonly no --save '' \
                --maxclients 200000 --tcp-backlog 65535 --hz 100 \
                --io-threads ${IO_THREADS} --io-threads-do-reads yes \
                --daemonize yes 2>/dev/null
        done
        echo \"\$(pgrep -c redis-server) on \$(hostname -s)\"
    " 2>&1 | grep " on "
}

#===============================================================================
echo "==============================================================================="
echo " Redis 16KB SINGLE-NIC — 1 HOUR (NO PERSISTENCE)"
echo " $(date)"
echo " Servers: 104, 107 | ${INST_PER_NODE} inst/node | io-threads=${IO_THREADS}"
echo " Clients: 101 + 102 | ALL traffic on 200.0.0.x (np0)"
echo " Params: pipeline=${PIPELINE}, data=${DATA_SIZE}B, ratio=${RATIO}"
echo " Duration: ${TEST_TIME}s (1 hour) | NO persistence"
echo "==============================================================================="

{
echo "Redis 16KB Single-NIC — 1 HOUR NO PERSISTENCE — $(date)"
echo "Servers: 104, 107 (200.0.0.x only) | ${INST_PER_NODE} inst/node | io-threads=${IO_THREADS}"
echo "Clients: 101 + 102 (200.0.0.x only)"
echo "Params: pipeline=${PIPELINE}, data=${DATA_SIZE}B, ratio=${RATIO}, time=${TEST_TIME}s"
echo "Persistence: NONE (appendonly=no, save='')"
echo ""
} > "$REPORT"

#-------------------------------------------------------------------------------
echo ""
echo "=== Starting Redis: 2 nodes × ${INST_PER_NODE} = $((2*INST_PER_NODE)) instances ==="
stop_all
for node in "${SERVERS[@]}"; do
    start_instances "$node" "$INST_PER_NODE"
done
sleep 2

#-------------------------------------------------------------------------------
echo ""
echo "=== Deploying memtier on client 2 (node 102) ==="

ssh "$CLIENT2" 'rm -f /tmp/bench_*.txt' 2>/dev/null

C2_PROCS=0
for srv_idx in 0 1; do
    SRV="${SERVERS[$srv_idx]}"
    PORT_STEP=$((INST_PER_NODE / PROCS_PER_SERVER))
    [[ $PORT_STEP -lt 1 ]] && PORT_STEP=1

    for j in $(seq 0 $((PROCS_PER_SERVER - 1))); do
        C2_PROCS=$((C2_PROCS+1))
        PORT=$((7000 + j * PORT_STEP))
        [[ $PORT -ge $((7000 + INST_PER_NODE)) ]] && PORT=$((7000 + INST_PER_NODE - 1))
        ssh "$CLIENT2" "nohup memtier_benchmark --server=$SRV --port=$PORT --protocol=redis \
            --threads=$THREADS --clients=$CLIENTS --pipeline=$PIPELINE \
            --data-size=$DATA_SIZE --ratio=$RATIO --test-time=$TEST_TIME \
            --key-minimum=1 --key-maximum=10000000 --key-pattern=R:R \
            --hide-histogram > /tmp/bench_${C2_PROCS}.txt 2>/dev/null &" 2>/dev/null
    done
done
echo "  Deployed ${C2_PROCS} procs on node 102"

sleep 3

#-------------------------------------------------------------------------------
echo ""
echo "=== Launching local memtier (client 1, node 101) ==="

C1_PIDS=()
C1_PROCS=0

for srv_idx in 0 1; do
    SRV="${SERVERS[$srv_idx]}"
    PORT_STEP=$((INST_PER_NODE / PROCS_PER_SERVER))
    [[ $PORT_STEP -lt 1 ]] && PORT_STEP=1

    for j in $(seq 0 $((PROCS_PER_SERVER - 1))); do
        C1_PROCS=$((C1_PROCS+1))
        PORT=$((7000 + j * PORT_STEP))
        [[ $PORT -ge $((7000 + INST_PER_NODE)) ]] && PORT=$((7000 + INST_PER_NODE - 1))
        $MEMTIER --server="$SRV" --port="$PORT" --protocol=redis \
            --threads="$THREADS" --clients="$CLIENTS" --pipeline="$PIPELINE" \
            --data-size="$DATA_SIZE" --ratio="$RATIO" --test-time="$TEST_TIME" \
            --key-minimum=1 --key-maximum=10000000 --key-pattern=R:R \
            --hide-histogram > "${RESULTS_DIR}/c1_p${C1_PROCS}_${TIMESTAMP}.txt" 2>/dev/null &
        C1_PIDS+=($!)
    done
done

TOTAL_PROCS=$((C1_PROCS + C2_PROCS))
TOTAL_CONNS=$((TOTAL_PROCS * THREADS * CLIENTS))
echo "  Client 1: ${C1_PROCS} procs | Client 2: ${C2_PROCS} procs | Total: ${TOTAL_PROCS}"
echo "  Connections: ${TOTAL_CONNS} (all on 200.0.0.x / np0)"
echo "  Running for ${TEST_TIME}s..."
echo ""
echo "  Started: $(date)"

for pid in "${C1_PIDS[@]}"; do wait "$pid" 2>/dev/null || true; done
echo "  Client 1 complete: $(date)"

sleep 30
echo "  Collecting client 2 results..."

#-------------------------------------------------------------------------------
ssh "$CLIENT2" "cat /tmp/bench_*.txt 2>/dev/null" 2>/dev/null | grep -v "oneAPI\|::\|bash\|args\|advisor\|ccl\|compiler\|dal\|debug\|dev-\|dnnl\|dpcpp\|dpl\|ipp\|mkl\|mpi\|tbb\|umf\|vtune\|initialized\|setvars\|latest" > "${RESULTS_DIR}/c2_all_${TIMESTAMP}.txt" 2>/dev/null

#-------------------------------------------------------------------------------
echo ""
echo "=== Results ===" | tee -a "$REPORT"

TOTAL_OPS=0 TOTAL_P99=0 COUNT=0
C1_OPS=0 C2_OPS=0 C1_COUNT=0 C2_COUNT=0

for f in "${RESULTS_DIR}/c1_"*"_${TIMESTAMP}.txt"; do
    OPS=$(grep "^Totals" "$f" 2>/dev/null | awk '{print $2}')
    P99=$(grep "^Totals" "$f" 2>/dev/null | awk '{print $7}')
    if [[ -n "$OPS" && "$OPS" != "0.00" ]]; then
        TOTAL_OPS=$(echo "$TOTAL_OPS + $OPS" | bc)
        C1_OPS=$(echo "$C1_OPS + $OPS" | bc)
        TOTAL_P99=$(echo "$TOTAL_P99 + $P99" | bc 2>/dev/null || true)
        COUNT=$((COUNT+1)); C1_COUNT=$((C1_COUNT+1))
    fi
done

while IFS= read -r line; do
    OPS=$(echo "$line" | awk '{print $2}')
    P99=$(echo "$line" | awk '{print $7}')
    if [[ -n "$OPS" && "$OPS" != "0.00" ]]; then
        TOTAL_OPS=$(echo "$TOTAL_OPS + $OPS" | bc)
        C2_OPS=$(echo "$C2_OPS + $OPS" | bc)
        TOTAL_P99=$(echo "$TOTAL_P99 + $P99" | bc 2>/dev/null || true)
        COUNT=$((COUNT+1)); C2_COUNT=$((C2_COUNT+1))
    fi
done < <(grep "^Totals" "${RESULTS_DIR}/c2_all_${TIMESTAMP}.txt" 2>/dev/null)

if [[ $COUNT -gt 0 ]]; then
    AVG_P99=$(echo "scale=2; $TOTAL_P99 / $COUNT" | bc)
    OPS_INT=$(printf "%.0f" "$TOTAL_OPS")
    C1_INT=$(printf "%.0f" "$C1_OPS")
    C2_INT=$(printf "%.0f" "$C2_OPS")
    THROUGHPUT_GBS=$(echo "scale=2; $TOTAL_OPS * $DATA_SIZE / 1073741824" | bc)
    THROUGHPUT_GBPS=$(echo "scale=1; $THROUGHPUT_GBS * 8" | bc)
    TOTAL_DATA_TB=$(echo "scale=2; $TOTAL_OPS * $DATA_SIZE * $TEST_TIME / 1099511627776" | bc)

    echo "  Total Ops/sec:     ${OPS_INT}" | tee -a "$REPORT"
    echo "  Client 1 (101):    ${C1_INT} ops/sec (${C1_COUNT} procs)" | tee -a "$REPORT"
    echo "  Client 2 (102):    ${C2_INT} ops/sec (${C2_COUNT} procs)" | tee -a "$REPORT"
    echo "  Avg p99:           ${AVG_P99} ms" | tee -a "$REPORT"
    echo "  Data Throughput:   ${THROUGHPUT_GBS} GB/s (${THROUGHPUT_GBPS} Gbps)" | tee -a "$REPORT"
    echo "  Single NIC load:   ~${THROUGHPUT_GBPS} Gbps on np0 (200Gbps line rate)" | tee -a "$REPORT"
    echo "  Total data moved:  ~${TOTAL_DATA_TB} TB in 1 hour" | tee -a "$REPORT"
    echo "  Valid procs:       ${COUNT} / ${TOTAL_PROCS}" | tee -a "$REPORT"
    echo "" | tee -a "$REPORT"
else
    echo "  ERROR: no valid results" | tee -a "$REPORT"
fi

#-------------------------------------------------------------------------------
stop_all

echo ""
echo "==============================================================================="
echo " 1-HOUR RUN COMPLETE (NO PERSISTENCE) — $(date)"
echo " Report: ${REPORT}"
echo "==============================================================================="
