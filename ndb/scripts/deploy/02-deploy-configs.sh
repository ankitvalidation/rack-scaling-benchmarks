#!/bin/bash
# Deploy NDB config files to all 6 nodes (CentOS Stream 10)
# Run this from Node 1 (S0101 / 200.0.0.101)
# Uses SSH pipe instead of scp (remote .bashrc oneAPI banner breaks SCP)
set -e

DEPLOY_DIR="$(cd "$(dirname "$0")" && pwd)"
MGMT_NODE=200.0.0.101
SQL_NODE=200.0.0.102
DATA_NODES=(200.0.0.103 200.0.0.104 200.0.0.106 200.0.0.107)

# Helper: transfer file via SSH pipe (scp breaks due to oneAPI .bashrc output)
ssh_copy() {
    local src="$1" dst_host="$2" dst_path="$3"
    cat "$src" | ssh root@"$dst_host" "cat > '$dst_path'" 2>/dev/null
}

echo "=== Deploying NDB Cluster configs ==="

# 1. Deploy config.ini to management node
echo "--- config.ini -> $MGMT_NODE ---"
ssh root@$MGMT_NODE "mkdir -p /var/lib/mysql-cluster" 2>/dev/null
ssh_copy "$DEPLOY_DIR/config.ini" $MGMT_NODE /var/lib/mysql-cluster/config.ini

# 2. Deploy mysqld.cnf to SQL nodes (CentOS uses /etc/my.cnf)
echo "--- mysqld-node1.cnf -> $MGMT_NODE:/etc/my.cnf ---"
ssh_copy "$DEPLOY_DIR/mysqld-node1.cnf" $MGMT_NODE /etc/my.cnf

echo "--- mysqld-node2.cnf -> $SQL_NODE:/etc/my.cnf ---"
ssh_copy "$DEPLOY_DIR/mysqld-node2.cnf" $SQL_NODE /etc/my.cnf

# 3. Ensure required directories exist on SQL nodes
for ip in $MGMT_NODE $SQL_NODE; do
    ssh root@$ip "mkdir -p /var/run/mysqld /var/log/mysql && chown mysql:mysql /var/run/mysqld /var/log/mysql 2>/dev/null || true" 2>/dev/null
done

# 4. Deploy HammerDB scripts to SQL nodes
for ip in $MGMT_NODE $SQL_NODE; do
    echo "--- HammerDB scripts -> $ip ---"
    ssh root@$ip "mkdir -p /root/ndb-benchmark" 2>/dev/null
    ssh_copy "$DEPLOY_DIR/build_tpcc_schema.tcl" $ip /root/ndb-benchmark/build_tpcc_schema.tcl
    ssh_copy "$DEPLOY_DIR/run_benchmark_256vu.tcl" $ip /root/ndb-benchmark/run_benchmark_256vu.tcl
done

# 5. Customize HammerDB scripts for each SQL node's local connection
echo "--- Customizing HammerDB scripts ---"
ssh root@$MGMT_NODE "sed -i 's/MYSQL_HOST/200.0.0.101/g' /root/ndb-benchmark/*.tcl" 2>/dev/null
ssh root@$SQL_NODE "sed -i 's/MYSQL_HOST/200.0.0.102/g' /root/ndb-benchmark/*.tcl" 2>/dev/null

# 6. Deploy CPU monitor to management node
echo "--- CPU monitor -> $MGMT_NODE ---"
ssh_copy "$DEPLOY_DIR/cpu_monitor.sh" $MGMT_NODE /root/ndb-benchmark/cpu_monitor.sh
ssh root@$MGMT_NODE "chmod +x /root/ndb-benchmark/cpu_monitor.sh" 2>/dev/null

# 7. Deploy startup/shutdown scripts
echo "--- Cluster scripts -> $MGMT_NODE ---"
for script in 03-start-cluster.sh 04-build-schema.sh 05-run-benchmark.sh 06-stop-cluster.sh; do
    ssh_copy "$DEPLOY_DIR/$script" $MGMT_NODE "/root/ndb-benchmark/$script"
done
ssh root@$MGMT_NODE "chmod +x /root/ndb-benchmark/*.sh" 2>/dev/null

echo ""
echo "=== Config deployment complete ==="
echo "Next: Run 03-start-cluster.sh"
