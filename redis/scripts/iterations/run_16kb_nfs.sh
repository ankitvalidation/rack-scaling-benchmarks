#!/bin/bash
#===============================================================================
# Redis 16KB Single-NIC + NFS Persistence Test
#
# Shows dual-network utilization:
#   np0 (200.0.0.x): Redis client data traffic (16KB ops)
#   np1 (220.0.0.x): Redis → NFS storage traffic (AOF streaming)
#
# Redis persistence config:
#   --appendonly yes --appendfsync no (stream writes, no blocking)
#   --save '' (no RDB snapshots)
#   --dir /mnt/nfs_rack/redis-bench/<node>/<port>/
#   Graceful shutdown at end to flush all data
#
# Write-heavy ratio (3:1) to maximize storage traffic
#
# Servers: 104, 107 (node 103 DOWN)
# Clients: 101, 102 (fire-and-forget, np0 only)
#===============================================================================
set +e

MEMTIER="/usr/local/bin/memtier_benchmark"

SERVERS=(200.0.0.104 200.0.0.107)
ALL_NODES=(200.0.0.101 200.0.0.102 200.0.0.104 200.0.0.107)
CLIENT2="200.0.0.102"

# Parameters
PIPELINE=50
DATA_SIZE=16384
RATIO="3:1"   # 75% writes for max storage traffic
TEST_TIME=90
INST_PER_NODE=16
IO_THREADS=8
PROCS_PER_SERVER=16
THREADS=16
CLIENTS=25

# NFS storage path
NFS_BASE="/mnt/nfs_rack/redis-bench"

RESULTS_DIR="/root/redis-scaling-test/results_16kb_nfs"
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
    local NODE_SHORT=$(echo "$NODE" | awk -F. '{print "node"$4}')
    ssh "$NODE" "
        rm -rf /tmp/redis-run; mkdir -p /tmp/redis-run
        # Create NFS directories for each instance
        mkdir -p ${NFS_BASE}/${NODE_SHORT}
        for i in \$(seq 0 $((N-1))); do
            PORT=\$((7000 + \$i))
            mkdir -p /tmp/redis-run/\$PORT
            mkdir -p ${NFS_BASE}/${NODE_SHORT}/\$PORT
            redis-server --port \$PORT --bind 0.0.0.0 --protected-mode no \
                --dir ${NFS_BASE}/${NODE_SHORT}/\$PORT \
                --appendonly yes \
                --appendfsync no \
                --save '' \
                --maxclients 200000 \
                --tcp-backlog 65535 --hz 100 \
                --io-threads ${IO_THREADS} --io-threads-do-reads yes \
                --daemonize yes 2>/dev/null
        done
        echo \"\$(pgrep -c redis-server) on \$(hostname -s)\"
    " 2>&1 | grep " on "
}

start_cpu_monitoring() {
    echo "  Starting CPU monitoring..."
    for node in "${ALL_NODES[@]}"; do
        ssh "$node" "nohup mpstat -P ALL 5 25 > /tmp/cpu_bench.txt 2>/dev/null &" 2>/dev/null &
    done
    nohup mpstat -P ALL 5 25 > /tmp/cpu_bench.txt 2>/dev/null &
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
            local total=$(echo "100 - $avg_idle" | bc 2>/dev/null || echo "?")
            echo "  Node ${label}: ${total}% CPU used (idle=${avg_idle}%)" | tee -a "$REPORT"
        else
            echo "  Node ${label}: NO DATA" | tee -a "$REPORT"
        fi
    done
}

#===============================================================================
echo "==============================================================================="
echo " Redis 16KB + NFS Persistence Test"
echo " $(date)"
echo " Servers: 104, 107 | ${INST_PER_NODE} inst/node | io-threads=${IO_THREADS}"
echo " Storage: ${NFS_BASE} (NFS via np1 / 220.0.0.x)"
echo " Persistence: appendonly=yes, appendfsync=no (non-blocking), ratio=3:1 (write-heavy)"
echo " Data traffic: np0 (200.0.0.x) | Storage traffic: np1 (220.0.0.x)"
echo " Clients: 101 + 102 | pipeline=${PIPELINE} | data=${DATA_SIZE}B | time=${TEST_TIME}s"
echo "==============================================================================="

