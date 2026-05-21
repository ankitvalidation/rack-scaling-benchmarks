#!/bin/bash
# Stop the entire NDB Cluster gracefully
# Run from Node 1 (S0101 / 200.0.0.101)

MGMT_NODE=200.0.0.101
SQL_NODE=200.0.0.102
DATA_NODES=(200.0.0.103 200.0.0.104 200.0.0.106 200.0.0.107)

echo "=== Stopping NDB Cluster ==="

# Stop MySQL on both SQL nodes
echo "--- Stopping MySQL ---"
systemctl stop mysql 2>/dev/null || true
ssh root@$SQL_NODE "systemctl stop mysql" 2>/dev/null || true
echo "MySQL stopped"

# Stop all NDB nodes via management command
echo "--- Stopping NDB nodes ---"
ndb_mgm -e "ALL STOP" 2>&1
sleep 5

# Force-kill any remaining processes
echo "--- Cleanup ---"
pkill -9 -f ndb_mgmd 2>/dev/null || true
for dn in "${DATA_NODES[@]}"; do
    ssh root@$dn "pkill -9 ndbmtd 2>/dev/null" || true
done
sleep 2

echo "=== Cluster stopped ==="
