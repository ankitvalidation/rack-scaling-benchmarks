#!/bin/bash
set -euo pipefail

###############################################################################
# ScyllaDB Horizontal Node Scaling Benchmark
#
# Demonstrates ScyllaDB cluster scaling across 1, 3, and 5 nodes.
# Each node runs ScyllaDB with --smp 155 (leaving 5 cores for OS overhead).
#
# Configurations:
#   1 node:  103
#   3 nodes: 103, 104, 107
#   5 nodes: 103, 104, 107, 102, 101
#
# Client: node 101 (200.0.0.101) - for 5-node test, shares with ScyllaDB.
# Secondary client: node 102 for 3+ node tests.
#
# For each cluster size:
#   1. Start ScyllaDB cluster
#   2. Write 5M rows (500K partitions × 10 clustering rows)
#   3. Read for 60s at max throughput
#   4. Record results and tear down
###############################################################################

# Node pools
declare -A NODE_SETS
NODE_SETS[1]="200.0.0.103"
NODE_SETS[3]="200.0.0.103 200.0.0.104 200.0.0.107"
NODE_SETS[5]="200.0.0.103 200.0.0.104 200.0.0.107 200.0.0.102 200.0.0.101"
ALL_NODES="200.0.0.101 200.0.0.102 200.0.0.103 200.0.0.104 200.0.0.107"

SEED=200.0.0.103
CLIENT=200.0.0.101
SCYLLA_IMAGE="docker.io/scylladb/scylla:latest"
BENCH_IMAGE="docker.io/scylladb/scylla-bench:latest"
SMP=155
MEMORY="1200G"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RESULTS_DIR="$SCRIPT_DIR/results/horizontal"
mkdir -p "$RESULTS_DIR"

CLUSTER_SIZES=(1 3 5)

# Workload parameters
PARTITION_COUNT=500000
CLUSTERING_ROWS=10
READ_DURATION="60s"
CONCURRENCY=4096
CONNECTIONS=128

# --- Formatting ---
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'
CYAN='\033[0;36m'; NC='\033[0m'
log()    { echo -e "${GREEN}[$(date '+%H:%M:%S')]${NC} $*"; }
warn()   { echo -e "${YELLOW}[$(date '+%H:%M:%S')] WARN:${NC} $*"; }
err()    { echo -e "${RED}[$(date '+%H:%M:%S')] ERROR:${NC} $*"; }
banner() { echo -e "\n${CYAN}════════════════════════════════════════════════════${NC}"
           echo -e "${CYAN}  $*${NC}"
           echo -e "${CYAN}════════════════════════════════════════════════════${NC}\n"; }

ssh_cmd() {
    local node=$1; shift
    ssh -T "$node" "$@" 2>&1 | grep -v \
        "oneAPI\|:: \|bash: BASH_VERSION\|args: Using\|advisor\|ccl\|compiler\|dal\|debugger\|dev-util\|dnnl\|dpcpp\|dpl\|ipp\|mkl\|mpi\|tbb\|umf\|vtune\|initialized\|^$" || true
}

###############################################################################
# Cluster Management
###############################################################################

cleanup_all() {
    log "Cleaning up ALL nodes..."
    for node in $ALL_NODES; do
        ssh_cmd "$node" "podman stop scylla 2>/dev/null; podman rm -f scylla 2>/dev/null" &
    done
    wait
    sleep 2
    log "All nodes cleaned."
}

ensure_images() {
    log "Ensuring images on all nodes..."
    for node in $ALL_NODES; do
        ssh_cmd "$node" "podman image exists $SCYLLA_IMAGE 2>/dev/null || podman pull $SCYLLA_IMAGE --quiet" &
        ssh_cmd "$node" "podman image exists $BENCH_IMAGE 2>/dev/null || podman pull $BENCH_IMAGE --quiet" &
    done
    wait
    log "Images ready on all nodes."
}

start_scylla_node() {
    local node=$1
    local seeds=$2

    log "  Starting ScyllaDB on $node (seeds=$seeds)..."
    ssh_cmd "$node" "podman run -d --name scylla \
        --net=host \
        --privileged \
        $SCYLLA_IMAGE \
        --smp $SMP \
        --memory $MEMORY \
        --overprovisioned 0 \
        --listen-address $node \
        --rpc-address $node \
        --broadcast-address $node \
        --broadcast-rpc-address $node \
        --seeds $seeds \
        --developer-mode 1 \
        --api-address 0.0.0.0 \
        --default-log-level warn"
}

wait_for_cql() {
    local node=$1
    local timeout=${2:-300}
    local elapsed=0
    log "  Waiting for CQL on $node..."
    while [ $elapsed -lt $timeout ]; do
        if ssh_cmd "$node" "podman exec scylla cqlsh $node -e 'SELECT now() FROM system.local'" 2>/dev/null | grep -q "now"; then
            log "  CQL ready on $node (${elapsed}s)"
            return 0
        fi
        sleep 5
        elapsed=$((elapsed + 5))
    done
    err "CQL not ready on $node after ${timeout}s"
    return 1
}