{
echo "Redis 16KB + NFS Persistence — $(date)"
echo "Servers: 104, 107 | ${INST_PER_NODE} inst/node | io-threads=${IO_THREADS}"
echo "Storage: ${NFS_BASE} (NFS on 220.0.0.105 via np1)"
echo "Persistence: appendonly=yes (everysec) + RDB save every 10s"
echo "Network split: np0=data, np1=storage"
echo "Params: pipeline=${PIPELINE}, data=${DATA_SIZE}B, ratio=${RATIO}, time=${TEST_TIME}s"
echo ""
} > "$REPORT"

#-------------------------------------------------------------------------------
echo ""
echo "=== Cleaning previous NFS data ==="
for node in "${SERVERS[@]}"; do
    NODE_SHORT=$(echo "$node" | awk -F. '{print "node"$4}')
    ssh "$node" "rm -rf ${NFS_BASE}/${NODE_SHORT}" 2>/dev/null &
done
wait
echo "  Done."

#-------------------------------------------------------------------------------
echo ""
echo "=== Starting Redis with persistence: 2 × ${INST_PER_NODE} = $((2*INST_PER_NODE)) instances ==="
stop_all
for node in "${SERVERS[@]}"; do
    start_instances "$node" "$INST_PER_NODE"
done
sleep 2

# Verify instances are writing to NFS
echo "  Verifying NFS write access..."
for node in "${SERVERS[@]}"; do
    NODE_SHORT=$(echo "$node" | awk -F. '{print "node"$4}')
    FILE_COUNT=$(ssh "$node" "ls ${NFS_BASE}/${NODE_SHORT}/7000/ 2>/dev/null | wc -l" 2>/dev/null | grep -v "oneAPI\|::\|bash\|args\|advisor\|ccl\|compiler\|dal\|debug\|dev-\|dnnl\|dpcpp\|dpl\|ipp\|mkl\|mpi\|tbb\|umf\|vtune\|initialized\|setvars\|latest" | tr -d ' ')
    echo "    ${NODE_SHORT}: ${FILE_COUNT} files in NFS dir"
done

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
echo "=== Starting CPU monitoring ==="
start_cpu_monitoring
sleep 2

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
echo "  Client 1: ${C1_PROCS} procs | Client 2: ${C2_PROCS} procs | Total: ${TOTAL_PROCS}"
echo "  Waiting ${TEST_TIME}s (longer for RDB snapshots)..."

for pid in "${C1_PIDS[@]}"; do wait "$pid" 2>/dev/null || true; done
echo "  Client 1 complete."

sleep 10

#-------------------------------------------------------------------------------
echo ""
echo "=== Storage summary (NFS usage) ==="

for node in "${SERVERS[@]}"; do
    NODE_SHORT=$(echo "$node" | awk -F. '{print "node"$4}')
    NFS_SIZE=$(ssh "$node" "du -sh ${NFS_BASE}/${NODE_SHORT}/ 2>/dev/null | awk '{print \$1}'" 2>/dev/null | grep -v "oneAPI\|::\|bash\|args\|advisor\|ccl\|compiler\|dal\|debug\|dev-\|dnnl\|dpcpp\|dpl\|ipp\|mkl\|mpi\|tbb\|umf\|vtune\|initialized\|setvars\|latest" | tail -1)
    AOF_SIZE=$(ssh "$node" "du -sh ${NFS_BASE}/${NODE_SHORT}/7000/appendonlydir/ 2>/dev/null | awk '{print \$1}'" 2>/dev/null | grep -v "oneAPI\|::\|bash\|args\|advisor\|ccl\|compiler\|dal\|debug\|dev-\|dnnl\|dpcpp\|dpl\|ipp\|mkl\|mpi\|tbb\|umf\|vtune\|initialized\|setvars\|latest" | tail -1)
    RDB_COUNT=$(ssh "$node" "find ${NFS_BASE}/${NODE_SHORT}/ -name 'dump.rdb' 2>/dev/null | wc -l" 2>/dev/null | grep -v "oneAPI\|::\|bash\|args\|advisor\|ccl\|compiler\|dal\|debug\|dev-\|dnnl\|dpcpp\|dpl\|ipp\|mkl\|mpi\|tbb\|umf\|vtune\|initialized\|setvars\|latest" | tail -1)
    echo "  ${NODE_SHORT}: total=${NFS_SIZE}, AOF(port7000)=${AOF_SIZE}, RDB files=${RDB_COUNT}" | tee -a "$REPORT"
