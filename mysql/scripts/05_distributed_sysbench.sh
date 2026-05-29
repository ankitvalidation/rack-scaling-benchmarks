#!/bin/bash
#===============================================================================
# MySQL Distributed Sysbench Benchmark (PKB-equivalent)
#
# Matches PerfKitBenchmarker config:
#   - 8 tables × 50M rows, 100GB buffer pool, oltp_read_only + oltp_read_write
#
# Phase 1: Single server (baseline)
#   Server: Node 104 | Client: Node 101
#
# Phase 2: Distributed (2 servers)
#   Server A: Node 104 | Client A: Node 101
#   Server B: Node 102 | Client B: Node 107
#   Shows 2× linear scaling with independent MySQL instances
#
# Thread sweep: 1, 8, 16, 32, 64, 128, 256, 512
#===============================================================================
set -e

# --- Configuration (matches PKB) ---
TABLES=8
TABLE_SIZE=50000000
BUFFER_POOL_SIZE="100G"
MYSQL_PORT=3320
TEST_TIME=300

# Servers and clients
SERVER_A="200.0.0.104"
SERVER_B="200.0.0.102"
CLIENT_A="200.0.0.101"  # local
CLIENT_B="200.0.0.107"

THREAD_COUNTS=(1 8 16 32 64 128 256 512)
WORKLOADS=(oltp_read_only oltp_read_write)

RESULTS_DIR="/root/rack-scaling-benchmarks/mysql/results/distributed_sysbench"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
mkdir -p "$RESULTS_DIR"

# Helper: filter oneAPI noise from SSH
ssh_cmd() {
    local host="$1"; shift
    ssh root@"$host" "$@" 2>/dev/null | grep -v "oneAPI\|::\|bash:\|setvars\|WARNING\|args:\|advisor\|ccl\|compiler\|dal\|debug\|dev-\|dnnl\|dpcpp\|dpl\|ipp\|mkl\|mpi\|tbb\|umf\|vtune\|initialized\|latest\|POSIX\|command-line\|cleared\|BASH_VERSION\|32-bit"
}

#===============================================================================
# STEP 1: Configure and start MySQL on both servers
#===============================================================================
configure_mysql() {
    local server="$1"
    local node_name="$2"
    echo "=== Configuring MySQL on $node_name ($server) ==="

    ssh_cmd "$server" "
        # Stop existing MySQL
        pkill -9 mysqld 2>/dev/null || true
        sleep 2

        # Create data directory
        mkdir -p /var/lib/mysql-bench/data
        mkdir -p /var/run/mysqld
        mkdir -p /var/log/mysql

        # Write config
        cat > /etc/my.cnf << 'MYCNF'
[mysqld]
port=3320
bind-address=0.0.0.0
skip-name-resolve
datadir=/var/lib/mysql-bench/data
socket=/var/run/mysqld/mysqld.sock
pid-file=/var/run/mysqld/mysqld.pid
log-error=/var/log/mysql/mysqld.log

# --- Match PKB: 100GB buffer pool ---
innodb_buffer_pool_size=100G
innodb_buffer_pool_instances=64

# --- InnoDB tuning for high-core systems ---
innodb_read_io_threads=64
innodb_write_io_threads=64
innodb_io_capacity=20000
innodb_io_capacity_max=40000
innodb_flush_method=O_DIRECT
innodb_use_native_aio=ON

# --- Redo log ---
innodb_redo_log_capacity=4G

# --- ACID ---
innodb_flush_log_at_trx_commit=1
innodb_doublewrite=ON

# --- Connections ---
max_connections=600
back_log=1500
table_open_cache=10000

# --- Performance ---
innodb_thread_concurrency=0
innodb_adaptive_hash_index=ON

[client]
port=3320
socket=/var/run/mysqld/mysqld.sock
MYCNF


        # Initialize if fresh
        if [ ! -d '/var/lib/mysql-bench/data/mysql' ]; then
            echo 'Initializing MySQL data directory...'
            mysqld --initialize-insecure --user=root --datadir=/var/lib/mysql-bench/data 2>&1 | tail -3
        fi

        # Start MySQL
        mysqld --user=root --port=3320 --datadir=/var/lib/mysql-bench/data &
        sleep 5

        # Create benchmark user
        mysql --port=3320 --socket=/var/run/mysqld/mysqld.sock -e \"
            CREATE USER IF NOT EXISTS 'bench'@'%' IDENTIFIED BY 'bench123';
            GRANT ALL PRIVILEGES ON *.* TO 'bench'@'%';
            CREATE DATABASE IF NOT EXISTS sbtest;
            FLUSH PRIVILEGES;
        \" 2>/dev/null

        echo 'MySQL ready on port 3320'
    "
}

