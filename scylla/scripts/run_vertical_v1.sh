#!/bin/bash
set -euo pipefail

###############################################################################
# ScyllaDB Vertical Core Scaling Benchmark
#
# Demonstrates ScyllaDB's shard-per-core architecture by varying --smp on a
# single 160-core node. Each shard maps to one CPU core.
#
# Server: node 103 (200.0.0.103)
# Client: node 101 (200.0.0.101) running scylla-bench
#
# For each SMP value:
#   1. Start ScyllaDB with --smp N
#   2. Write 1M rows (100K partitions × 10 clustering rows)
#   3. Read for 60s at max throughput
#   4. Record results and clean up
###############################################################################

SERVER=200.0.0.103
CLIENT=200.0.0.101
SCYLLA_IMAGE="docker.io/scylladb/scylla:latest"
BENCH_IMAGE="docker.io/scylladb/scylla-bench:latest"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RESULTS_DIR="$SCRIPT_DIR/results/vertical"
mkdir -p "$RESULTS_DIR"

SMP_VALUES=(1 2 4 8 16 32 64 96 128 160)

# Workload parameters
PARTITION_COUNT=100000
CLUSTERING_ROWS=10
READ_DURATION="60s"

# --- Formatting ---
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
log()    { echo -e "${GREEN}[$(date '+%H:%M:%S')]${NC} $*"; }
warn()   { echo -e "${YELLOW}[$(date '+%H:%M:%S')] WARN:${NC} $*"; }
err()    { echo -e "${RED}[$(date '+%H:%M:%S')] ERROR:${NC} $*"; }
banner() { echo -e "\n${CYAN}════════════════════════════════════════════════════${NC}"
           echo -e "${CYAN}  $*${NC}"
           echo -e "${CYAN}════════════════════════════════════════════════════${NC}\n"; }

# Filter oneAPI noise from SSH output
ssh_cmd() {
    local node=$1; shift
    ssh -T "$node" "$@" 2>&1 | grep -v \
        "oneAPI\|:: \|bash: BASH_VERSION\|args: Using\|advisor\|ccl\|compiler\|dal\|debugger\|dev-util\|dnnl\|dpcpp\|dpl\|ipp\|mkl\|mpi\|tbb\|umf\|vtune\|initialized\|^$" || true
}

###############################################################################
# Core Functions
###############################################################################

cleanup() {
    log "Cleaning up server $SERVER..."
    ssh_cmd "$SERVER" "podman stop scylla 2>/dev/null; podman rm -f scylla 2>/dev/null" || true
    sleep 1
}

start_scylla() {
    local smp=$1
    local mem=$((smp * 8))
    [ $mem -gt 1200 ] && mem=1200
    [ $mem -lt 2 ] && mem=2

    log "Starting ScyllaDB on $SERVER (smp=$smp, memory=${mem}G)..."
    ssh_cmd "$SERVER" "podman run -d --name scylla \
        --net=host \
        --privileged \
        $SCYLLA_IMAGE \
        --smp $smp \
        --memory ${mem}G \
        --overprovisioned 0 \
        --listen-address $SERVER \
        --rpc-address $SERVER \
        --broadcast-address $SERVER \
        --broadcast-rpc-address $SERVER \
        --developer-mode 1 \
        --api-address 0.0.0.0 \
        --default-log-level warn"
}

wait_for_cql() {
    local timeout=${1:-300}
    local elapsed=0
    log "Waiting for CQL on $SERVER..."
    while [ $elapsed -lt $timeout ]; do
        if ssh_cmd "$SERVER" "podman exec scylla cqlsh $SERVER -e 'SELECT now() FROM system.local'" 2>/dev/null | grep -q "now"; then
            log "CQL ready (${elapsed}s)"
            return 0
        fi
        sleep 5
        elapsed=$((elapsed + 5))
    done
    err "CQL not ready after ${timeout}s"
    return 1
}