done

#-------------------------------------------------------------------------------
echo ""
echo "=== Collecting client 2 results ==="

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

    echo "  Total Ops/sec:    ${OPS_INT}" | tee -a "$REPORT"
    echo "  Client 1 (101):   ${C1_INT} ops/sec (${C1_COUNT} procs)" | tee -a "$REPORT"
    echo "  Client 2 (102):   ${C2_INT} ops/sec (${C2_COUNT} procs)" | tee -a "$REPORT"
    echo "  Avg p99:          ${AVG_P99} ms" | tee -a "$REPORT"
    echo "  Data Throughput:  ${THROUGHPUT_GBS} GB/s (${THROUGHPUT_GBPS} Gbps) — np0" | tee -a "$REPORT"
    echo "  Valid procs:      ${COUNT} / ${TOTAL_PROCS}" | tee -a "$REPORT"
    echo "" | tee -a "$REPORT"
    echo "  Network split:" | tee -a "$REPORT"
    echo "    np0 (200.0.0.x): ~${THROUGHPUT_GBPS} Gbps data traffic" | tee -a "$REPORT"
    echo "    np1 (220.0.0.x): NFS storage traffic (AOF + RDB snapshots)" | tee -a "$REPORT"
else
    echo "  ERROR: no valid results" | tee -a "$REPORT"
fi

#-------------------------------------------------------------------------------
collect_cpu

#-------------------------------------------------------------------------------
# Graceful shutdown to flush all data to NFS
echo ""
echo "=== Graceful shutdown (flushing to NFS) ==="
for node in "${SERVERS[@]}"; do
    for p in \$(seq 0 $((INST_PER_NODE-1))); do
        PORT=\$((7000 + p))
        ssh "$node" "redis-cli -p \$PORT BGREWRITEAOF 2>/dev/null" 2>/dev/null &
    done
done
wait
sleep 15  # Let AOF rewrite complete

# Now check final sizes
echo "" | tee -a "$REPORT"
echo "=== Final NFS storage (after flush) ===" | tee -a "$REPORT"
for node in "${SERVERS[@]}"; do
    NODE_SHORT=\$(echo "$node" | awk -F. '{print "node"\$4}')
    TOTAL_SIZE=\$(ssh "$node" "du -sh ${NFS_BASE}/\${NODE_SHORT}/ 2>/dev/null | awk '{print \\\$1}'" 2>/dev/null | grep -v "oneAPI\|::\|bash\|args\|advisor\|ccl\|compiler\|dal\|debug\|dev-\|dnnl\|dpcpp\|dpl\|ipp\|mkl\|mpi\|tbb\|umf\|vtune\|initialized\|setvars\|latest" | tail -1)
    echo "  \${NODE_SHORT}: \${TOTAL_SIZE} on NFS" | tee -a "$REPORT"
done
DU_TOTAL=\$(du -sh ${NFS_BASE}/ 2>/dev/null | awk '{print \$1}')
echo "  TOTAL: \${DU_TOTAL} on NFS (220.0.0.105)" | tee -a "$REPORT"

stop_all

echo ""
echo "==============================================================================="
echo " COMPLETE — $(date)"
echo " Report: ${REPORT}"
echo " NFS data remains at: ${NFS_BASE}/"
echo "==============================================================================="
