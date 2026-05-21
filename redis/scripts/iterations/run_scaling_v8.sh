#!/bin/bash
#===============================================================================
# Redis Vertical (Density) Scaling Benchmark v8
#
# IMPROVEMENT OVER v7:
#   - Dual-NIC: each client hits servers on BOTH 200.0.0.x and 220.0.0.x
#     → 400 Gbps aggregate bandwidth per server (vs 200 Gbps in v7)
#   - 10 memtier procs per client per server (vs 5 in v7)
#     → 20 total procs per server (vs 10)
#   - Total load generation: 2 clients × 10 procs × 3 servers = 60 procs
#     → 60 × 16T × 25C = 24,000 connections (vs 12,000 in v7)
#
# Architecture:
#   Clients: 101 (200.0.0.101 + 220.0.0.101)
#            102 (200.0.0.102 + 220.0.0.102)
#   Servers: 103, 104, 107 — listening on 0.0.0.0 (reachable via both NICs)
#
# Test: Density sweep on 3 server nodes — 1,4,8,16,32,64,96,128,160 inst/node
#===============================================================================
set +e

MEMTIER="/usr/local/bin/memtier_benchmark"

# Dual-NIC server addresses
SERVERS_NIC1=(200.0.0.103 200.0.0.104 200.0.0.107)
SERVERS_NIC2=(220.0.0.103 220.0.0.104 220.0.0.107)

# Client 2 addresses (for SSH)
CLIENT2_NIC1="200.0.0.102"

# Parameters
PIPELINE=20
DATA_SIZE=256
RATIO="1:1"
TEST_TIME=60

RESULTS_DIR="/root/redis-scaling-test/results_v8"
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
                --tcp-backlog 65535 --hz 100 --daemonize yes 2>/dev/null
        done
        echo \"\$(pgrep -c redis-server) on \$(hostname -s)\"
    " 2>&1 | grep " on "
}

run_density_test() {
    local INST_PER_NODE=$1
    local TOTAL_INST=$((3 * INST_PER_NODE))

    # Determine procs per client per NIC per server
    # Goal: spread load evenly. Each proc targets one port.
    # 5 procs per NIC per server × 2 NICs × 2 clients = 20 procs/server
    local PROCS_PER_NIC=5
    if [[ $INST_PER_NODE -le 2 ]]; then
        PROCS_PER_NIC=$INST_PER_NODE
    elif [[ $INST_PER_NODE -le 4 ]]; then
        PROCS_PER_NIC=$INST_PER_NODE
    elif [[ $INST_PER_NODE -le 8 ]]; then
        PROCS_PER_NIC=4
    fi

    local THREADS=16
    local CLIENTS=25
    local TOTAL_PROCS=$((PROCS_PER_NIC * 2 * 2 * 3))  # per_nic × 2nics × 2clients × 3servers
    local TOTAL_CONNS=$((TOTAL_PROCS * THREADS * CLIENTS))

    echo "  Config: 2 clients × 2 NICs × ${PROCS_PER_NIC} procs/nic/server × 3 servers"
    echo "  Total procs: ${TOTAL_PROCS} | Connections: ${TOTAL_CONNS}"

    local PIDS=()
    local P=0

    # Function to launch memtier procs for a given client (local or remote)
    # For each server, hit BOTH NIC1 and NIC2 addresses
    for srv_idx in 0 1 2; do
        local SRV_NIC1="${SERVERS_NIC1[$srv_idx]}"
        local SRV_NIC2="${SERVERS_NIC2[$srv_idx]}"

        local PORT_STEP=$((INST_PER_NODE / PROCS_PER_NIC))
        [[ $PORT_STEP -lt 1 ]] && PORT_STEP=1

        # --- CLIENT 1 (local) → NIC1 ---
        for j in $(seq 0 $((PROCS_PER_NIC - 1))); do
            P=$((P+1))
            local PORT=$((7000 + j * PORT_STEP))
            [[ $PORT -ge $((7000 + INST_PER_NODE)) ]] && PORT=$((7000 + INST_PER_NODE - 1))
            $MEMTIER --server="$SRV_NIC1" --port="$PORT" --protocol=redis \
                --threads="$THREADS" --clients="$CLIENTS" --pipeline="$PIPELINE" \
                --data-size="$DATA_SIZE" --ratio="$RATIO" --test-time="$TEST_TIME" \
                --key-minimum=1 --key-maximum=10000000 --key-pattern=R:R \
                --hide-histogram > "${RESULTS_DIR}/d${INST_PER_NODE}_c1n1_p${P}_${TIMESTAMP}.txt" 2>/dev/null &
            PIDS+=($!)
        done

        # --- CLIENT 1 (local) → NIC2 ---
        for j in $(seq 0 $((PROCS_PER_NIC - 1))); do
            P=$((P+1))
            local PORT=$((7000 + j * PORT_STEP + PORT_STEP/2))
            [[ $PORT -ge $((7000 + INST_PER_NODE)) ]] && PORT=$((7000 + INST_PER_NODE - 1))
            $MEMTIER --server="$SRV_NIC2" --port="$PORT" --protocol=redis \
                --threads="$THREADS" --clients="$CLIENTS" --pipeline="$PIPELINE" \
                --data-size="$DATA_SIZE" --ratio="$RATIO" --test-time="$TEST_TIME" \
                --key-minimum=1 --key-maximum=10000000 --key-pattern=R:R \
                --hide-histogram > "${RESULTS_DIR}/d${INST_PER_NODE}_c1n2_p${P}_${TIMESTAMP}.txt" 2>/dev/null &
            PIDS+=($!)
        done

        # --- CLIENT 2 (remote) → NIC1 ---
        for j in $(seq 0 $((PROCS_PER_NIC - 1))); do
            P=$((P+1))
            local PORT=$((7000 + j * PORT_STEP + PORT_STEP/4))
            [[ $PORT -ge $((7000 + INST_PER_NODE)) ]] && PORT=$((7000 + INST_PER_NODE - 1))
            ssh "$CLIENT2_NIC1" "
                memtier_benchmark --server=$SRV_NIC1 --port=$PORT --protocol=redis \
                    --threads=$THREADS --clients=$CLIENTS --pipeline=$PIPELINE \
                    --data-size=$DATA_SIZE --ratio=$RATIO --test-time=$TEST_TIME \
                    --key-minimum=1 --key-maximum=10000000 --key-pattern=R:R \
                    --hide-histogram 2>/dev/null
            " > "${RESULTS_DIR}/d${INST_PER_NODE}_c2n1_p${P}_${TIMESTAMP}.txt" 2>/dev/null &
            PIDS+=($!)
        done

        # --- CLIENT 2 (remote) → NIC2 ---
        for j in $(seq 0 $((PROCS_PER_NIC - 1))); do
            P=$((P+1))
            local PORT=$((7000 + j * PORT_STEP + 3*PORT_STEP/4))
            [[ $PORT -ge $((7000 + INST_PER_NODE)) ]] && PORT=$((7000 + INST_PER_NODE - 1))
            ssh "$CLIENT2_NIC1" "
                memtier_benchmark --server=$SRV_NIC2 --port=$PORT --protocol=redis \
                    --threads=$THREADS --clients=$CLIENTS --pipeline=$PIPELINE \
                    --data-size=$DATA_SIZE --ratio=$RATIO --test-time=$TEST_TIME \
                    --key-minimum=1 --key-maximum=10000000 --key-pattern=R:R \
                    --hide-histogram 2>/dev/null
            " > "${RESULTS_DIR}/d${INST_PER_NODE}_c2n2_p${P}_${TIMESTAMP}.txt" 2>/dev/null &
            PIDS+=($!)
        done
    done

    echo "  Waiting for ${#PIDS[@]} memtier processes (${TEST_TIME}s + overhead)..."
    for pid in "${PIDS[@]}"; do wait "$pid" 2>/dev/null || true; done

    # Aggregate results
    local TOTAL_OPS=0 TOTAL_P99=0 COUNT=0
    for f in "${RESULTS_DIR}/d${INST_PER_NODE}_c"*"_${TIMESTAMP}.txt"; do
        local OPS=$(grep "^Totals" "$f" 2>/dev/null | awk '{print $2}')
        local P99=$(grep "^Totals" "$f" 2>/dev/null | awk '{print $7}')
        if [[ -n "$OPS" && "$OPS" != "0.00" ]]; then
            TOTAL_OPS=$(echo "$TOTAL_OPS + $OPS" | bc)
            TOTAL_P99=$(echo "$TOTAL_P99 + $P99" | bc 2>/dev/null || echo "$TOTAL_P99")
            COUNT=$((COUNT+1))
        fi
    done

    if [[ $COUNT -gt 0 ]]; then
        local AVG_P99=$(echo "scale=2; $TOTAL_P99 / $COUNT" | bc)
        local OPS_INT=$(printf "%.0f" "$TOTAL_OPS")
        echo "  >>> ${OPS_INT} ops/sec | p99: ${AVG_P99} ms  [${COUNT} procs]"
        echo "D_3n_${INST_PER_NODE}i | ${OPS_INT} ops/sec | p99: ${AVG_P99} ms | ${COUNT} procs | ${TOTAL_CONNS} conns" >> "$REPORT"
    else
        echo "  >>> ERROR: no valid results"
        echo "D_3n_${INST_PER_NODE}i | ERROR" >> "$REPORT"
    fi
}