#===============================================================================
# STEP 2: Prepare data (sysbench prepare)
#===============================================================================
prepare_data() {
    local server="$1"
    local client="$2"
    local label="$3"
    echo ""
    echo "=== Preparing data on $label: ${TABLES} tables × ${TABLE_SIZE} rows ==="

    if [[ "$client" == "$CLIENT_A" ]]; then
        # Local execution
        sysbench /usr/share/sysbench/oltp_read_only.lua \
            --mysql-host="$server" --mysql-port=$MYSQL_PORT \
            --mysql-user=bench --mysql-password=bench123 \
            --mysql-db=sbtest \
            --tables=$TABLES --table-size=$TABLE_SIZE \
            --threads=16 \
            prepare 2>&1 | tail -5
    else
        ssh_cmd "$client" "sysbench /usr/share/sysbench/oltp_read_only.lua \
            --mysql-host=$server --mysql-port=$MYSQL_PORT \
            --mysql-user=bench --mysql-password=bench123 \
            --mysql-db=sbtest \
            --tables=$TABLES --table-size=$TABLE_SIZE \
            --threads=16 \
            prepare 2>&1 | tail -5"
    fi
}

#===============================================================================
# STEP 3: Run benchmark
#===============================================================================
run_single_server() {
    local workload="$1"
    echo ""
    echo "================================================================"
    echo " PHASE 1: Single Server — $workload"
    echo " Server: $SERVER_A (node 104) | Client: $CLIENT_A (node 101)"
    echo " $(date)"
    echo "================================================================"

    local outfile="$RESULTS_DIR/single_${workload}_${TIMESTAMP}.txt"
    printf "%-10s %10s %12s %15s %12s %12s %12s\n" \
        "Threads" "TPS" "QPS" "Transactions" "Avg_lat_ms" "p95_lat_ms" "p99_lat_ms" > "$outfile"
    printf "%s\n" "$(printf '%.0s-' {1..85})" >> "$outfile"

    for threads in "${THREAD_COUNTS[@]}"; do
        echo "  --- Threads: $threads (${TEST_TIME}s) ---"
        result=$(sysbench /usr/share/sysbench/${workload}.lua \
            --mysql-host="$SERVER_A" --mysql-port=$MYSQL_PORT \
            --mysql-user=bench --mysql-password=bench123 \
            --mysql-db=sbtest \
            --tables=$TABLES --table-size=$TABLE_SIZE \
            --threads=$threads --time=$TEST_TIME \
            --report-interval=10 --rand-type=uniform \
            run 2>&1)

        tps=$(echo "$result" | grep "transactions:" | awk '{print $2}' | sed 's/(//g' | xargs printf "%.0f")
        qps=$(echo "$result" | grep "queries:" | awk '{print $2}' | sed 's/(//g' | xargs printf "%.0f")
        txns=$(echo "$result" | grep "transactions:" | awk '{print $1}' | head -1)
        avg=$(echo "$result" | grep "avg:" | awk '{print $2}')
        p95=$(echo "$result" | grep "95th percentile:" | awk '{print $3}')
        p99=$(echo "$result" | grep "99th percentile:" | awk '{print $3}')

        printf "%-10s %10s %12s %15s %12s %12s %12s\n" \
            "$threads" "$tps" "$qps" "$txns" "$avg" "$p95" "$p99" >> "$outfile"
        echo "    TPS=$tps QPS=$qps avg=${avg}ms p95=${p95}ms"
    done

    echo ""
    echo "Results: $outfile"
    cat "$outfile"
}