wait_for_cluster() {
    local expected=$1
    local timeout=${2:-600}
    local elapsed=0
    log "  Waiting for cluster: $expected nodes UP/NORMAL..."
    while [ $elapsed -lt $timeout ]; do
        local count
        count=$(ssh_cmd "$SEED" "podman exec scylla nodetool status" 2>/dev/null | grep -c "^UN " || echo "0")
        if [ "$count" -ge "$expected" ]; then
            log "  Cluster ready: $count/$expected nodes UP (${elapsed}s)"
            # Show status
            ssh_cmd "$SEED" "podman exec scylla nodetool status" | head -20
            return 0
        fi
        log "    $count/$expected UP... (${elapsed}s)"
        sleep 10
        elapsed=$((elapsed + 10))
    done
    err "Cluster did not reach $expected nodes after ${timeout}s"
    return 1
}

start_cluster() {
    local size=$1
    local nodes_str="${NODE_SETS[$size]}"
    read -ra nodes <<< "$nodes_str"

    log "Starting $size-node cluster..."

    # Start seed node first
    start_scylla_node "${nodes[0]}" "$SEED"
    wait_for_cql "${nodes[0]}" 300

    # Start remaining nodes
    for ((i=1; i<${#nodes[@]}; i++)); do
        start_scylla_node "${nodes[$i]}" "$SEED"
        sleep 5  # stagger joins
    done

    # Wait for all nodes to join
    if [ $size -gt 1 ]; then
        wait_for_cluster "$size" 600
    fi

    log "Cluster of $size nodes ready."
}

run_bench() {
    local mode=$1
    local size=$2
    local label=$3

    # Contact points: comma-separated list of all nodes in the cluster
    local nodes_str="${NODE_SETS[$size]}"
    local contact_points
    contact_points=$(echo "$nodes_str" | tr ' ' ',')

    local duration_arg=""
    local workload="sequential"
    if [ "$mode" = "read" ]; then
        duration_arg="-duration $READ_DURATION"
        workload="uniform"
    fi

    log "scylla-bench $mode → $contact_points (concurrency=$CONCURRENCY)"
    ssh_cmd "$CLIENT" "podman run --rm --net=host $BENCH_IMAGE \
        -nodes '$contact_points' \
        -mode $mode \
        -workload $workload \
        -partition-count $PARTITION_COUNT \
        -clustering-row-count $CLUSTERING_ROWS \
        -concurrency $CONCURRENCY \
        -connection-count $CONNECTIONS \
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

banner "ScyllaDB Horizontal Node Scaling Benchmark"
log "Seed: $SEED | Client: $CLIENT | SMP=$SMP per node"
log "Cluster sizes: ${CLUSTER_SIZES[*]}"
log "Workload: ${PARTITION_COUNT} partitions × ${CLUSTERING_ROWS} rows"
log ""

ensure_images

# CSV header
CSV="$RESULTS_DIR/horizontal_scaling.csv"
echo "nodes,write_ops,write_p99,write_mean,read_ops,read_p99,read_mean" > "$CSV"

SUMMARY="$RESULTS_DIR/horizontal_summary.txt"
printf "%-6s | %-12s %-10s %-10s | %-12s %-10s %-10s\n" \
    "Nodes" "Write ops/s" "Wr p99" "Wr mean" "Read ops/s" "Rd p99" "Rd mean" > "$SUMMARY"
printf "%s\n" "$(printf '%.0s-' {1..85})" >> "$SUMMARY"

for size in "${CLUSTER_SIZES[@]}"; do
    banner "Testing $size-Node Cluster"
    START_TIME=$(date +%s)

    cleanup_all
    sleep 3

    start_cluster "$size"
    sleep 5

    # === Write Phase ===
    log "=== WRITE PHASE ($size nodes) ==="
    run_bench write "$size" "${size}n_write"
    write_csv=$(parse_results "$RESULTS_DIR/${size}n_write.txt")
    IFS=',' read -r w_ops w_p99 w_mean <<< "$write_csv"
    log "Write: $w_ops ops/s | p99=$w_p99 | mean=$w_mean"

    # === Read Phase ===
    log "=== READ PHASE ($size nodes) ==="
    run_bench read "$size" "${size}n_read"
    read_csv=$(parse_results "$RESULTS_DIR/${size}n_read.txt")
    IFS=',' read -r r_ops r_p99 r_mean <<< "$read_csv"
    log "Read: $r_ops ops/s | p99=$r_p99 | mean=$r_mean"

    # Record
    echo "$size,$write_csv,$read_csv" >> "$CSV"
    printf "%-6s | %-12s %-10s %-10s | %-12s %-10s %-10s\n" \
        "$size" "$w_ops" "$w_p99" "$w_mean" "$r_ops" "$r_p99" "$r_mean" >> "$SUMMARY"

    ELAPSED=$(($(date +%s) - START_TIME))
    log "$size-node cluster completed in ${ELAPSED}s"

    cleanup_all
done

banner "Horizontal Scaling - Complete Results"
cat "$SUMMARY"
log ""
log "CSV: $CSV"
log "Raw results: $RESULTS_DIR/"
