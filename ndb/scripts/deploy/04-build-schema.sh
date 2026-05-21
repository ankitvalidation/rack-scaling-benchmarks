#!/bin/bash
# Build TPC-C schema (100 warehouses) on the NDB Cluster
# Run from Node 1 (S0101 / 200.0.0.101)
# Only needs to run ONCE - data is shared across all SQL nodes via NDB
set -e

MGMT_NODE=200.0.0.101
HAMMERDB="/opt/HammerDB-4.12"

echo "=== Building TPC-C Schema (100 warehouses) ==="
echo "Started: $(date)"

# Create the database
echo "--- Creating tpcc database ---"
mysql -u root -phammerdb123 -h $MGMT_NODE -e "CREATE DATABASE IF NOT EXISTS tpcc;" 2>&1

# Build schema via HammerDB (runs on Node 1, hitting local mysqld)
echo "--- Running HammerDB schema build (this takes ~5-10 minutes) ---"
cd "$HAMMERDB"
./hammerdbcli auto /root/ndb-benchmark/build_tpcc_schema.tcl 2>&1 | tail -20

# Verify from both SQL nodes
echo ""
echo "--- Verifying data ---"
echo -n "  Node 1 ($MGMT_NODE): "
mysql -u root -phammerdb123 -h $MGMT_NODE -e "SELECT COUNT(*) as warehouses FROM tpcc.warehouse;" 2>&1 | grep -v Warning

echo -n "  Node 2 (200.0.0.102): "
mysql -u root -phammerdb123 -h 200.0.0.102 -e "SELECT COUNT(*) as warehouses FROM tpcc.warehouse;" 2>&1 | grep -v Warning

echo ""
echo "=== Schema build complete: $(date) ==="
echo "Next: Run 05-run-benchmark.sh"
