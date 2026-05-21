#!/bin/bash
# v12b: Dense cluster with proper dual-client (fixed SSH)
RESDIR="/root/redis-scaling-test/results_v12b"
mkdir -p "$RESDIR"
MEMTIER="/usr/local/bin/memtier_benchmark"
INST=32
PORT=7000

start_cluster() {
    local nodes=("$@")
    local N=${#nodes[@]}
    for s in "${nodes[@]}"; do
        ssh -T "$s" "pkill -9 redis-server; rm -rf /tmp/redis-cluster; sleep 0.3; mkdir -p /tmp/redis-cluster
        for i in \$(seq 0 $((INST-1))); do P=\$((${PORT}+i)); mkdir -p /tmp/redis-cluster/\$P
            redis-server --port \$P --bind 0.0.0.0 --protected-mode no --dir /tmp/redis-cluster/\$P \
                --cluster-enabled yes --cluster-config-file /tmp/redis-cluster/\$P/nodes.conf \
                --cluster-node-timeout 5000 --appendonly no --save '' --maxclients 200000 \
                --tcp-backlog 65535 --hz 100 --daemonize yes 2>/dev/null
        done; pgrep -c redis-server" 2>/dev/null &
    done
    wait; sleep 2
    
    CNODES=""
    for s in "${nodes[@]}"; do for p in $(seq 0 $((INST-1))); do CNODES+=" ${s}:$((PORT+p))"; done; done
    redis-cli --cluster create $CNODES --cluster-replicas 0 --cluster-yes 2>&1 | tail -2
    sleep 5
    redis-cli -h "${nodes[0]}" -p $PORT cluster info 2>/dev/null | grep "cluster_state"
}

bench() {
    local tag=$1 entry=$2 c1_procs=$3 c2_procs=$4
    echo "  BENCH $tag: c1=${c1_procs}procs c2=${c2_procs}procs"
    
    # Client 1 (local, node 101)
    for p in $(seq 1 $c1_procs); do
        $MEMTIER --server=$entry --port=$PORT \
            --protocol=redis --cluster-mode \
            --threads=32 --clients=5 --pipeline=20 \
            --data-size=256 --ratio=1:1 --test-time=60 \
            --key-minimum=1 --key-maximum=10000000 --key-pattern=R:R \
            --hide-histogram > "${RESDIR}/${tag}_c1_p${p}.txt" 2>/dev/null &
    done
    
    # Client 2 (node 102, via SSH -T with full path, no bashrc)
    for p in $(seq 1 $c2_procs); do
        ssh -T 200.0.0.102 "$MEMTIER --server=$entry --port=$PORT \
            --protocol=redis --cluster-mode \
            --threads=32 --clients=5 --pipeline=20 \
            --data-size=256 --ratio=1:1 --test-time=60 \
            --key-minimum=1 --key-maximum=10000000 --key-pattern=R:R \
            --hide-histogram 2>/dev/null" > "${RESDIR}/${tag}_c2_p${p}.txt" 2>/dev/null &
    done
    
    wait
    
    TOTAL=0; COUNT=0
    for f in ${RESDIR}/${tag}_c*.txt; do
        OPS=$(grep "^Totals" "$f" 2>/dev/null | awk '{print $2}')
        if [[ -n "$OPS" && "$OPS" != "0.00" ]]; then
            TOTAL=$(echo "$TOTAL + $OPS" | bc); COUNT=$((COUNT+1))
        fi
    done
    echo ">>> $tag: $(printf "%'.0f" $TOTAL) ops/sec [$COUNT procs contributed]"
}

stop_all() {
    for s in "$@"; do ssh -T "$s" 'pkill -9 redis-server; rm -rf /tmp/redis-cluster' 2>/dev/null & done
    wait
}

echo "=== v12b Dense Cluster Dual-Client Test - $(date) ==="

# 3-node (96 members): servers=103,104,107 clients=101,102
echo "--- 3-node × 32 inst (96 members) ---"
start_cluster 200.0.0.103 200.0.0.104 200.0.0.107
bench "3n" "200.0.0.103" 5 5
stop_all 200.0.0.103 200.0.0.104 200.0.0.107
sleep 3

# 5-node (160 members): servers=103,104,107,102,101, clients=101,102 (co-located)
echo "--- 5-node × 32 inst (160 members) ---"
start_cluster 200.0.0.103 200.0.0.104 200.0.0.107 200.0.0.102 200.0.0.101
bench "5n" "200.0.0.103" 5 4
stop_all 200.0.0.103 200.0.0.104 200.0.0.107 200.0.0.102 200.0.0.101

echo "=== DONE - $(date) ==="
