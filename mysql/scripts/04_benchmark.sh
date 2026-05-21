#!/bin/bash
#===============================================================================
# MySQL Benchmark — Thread Sweep (oltp_read_only)
#
# Two runs:
#   Run A: CPU-pinned (cores 0-8, matching DMR X4 baseline)
#   Run B: Unconstrained (all 160 cores, showcase)
#
# Thread sweep: 1, 8, 16, 32, 64, 128, 224, 320, 512
# Each point: 5-minute run with 10s reporting interval
#===============================================================================
set +e

SERVER="200.0.0.104"
MYSQL_PORT=3320
TABLES=60
ROWS=100000000

# Thread counts — match theirs + extend beyond
THREADS_SWEEP="1 8 16 32 64 128 224 320 512"
TEST_TIME=300   # 5 minutes per data point
REPORT_INTERVAL=10

RESULTS_DIR="/root/mysql-scaling-test/results"
mkdir -p "$RESULTS_DIR"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

SYSBENCH_COMMON="oltp_read_only \
    --mysql-host=$SERVER \
    --mysql-port=$MYSQL_PORT \
    --mysql-user=bench \
    --mysql-password=bench123 \
    --mysql-db=sbtest \
    --tables=$TABLES \
    --table-size=$ROWS \
    --rand-type=uniform \
    --report-interval=$REPORT_INTERVAL \
    --time=$TEST_TIME"

#===============================================================================
run_sweep() {
    local RUN_LABEL=$1
    local TASKSET_CMD=$2   # empty for unconstrained
    local REPORT_FILE="${RESULTS_DIR}/${RUN_LABEL}_${TIMESTAMP}.txt"

    echo ""
    echo "=================================================================="
    echo " ${RUN_LABEL} — Thread Sweep"
    echo " $(date)"
    echo "=================================================================="

    {
    echo "${RUN_LABEL} — $(date)"
    echo "Server: ${SERVER}:${MYSQL_PORT}"
    echo "Config: oltp_read_only, time=${TEST_TIME}s, rand=uniform"
    if [[ -n "$TASKSET_CMD" ]]; then
        echo "CPU Pinning: ${TASKSET_CMD}"
    else
        echo "CPU Pinning: NONE (all cores)"
    fi
    echo ""
    printf "%-10s %10s %12s %18s %12s %12s %12s\n" "Threads" "TPS" "QPS" "Transactions" "Avg_lat_ms" "p95_lat_ms" "Max_lat_ms"
    echo "--------------------------------------------------------------------------------------------"
    } > "$REPORT_FILE"

    for T in $THREADS_SWEEP; do
        echo ""
        echo "--- Threads: $T (${TEST_TIME}s) ---"

        # If pinned, restart MySQL with taskset
        if [[ -n "$TASKSET_CMD" && "$T" == "1" ]]; then
            echo "  Restarting MySQL with CPU pinning: $TASKSET_CMD"
            ssh "$SERVER" "
                pkill -9 mysqld; sleep 3
                ${TASKSET_CMD} /usr/libexec/mysqld --user=mysql &
                sleep 120
                mysqladmin --socket=/var/run/mysqld/mysqld.sock --port=${MYSQL_PORT} ping
            " 2>&1 | grep -v "oneAPI\|::\|bash\|args\|advisor\|ccl\|compiler\|dal\|debug\|dev-\|dnnl\|dpcpp\|dpl\|ipp\|mkl\|mpi\|tbb\|umf\|vtune\|initialized\|setvars\|latest"
        fi

        # Run sysbench
        OUTPUT=$(sysbench $SYSBENCH_COMMON --threads=$T run 2>&1)

        # Parse results
        TPS=$(echo "$OUTPUT" | grep "transactions:" | awk -F'(' '{print $2}' | awk '{printf "%.0f", $1}')
        QPS=$(echo "$OUTPUT" | grep "queries:" | awk -F'(' '{print $2}' | awk '{printf "%.0f", $1}')
        TOTAL_TX=$(echo "$OUTPUT" | grep "transactions:" | awk '{print $2}')
        AVG_LAT=$(echo "$OUTPUT" | grep "avg:" | awk '{print $2}')
        P95_LAT=$(echo "$OUTPUT" | grep "95th percentile:" | awk '{print $3}')
        MAX_LAT=$(echo "$OUTPUT" | grep "max:" | tail -1 | awk '{print $2}')

        echo "  TPS: ${TPS} | QPS: ${QPS} | avg: ${AVG_LAT}ms | p95: ${P95_LAT}ms"
        printf "%-10s %10s %12s %18s %12s %12s %12s\n" "$T" "$TPS" "$QPS" "$TOTAL_TX" "$AVG_LAT" "$P95_LAT" "$MAX_LAT" >> "$REPORT_FILE"

        # Brief pause between runs
        sleep 5
    done

    echo ""
    echo "Results saved to: ${REPORT_FILE}"
    cat "$REPORT_FILE"
}

#===============================================================================
echo "==============================================================================="
echo " MySQL oltp_read_only Thread Sweep"
echo " Server: ${SERVER}:${MYSQL_PORT} (node 104)"
echo " Client: local (node 101, 160 cores)"
echo " Dataset: ${TABLES} tables × 100M rows"
echo " Duration: ${TEST_TIME}s per thread count"
echo " $(date)"
echo "==============================================================================="

#--- Run A: Pinned to cores 0-8 (match DMR X4) ---
run_sweep "RUN_A_pinned_9cores" "taskset -c 0-8"

#--- Restart MySQL unconstrained ---
echo ""
echo "=== Restarting MySQL without CPU pinning (all 160 cores) ==="
ssh "$SERVER" "
    pkill -9 mysqld; sleep 3
    /usr/libexec/mysqld --user=mysql &
    sleep 120
    mysqladmin --socket=/var/run/mysqld/mysqld.sock --port=${MYSQL_PORT} ping
" 2>&1 | grep -v "oneAPI\|::\|bash\|args\|advisor\|ccl\|compiler\|dal\|debug\|dev-\|dnnl\|dpcpp\|dpl\|ipp\|mkl\|mpi\|tbb\|umf\|vtune\|initialized\|setvars\|latest"

#--- Run B: Unconstrained ---
run_sweep "RUN_B_unconstrained_160cores" ""

#===============================================================================
echo ""
echo "==============================================================================="
echo " BENCHMARK COMPLETE — $(date)"
echo ""
echo " Results:"
echo "   ${RESULTS_DIR}/RUN_A_pinned_9cores_${TIMESTAMP}.txt"
echo "   ${RESULTS_DIR}/RUN_B_unconstrained_160cores_${TIMESTAMP}.txt"
echo "==============================================================================="