run_bench() {
    local mode=$1       # write or read
    local smp=$2
    local label=$3

    # Scale concurrency with SMP: enough goroutines to keep all shards busy
    local concurrency=$((smp * 16))
    [ $concurrency -lt 64 ] && concurrency=64
    [ $concurrency -gt 4096 ] && concurrency=4096

    # Scale connections with SMP
    local connections=$((smp * 2))
    [ $connections -lt 4 ] && connections=4
    [ $connections -gt 128 ] && connections=128

    local duration_arg=""
    local workload="sequential"
    if [ "$mode" = "read" ]; then
        duration_arg="-duration $READ_DURATION"
        workload="uniform"
    fi

    log "scylla-bench $mode: concurrency=$concurrency, connections=$connections"
    ssh_cmd "$CLIENT" "podman run --rm --net=host $BENCH_IMAGE \
        -nodes $SERVER \
        -mode $mode \
        -workload $workload \
        -partition-count $PARTITION_COUNT \
        -clustering-row-count $CLUSTERING_ROWS \
        -concurrency $concurrency \
        -connection-count $connections \
        -consistency-level one \
        -replication-factor 1 \
        $duration_arg" 2>&1 | tee "$RESULTS_DIR/${label}.txt"
}

parse_results() {
    local file=$1
    local ops p99 mean_lat
    ops=$(grep "^Operations/s:" "$file" | awk '{print $2}')
    p99=$(grep -A7 "^raw latency" "$file" | grep "99th:" | head -1 | awk '{print $2}')
    mean_lat=$(grep -A7 "^raw latency" "$file" | grep "mean:" | head -1 | awk '{print $2}')
    echo "${ops:-0},${p99:-0},${mean_lat:-0}"
}

###############################################################################
# Main
###############################################################################

banner "ScyllaDB Vertical Core Scaling Benchmark"
log "Server: $SERVER (160 cores) | Client: $CLIENT"
log "SMP values: ${SMP_VALUES[*]}"
log "Workload: ${PARTITION_COUNT} partitions × ${CLUSTERING_ROWS} rows = $((PARTITION_COUNT * CLUSTERING_ROWS)) total rows"
log ""

# CSV header
CSV="$RESULTS_DIR/vertical_scaling.csv"
echo "smp,write_ops,write_p99,write_mean,read_ops,read_p99,read_mean" > "$CSV"

# Summary table header
SUMMARY="$RESULTS_DIR/vertical_summary.txt"
printf "%-6s | %-12s %-10s %-10s | %-12s %-10s %-10s\n" \
    "SMP" "Write ops/s" "Wr p99" "Wr mean" "Read ops/s" "Rd p99" "Rd mean" > "$SUMMARY"
printf "%s\n" "$(printf '%.0s-' {1..85})" >> "$SUMMARY"

for smp in "${SMP_VALUES[@]}"; do
    banner "Testing SMP = $smp"
    START_TIME=$(date +%s)

    # Clean slate
    cleanup
    sleep 2

    # Start ScyllaDB
    start_scylla "$smp"
    wait_for_cql || { err "Skipping SMP=$smp"; cleanup; continue; }

    # Small warmup delay
    sleep 3

    # === Write Phase ===
    log "=== WRITE PHASE (SMP=$smp) ==="
    run_bench write "$smp" "smp${smp}_write"
    write_csv=$(parse_results "$RESULTS_DIR/smp${smp}_write.txt")
    IFS=',' read -r w_ops w_p99 w_mean <<< "$write_csv"
    log "Write: $w_ops ops/s | p99=$w_p99 | mean=$w_mean"

    # === Read Phase ===
    log "=== READ PHASE (SMP=$smp) ==="
    run_bench read "$smp" "smp${smp}_read"
    read_csv=$(parse_results "$RESULTS_DIR/smp${smp}_read.txt")
    IFS=',' read -r r_ops r_p99 r_mean <<< "$read_csv"
    log "Read: $r_ops ops/s | p99=$r_p99 | mean=$r_mean"

    # Record
    echo "$smp,$write_csv,$read_csv" >> "$CSV"
    printf "%-6s | %-12s %-10s %-10s | %-12s %-10s %-10s\n" \
        "$smp" "$w_ops" "$w_p99" "$w_mean" "$r_ops" "$r_p99" "$r_mean" >> "$SUMMARY"

    ELAPSED=$(($(date +%s) - START_TIME))
    log "SMP=$smp completed in ${ELAPSED}s"

    # Cleanup before next iteration
    cleanup
done

banner "Vertical Core Scaling - Complete Results"
cat "$SUMMARY"
log ""
log "CSV: $CSV"
log "Raw results: $RESULTS_DIR/"
