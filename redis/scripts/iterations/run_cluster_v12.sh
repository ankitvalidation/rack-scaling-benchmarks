#!/bin/bash
# Test 3b: Dense cluster horizontal scaling with DUAL CLIENT load
# Servers: 103, 104, 107 (3-node), +102 (4-node), +101 (5-node)
# Clients: 101 + 102 (dual-NIC, multiple procs)
# Cluster mode: 32 instances per node, all masters

SERVERS_3=(200.0.0.103 200.0.0.104 200.0.0.107)
SERVERS_4=(200.0.0.103 200.0.0.104 200.0.0.107 200.0.0.102)
SERVERS_5=(200.0.0.103 200.0.0.104 200.0.0.107 200.0.0.102 200.0.0.101)
INST_PER_NODE=32
BASE_PORT=7000
RESDIR="/root/redis-scaling-test/results_v12_dualclient"
mkdir -p "$RESDIR"

CLIENT1="200.0.0.101"  # local
CLIENT2="200.0.0.102"

start_cluster() {
    local -n SRVS=$1
    local num_nodes=${#SRVS[@]}
    echo "--- Starting $num_nodes-node cluster (${num_nodes}×32 = $((num_nodes*32)) members) ---"
    
    # Kill existing redis on all nodes
    for s in "${SRVS[@]}"; do
        ssh "$s" 'pkill -9 redis-server 2>/dev/null; rm -rf /tmp/redis-cluster; sleep 0.5' 2>/dev/null &
    done
    wait
    sleep 1
    
    # Start instances on each node
    for s in "${SRVS[@]}"; do
        ssh "$s" "
            mkdir -p /tmp/redis-cluster
            for i in \$(seq 0 $((INST_PER_NODE-1))); do
                P=\$((${BASE_PORT}+i))
                mkdir -p /tmp/redis-cluster/\$P
                redis-server --port \$P --bind 0.0.0.0 --protected-mode no \
                    --dir /tmp/redis-cluster/\$P \
                    --cluster-enabled yes --cluster-config-file /tmp/redis-cluster/\$P/nodes.conf \
                    --cluster-node-timeout 5000 \
                    --appendonly no --save '' --maxclients 200000 \
                    --tcp-backlog 65535 --hz 100 --daemonize yes 2>/dev/null
            done
            echo \"\$(pgrep -c redis-server) on \$(hostname -s)\"
        " 2>/dev/null &
    done
    wait
    sleep 2
    
    # Build cluster-create node list
    NODES=""
    for s in "${SRVS[@]}"; do
        for p in $(seq 0 $((INST_PER_NODE-1))); do
            NODES="$NODES ${s}:$((BASE_PORT+p))"
        done
    done
    
    echo "Creating cluster with $((num_nodes*INST_PER_NODE)) members..."
    redis-cli --cluster create $NODES --cluster-replicas 0 --cluster-yes 2>&1 | tail -3
    sleep 5
    
    # Verify
    redis-cli -h "${SRVS[0]}" -p $BASE_PORT cluster info | grep -E "state|known"
}

run_dual_client_bench() {
    local tag=$1
    local entry_server=$2
    local entry_port=$3
    local procs_per_client=$4
    
    echo "  Benchmarking ($tag): ${procs_per_client} procs × 2 clients, entry=${entry_server}:${entry_port}"
    
    # Launch procs on local node (101) - use both NICs
    for p in $(seq 1 $procs_per_client); do
        memtier_benchmark --server="$entry_server" --port="$entry_port" \
            --protocol=redis --cluster-mode \
            --threads=32 --clients=5 --pipeline=20 \
            --data-size=256 --ratio=1:1 --test-time=60 \
            --key-minimum=1 --key-maximum=10000000 --key-pattern=R:R \
            --hide-histogram > "${RESDIR}/${tag}_c1_p${p}.txt" 2>/dev/null &
    done
    
    # Launch procs on remote client (102) via SSH
    for p in $(seq 1 $procs_per_client); do
        ssh "$CLIENT2" "memtier_benchmark --server=$entry_server --port=$entry_port \
            --protocol=redis --cluster-mode \
            --threads=32 --clients=5 --pipeline=20 \
            --data-size=256 --ratio=1:1 --test-time=60 \
            --key-minimum=1 --key-maximum=10000000 --key-pattern=R:R \
            --hide-histogram" > "${RESDIR}/${tag}_c2_p${p}.txt" 2>/dev/null &
    done
    
    echo "  Waiting for all procs to finish..."
    wait
    
    # Sum results
    TOTAL=0
    for f in ${RESDIR}/${tag}_c*.txt; do
        OPS=$(grep "^Totals" "$f" 2>/dev/null | awk '{print $2}')
        if [[ -n "$OPS" && "$OPS" != "0.00" ]]; then
            TOTAL=$(echo "$TOTAL + $OPS" | bc)
        fi
    done
    echo ">>> $tag TOTAL: $(printf "%'.0f" $TOTAL) ops/sec"
}

stop_cluster() {
    local -n SRVS=$1
    for s in "${SRVS[@]}"; do
        ssh "$s" 'pkill -9 redis-server; rm -rf /tmp/redis-cluster' 2>/dev/null &
    done
    wait
}

echo "============================================"
echo " DENSE CLUSTER SCALING - DUAL CLIENT TEST"
echo " $(date)"
echo "============================================"

# --- 3-node test (96 members) - use 5 procs per client ---
start_cluster SERVERS_3
run_dual_client_bench "3n_96m" "200.0.0.103" "7000" 5
stop_cluster SERVERS_3
sleep 5

# --- 4-node test (128 members) - use 5 procs per client ---
start_cluster SERVERS_4
run_dual_client_bench "4n_128m" "200.0.0.103" "7000" 5
stop_cluster SERVERS_4
sleep 5

# --- 5-node test (160 members) - use 4 procs per client (101 is also server) ---
start_cluster SERVERS_5
run_dual_client_bench "5n_160m" "200.0.0.103" "7000" 4
stop_cluster SERVERS_5

echo ""
echo "============================================"
echo " ALL DONE - $(date)"
echo "============================================"
