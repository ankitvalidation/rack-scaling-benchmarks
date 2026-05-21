#!/bin/bash
# Run TPC-C benchmark on both SQL nodes simultaneously with CPU monitoring
# Run from Node 1 (S0101 / 200.0.0.101)
set -e

MGMT_NODE=200.0.0.101
SQL_NODE=200.0.0.102
HAMMERDB="/opt/HammerDB-4.12"
REPORT_DIR="/root/ndb-benchmark/cpu_reports"
RESULTS_DIR="/root/ndb-benchmark/results"

mkdir -p "$REPORT_DIR" "$RESULTS_DIR"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

echo "============================================"
echo "=== NDB 6-Node TPC-C Benchmark ==="
echo "=== $(date) ==="
echo "============================================"
echo ""
echo "Config: 4 data nodes, 2 SQL nodes, 256 VU each (512 total)"
echo ""

# Step 1: Start CPU monitor
echo "--- Starting CPU monitor ---"
rm -f "$REPORT_DIR"/cpu_report_*.csv
chmod +x /root/ndb-benchmark/cpu_monitor.sh
nohup /root/ndb-benchmark/cpu_monitor.sh &>/dev/null &
MON_PID=$!
echo "CPU monitor PID: $MON_PID"

# Step 2: Start HammerDB on Node 2 (background, via SSH)
echo ""
echo "--- Starting HammerDB on Node 2 ($SQL_NODE) ---"
ssh root@$SQL_NODE "export GLIBC_TUNABLES=glibc.cpu.x86_shstk=0 && cd $HAMMERDB && ./hammerdbcli auto /root/ndb-benchmark/run_benchmark_256vu.tcl" \
    > "$RESULTS_DIR/node2_result_${TIMESTAMP}.log" 2>&1 &
NODE2_PID=$!
echo "Node 2 HammerDB PID: $NODE2_PID"

# Step 3: Start HammerDB on Node 1 (foreground output)
echo "--- Starting HammerDB on Node 1 ($MGMT_NODE) ---"
cd "$HAMMERDB"
GLIBC_TUNABLES=glibc.cpu.x86_shstk=0 ./hammerdbcli auto /root/ndb-benchmark/run_benchmark_256vu.tcl 2>&1 | tee "$RESULTS_DIR/node1_result_${TIMESTAMP}.log" &
NODE1_PID=$!

# Step 4: Wait for both to complete
echo ""
echo "--- Waiting for both benchmarks to complete ---"
wait $NODE1_PID 2>/dev/null || true
echo "Node 1 benchmark complete"
wait $NODE2_PID 2>/dev/null || true
echo "Node 2 benchmark complete"

# Step 5: Wait for final CPU samples, then stop monitor
sleep 10
kill $MON_PID 2>/dev/null || true
echo "CPU monitor stopped"

# Step 6: Extract results
echo ""
echo "============================================"
echo "=== BENCHMARK RESULTS ==="
echo "============================================"
echo ""

echo "--- Node 1 (SQL on $MGMT_NODE) ---"
grep "TEST RESULT" "$RESULTS_DIR/node1_result_${TIMESTAMP}.log" || echo "No result found"

echo ""
echo "--- Node 2 (SQL on $SQL_NODE) ---"
grep "TEST RESULT" "$RESULTS_DIR/node2_result_${TIMESTAMP}.log" || echo "No result found"

# Extract NOPM values and sum
NOPM1=$(grep "TEST RESULT" "$RESULTS_DIR/node1_result_${TIMESTAMP}.log" | grep -oP '\d+(?= NOPM)' || echo 0)
NOPM2=$(grep "TEST RESULT" "$RESULTS_DIR/node2_result_${TIMESTAMP}.log" | grep -oP '\d+(?= NOPM)' || echo 0)
TOTAL_NOPM=$((NOPM1 + NOPM2))
echo ""
echo "--- COMBINED ---"
echo "  Node 1: $NOPM1 NOPM"
echo "  Node 2: $NOPM2 NOPM"
echo "  TOTAL:  $TOTAL_NOPM NOPM"

# Step 7: CPU Report
echo ""
echo "============================================"
echo "=== CPU UTILIZATION REPORT ==="
echo "============================================"
REPORT=$(ls -t "$REPORT_DIR"/cpu_report_*.csv 2>/dev/null | head -1)
if [[ -n "$REPORT" ]]; then
    echo ""
    for node in node1 node2 data1 data2 data3 data4; do
        label=$(grep "$node" "$REPORT" | head -1 | cut -d, -f2)
        if grep -q "$node" "$REPORT"; then
            echo "--- $node ---"
            grep "$node" "$REPORT" | awk -F, '{sum+=$3; n++; if($3>max)max=$3; if(min==""||$3<min)min=$3} END {printf "  Avg: %.1f%%  Peak: %.1f%%  Min: %.1f%%  Samples: %d\n", sum/n, max, min, n}'
        fi
    done

    echo ""
    echo "--- Timeline (every 5th sample) ---"
    echo "Time       | Node1   | Node2   | Data1   | Data2   | Data3   | Data4"
    paste -d'|' \
        <(grep node1 "$REPORT" | awk -F, '{printf "%s|%6.1f%%\n",$1,$3}') \
        <(grep node2 "$REPORT" | awk -F, '{printf "%6.1f%%\n",$3}') \
        <(grep data1 "$REPORT" | awk -F, '{printf "%6.1f%%\n",$3}') \
        <(grep data2 "$REPORT" | awk -F, '{printf "%6.1f%%\n",$3}') \
        <(grep data3 "$REPORT" | awk -F, '{printf "%6.1f%%\n",$3}') \
        <(grep data4 "$REPORT" | awk -F, '{printf "%6.1f%%\n",$3}') \
        | awk -F'|' 'NR%5==1 {printf "%-10s | %7s | %7s | %7s | %7s | %7s | %s\n", $1,$2,$3,$4,$5,$6,$7}'
    echo ""
    echo "Full report: $REPORT"
else
    echo "No CPU report generated"
fi

echo ""
echo "=== Benchmark complete: $(date) ==="
