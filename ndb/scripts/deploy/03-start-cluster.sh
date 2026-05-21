#!/bin/bash
# Start the 6-node NDB Cluster
# Run this from Node 1 (S0101 / 200.0.0.101)
set -e

MGMT_NODE=200.0.0.101
SQL_NODE=200.0.0.102
DATA_NODES=(200.0.0.103 200.0.0.104 200.0.0.106 200.0.0.107)

echo "=== Starting NDB Cluster (6-node) ==="
echo "Started: $(date)"

# Step 1: Start management server
echo ""
echo "--- Step 1: Starting ndb_mgmd on $MGMT_NODE ---"
ndb_mgmd --config-file=/var/lib/mysql-cluster/config.ini --initial
sleep 3
echo "Management server started"

# Step 2: Start all 4 data nodes in parallel
echo ""
echo "--- Step 2: Starting data nodes ---"
for dn in "${DATA_NODES[@]}"; do
    echo "  Starting ndbmtd on $dn..."
    ssh root@$dn "ndbmtd --ndb-connectstring=$MGMT_NODE:1186 --initial" &
done
wait
echo "All data node start commands issued"

# Step 3: Wait for all data nodes to be fully started
echo ""
echo "--- Step 3: Waiting for data nodes ---"
for i in $(seq 1 120); do
    status=$(ndb_mgm -e "ALL STATUS" 2>&1)
    started=$(echo "$status" | grep -c "started" || true)
    if [[ $started -ge 4 ]]; then
        echo "All 4 data nodes are started!"
        echo "$status" | grep "Node [2-5]"
        break
    fi
    if [[ $((i % 10)) -eq 0 ]]; then
        echo "Waiting ($i)..."
        echo "$status" | grep "Node [2-5]"
    fi
    sleep 5
done

# Verify all 4 are up
status=$(ndb_mgm -e "ALL STATUS" 2>&1)
started=$(echo "$status" | grep -c "started" || true)
if [[ $started -lt 4 ]]; then
    echo "ERROR: Only $started/4 data nodes started. Check logs."
    echo "$status"
    exit 1
fi

# Step 4: Start MySQL on both SQL nodes
echo ""
echo "--- Step 4: Starting MySQL on SQL nodes ---"

# Ensure required directories exist
for ip in $MGMT_NODE $SQL_NODE; do
    ssh root@$ip "mkdir -p /var/run/mysqld && chown mysql:mysql /var/run/mysqld" 2>/dev/null
done

echo "  Starting mysqld on $MGMT_NODE..."
systemctl start mysqld
sleep 5

echo "  Starting mysqld on $SQL_NODE..."
ssh root@$SQL_NODE "systemctl start mysqld"
sleep 5

# Step 5: Handle initial root password (CentOS RPM generates random temp password)
echo ""
echo "--- Step 5: Setting up MySQL root access ---"
TEMP_PASS=$(grep 'temporary password' /var/log/mysqld.log 2>/dev/null | tail -1 | awk '{print $NF}')
if [[ -n "$TEMP_PASS" ]]; then
    echo "  Found temporary password, resetting root password..."
    mysqladmin -u root -p"$TEMP_PASS" password 'hammerdb123' 2>/dev/null || true
    # Also try ALTER USER if mysqladmin fails
    mysql -u root -p"$TEMP_PASS" --connect-expired-password -e "ALTER USER 'root'@'localhost' IDENTIFIED BY 'hammerdb123';" 2>/dev/null || true
fi
# Also try with hammerdb123 in case it was already set
mysql -u root -p'hammerdb123' -e "SELECT 1;" 2>/dev/null || echo "  Warning: root login not working yet"

# Step 6: Verify MySQL connectivity
echo ""
echo "--- Step 6: Verifying MySQL ---"
echo -n "  Node 1 ($MGMT_NODE): "
mysql -u root -p'hammerdb123' -e "SELECT 'OK' as status;" 2>&1 | grep OK || echo "FAILED"

echo -n "  Node 2 ($SQL_NODE): "
ssh root@$SQL_NODE "mysql -u root -p'hammerdb123' -e \"SELECT 'OK' as status;\"" 2>&1 | grep OK || echo "FAILED"

# Step 7: Create root user accessible from both SQL nodes
echo ""
echo "--- Step 7: Setting up root user for remote access ---"
mysql -u root -p'hammerdb123' -e "
CREATE USER IF NOT EXISTS 'root'@'%' IDENTIFIED BY 'hammerdb123';
GRANT ALL PRIVILEGES ON *.* TO 'root'@'%' WITH GRANT OPTION;
FLUSH PRIVILEGES;
" 2>/dev/null

# Step 7: Show cluster status
echo ""
echo "=== Cluster Status ==="
ndb_mgm -e "SHOW" 2>&1
echo ""
echo "=== NDB Cluster started successfully ==="
echo "  Management: $MGMT_NODE:1186"
echo "  SQL Node 1: $MGMT_NODE:3306"
echo "  SQL Node 2: $SQL_NODE:3306"
echo "  Data Nodes: ${DATA_NODES[*]}"
echo ""
echo "Next: Run 04-build-schema.sh"