run_distributed() {
    local workload="$1"
    echo ""
    echo "================================================================"
    echo " PHASE 2: Distributed (2 Servers) — $workload"
    echo " Server A: $SERVER_A (104) ← Client A: $CLIENT_A (101)"
    echo " Server B: $SERVER_B (102) ← Client B: $CLIENT_B (107)"
    echo " $(date)"
    echo "================================================================"

    local outfile="$RESULTS_DIR/distributed_${workload}_${TIMESTAMP}.txt"
    printf "%-10s %12s %12s %14s %14s %12s %12s\n" \
        "Threads" "TPS_A" "TPS_B" "TPS_Total" "QPS_Total" "Avg_A_ms" "Avg_B_ms" > "$outfile"
    printf "%s\n" "$(printf '%.0s-' {1..95})" >> "$outfile"

    for threads in "${THREAD_COUNTS[@]}"; do
        echo "  --- Threads: $threads per server (${TEST_TIME}s) ---"

        # Run both clients in parallel
        local tmpA="/tmp/sysbench_A_${threads}.out"
        local tmpB="/tmp/sysbench_B_${threads}.out"

        # Client A (local → Server A)
        sysbench /usr/share/sysbench/${workload}.lua \
            --mysql-host="$SERVER_A" --mysql-port=$MYSQL_PORT \
            --mysql-user=bench --mysql-password=bench123 \
            --mysql-db=sbtest \
            --tables=$TABLES --table-size=$TABLE_SIZE \
            --threads=$threads --time=$TEST_TIME \
            --rand-type=uniform \
            run > "$tmpA" 2>&1 &
        local pidA=$!

        # Client B (node 107 → Server B)
        ssh root@"$CLIENT_B" "sysbench /usr/share/sysbench/${workload}.lua \
            --mysql-host=$SERVER_B --mysql-port=$MYSQL_PORT \
            --mysql-user=bench --mysql-password=bench123 \
            --mysql-db=sbtest \
            --tables=$TABLES --table-size=$TABLE_SIZE \
            --threads=$threads --time=$TEST_TIME \
            --rand-type=uniform \
            run" > "$tmpB" 2>&1 &
        local pidB=$!

        wait $pidA $pidB 2>/dev/null

        # Parse results
        tpsA=$(grep "transactions:" "$tmpA" | awk '{print $2}' | sed 's/(//g' | xargs printf "%.0f" 2>/dev/null || echo "0")
        tpsB=$(grep "transactions:" "$tmpB" | awk '{print $2}' | sed 's/(//g' | xargs printf "%.0f" 2>/dev/null || echo "0")
        qpsA=$(grep "queries:" "$tmpA" | awk '{print $2}' | sed 's/(//g' | xargs printf "%.0f" 2>/dev/null || echo "0")
        qpsB=$(grep "queries:" "$tmpB" | awk '{print $2}' | sed 's/(//g' | xargs printf "%.0f" 2>/dev/null || echo "0")
        avgA=$(grep "avg:" "$tmpA" | awk '{print $2}' 2>/dev/null || echo "0")
        avgB=$(grep "avg:" "$tmpB" | awk '{print $2}' 2>/dev/null || echo "0")

        tpsTotal=$((tpsA + tpsB))
        qpsTotal=$((qpsA + qpsB))

        printf "%-10s %12s %12s %14s %14s %12s %12s\n" \
            "$threads" "$tpsA" "$tpsB" "$tpsTotal" "$qpsTotal" "$avgA" "$avgB" >> "$outfile"
        echo "    A=$tpsA + B=$tpsB = ${tpsTotal} TPS total (QPS=${qpsTotal})"
    done

    echo ""
    echo "Results: $outfile"
    cat "$outfile"
}

#===============================================================================
# MAIN
#===============================================================================
echo "╔══════════════════════════════════════════════════════════════════════╗"
echo "║  MySQL Distributed Sysbench Benchmark (PKB-equivalent)              ║"
echo "║  $(date)                                      ║"
echo "╚══════════════════════════════════════════════════════════════════════╝"
echo ""
echo "Config: ${TABLES} tables × ${TABLE_SIZE} rows, buffer_pool=${BUFFER_POOL_SIZE}"
echo "Servers: $SERVER_A (104) + $SERVER_B (102)"
echo "Clients: $CLIENT_A (101) + $CLIENT_B (107)"
echo "Thread sweep: ${THREAD_COUNTS[*]}"
echo "Test time: ${TEST_TIME}s per point"
echo ""

# Configure MySQL servers
configure_mysql "$SERVER_A" "node104"
configure_mysql "$SERVER_B" "node102"

# Prepare data on both servers
prepare_data "$SERVER_A" "$CLIENT_A" "Server A (104)"
prepare_data "$SERVER_B" "$CLIENT_B" "Server B (102)"

# Run benchmarks
for wl in "${WORKLOADS[@]}"; do
    run_single_server "$wl"
    run_distributed "$wl"
done

echo ""
echo "╔══════════════════════════════════════════════════════════════════════╗"
echo "║  BENCHMARK COMPLETE — $(date)              ║"
echo "║  Results in: $RESULTS_DIR/                                          ║"
echo "╚══════════════════════════════════════════════════════════════════════╝"