#===============================================================================
echo "==============================================================================="
echo " Redis Density Scaling v8 — Dual-NIC, Dual-Client"
echo " $(date)"
echo " Clients: 101 + 102 (both NICs: 200.0.0.x + 220.0.0.x)"
echo " Servers: 103, 104, 107 (both NICs)"
echo " Params: pipeline=${PIPELINE}, data=${DATA_SIZE}B, ratio=${RATIO}, time=${TEST_TIME}s"
echo " Improvement: 2× NICs + 2× procs vs v7 = 4× client capacity"
echo "==============================================================================="

{
echo "Redis Density Scaling v8 — $(date)"
echo "Clients: 101+102 (dual-NIC: 200.0.0.x + 220.0.0.x)"
echo "Servers: 103, 104, 107 (dual-NIC)"
echo "Params: pipeline=${PIPELINE}, data=${DATA_SIZE}B, ratio=${RATIO}, time=${TEST_TIME}s"
echo "Per-server load: 2 clients × 2 NICs × 5 procs = 20 memtier procs"
echo ""
} > "$REPORT"

#-------------------------------------------------------------------------------
echo ""
echo "======= DENSITY SCALING (3 nodes, dual-NIC) ======="
echo "=== DENSITY SCALING (3 nodes, dual-NIC) ===" >> "$REPORT"

for INST in 1 4 8 16 32 64 96 128 160; do
    echo ""
    echo "--- 3 nodes × ${INST} instances/node = $((3*INST)) total ---"

    stop_all
    for node in "${SERVERS_NIC1[@]}"; do
        start_instances "$node" "$INST"
    done
    sleep 2

    run_density_test "$INST"
done

#-------------------------------------------------------------------------------
stop_all

echo ""
echo "==============================================================================="
echo " COMPLETE — $(date)"
echo "==============================================================================="
echo ""
cat "$REPORT"
echo ""
echo "Full results: $RESULTS_DIR"
