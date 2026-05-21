#!/bin/bash
# Install MySQL NDB Cluster 8.4 LTS and HammerDB on all 6 nodes (CentOS Stream 10)
# Run this from Node 1 (S0101 / 200.0.0.101) after SSH keys are set up
set -e

# Node roles
MGMT_NODE=200.0.0.101       # S0101: ndb_mgmd + mysqld + HammerDB
SQL_NODE=200.0.0.102         # S0102: mysqld + HammerDB
DATA_NODES=(200.0.0.103 200.0.0.104 200.0.0.106 200.0.0.107)  # S0103-S0107
ALL_NODES=(200.0.0.101 200.0.0.102 200.0.0.103 200.0.0.104 200.0.0.106 200.0.0.107)
SQL_NODES=($MGMT_NODE $SQL_NODE)
HAMMERDB_NODES=($MGMT_NODE $SQL_NODE)

HAMMERDB_VERSION="4.12"
HAMMERDB_URL="https://github.com/TPC-Council/HammerDB/releases/download/v${HAMMERDB_VERSION}/HammerDB-${HAMMERDB_VERSION}-Linux.tar.gz"

install_mysql_ndb() {
    local ip=$1
    local role=$2
    echo ""
    echo "============================================"
    echo "=== Installing MySQL NDB on $ip ($role) ==="
    echo "============================================"

    ssh root@$ip bash -s "$role" << 'INSTALL_EOF'
        ROLE=$1

        # Check if already installed
        if rpm -qa | grep -q mysql-cluster-community; then
            echo "MySQL NDB Cluster already installed, skipping"
            exit 0
        fi

        echo "--- Removing MariaDB if present ---"
        dnf remove -y mariadb* 2>/dev/null || true

        echo "--- Adding MySQL yum repository ---"
        if ! rpm -qa | grep -q mysql84-community-release; then
            rpm -Uvh https://dev.mysql.com/get/mysql84-community-release-el10-1.noarch.rpm || true
        fi

        # Enable NDB Cluster repo, disable standalone MySQL
        dnf config-manager --disable mysql-8.4-lts-community 2>/dev/null || true
        dnf config-manager --enable mysql-cluster-8.4-lts-community 2>/dev/null || true

        echo "--- Installing packages for role: $ROLE ---"
        case "$ROLE" in
            mgmt_sql)
                # Management server + SQL node + client
                dnf install -y --nogpgcheck mysql-cluster-community-management-server \
                    mysql-cluster-community-server \
                    mysql-cluster-community-client \
                    mysql-cluster-community-data-node \
                    mysql-cluster-community-libs \
                    mysql-cluster-community-common \
                    mysql-cluster-community-ndbclient \
                    mysql-cluster-community-client-plugins \
                    mysql-cluster-community-icu-data-files
                ;;
            sql)
                # SQL node + client only
                dnf install -y --nogpgcheck mysql-cluster-community-server \
                    mysql-cluster-community-client \
                    mysql-cluster-community-data-node \
                    mysql-cluster-community-libs \
                    mysql-cluster-community-common \
                    mysql-cluster-community-ndbclient \
                    mysql-cluster-community-client-plugins \
                    mysql-cluster-community-icu-data-files
                ;;
            data)
                # Data node only (ndbmtd) + client for debugging
                dnf install -y --nogpgcheck mysql-cluster-community-data-node \
                    mysql-cluster-community-client \
                    mysql-cluster-community-libs \
                    mysql-cluster-community-common \
                    mysql-cluster-community-ndbclient \
                    mysql-cluster-community-client-plugins \
                    mysql-cluster-community-icu-data-files
                ;;
        esac

        # Stop MySQL from auto-starting (we'll start it manually after config)
        systemctl stop mysqld 2>/dev/null || true
        systemctl disable mysqld 2>/dev/null || true

        echo "--- MySQL NDB installed on $(hostname) ---"
INSTALL_EOF
}

install_hammerdb() {
    local ip=$1
    echo ""
    echo "============================================"
    echo "=== Installing HammerDB on $ip ==="
    echo "============================================"

    ssh root@$ip bash -s "$HAMMERDB_URL" "$HAMMERDB_VERSION" << 'HAMMER_EOF'
        HAMMERDB_URL=$1
        HAMMERDB_VERSION=$2

        if [[ -d /opt/HammerDB-${HAMMERDB_VERSION} ]]; then
            echo "HammerDB already installed at /opt/HammerDB-${HAMMERDB_VERSION}"
            exit 0
        fi

        echo "--- Downloading HammerDB ${HAMMERDB_VERSION} ---"
        cd /tmp
        wget -q "$HAMMERDB_URL" -O HammerDB-${HAMMERDB_VERSION}-Linux.tar.gz

        echo "--- Extracting to /opt ---"
        tar xzf HammerDB-${HAMMERDB_VERSION}-Linux.tar.gz -C /opt/

        echo "--- Verifying ---"
        /opt/HammerDB-${HAMMERDB_VERSION}/hammerdbcli --version 2>/dev/null | head -1 || echo "HammerDB installed"

        rm -f /tmp/HammerDB-${HAMMERDB_VERSION}-Linux.tar.gz
        echo "--- HammerDB installed on $(hostname) ---"
HAMMER_EOF
}

create_data_dirs() {
    local ip=$1
    echo "Creating data directory on $ip..."
    ssh root@$ip "mkdir -p /data/ndb-data && chown -R mysql:mysql /data/ndb-data 2>/dev/null || true"
}

# ============================================================
echo "########################################"
echo "# NDB 6-Node Cluster Install"
echo "# Started: $(date)"
echo "########################################"

# Step 1: Install on management + SQL node (S0101)
install_mysql_ndb $MGMT_NODE "mgmt_sql"

# Step 2: Install on second SQL node (S0102)
install_mysql_ndb $SQL_NODE "sql"

# Step 3: Install on data nodes (S0103, S0104, S0106, S0107)
for dn in "${DATA_NODES[@]}"; do
    install_mysql_ndb $dn "data"
done

# Step 4: Install HammerDB on SQL nodes
for hn in "${HAMMERDB_NODES[@]}"; do
    install_hammerdb $hn
done

# Step 5: Create data directories on data nodes
for dn in "${DATA_NODES[@]}"; do
    create_data_dirs $dn
done

# Step 6: Create mgmt directory on S0101
ssh root@$MGMT_NODE "mkdir -p /var/lib/mysql-cluster"

echo ""
echo "########################################"
echo "# Install complete: $(date)"
echo "########################################"
echo ""
echo "=== Verification ==="
for ip in "${ALL_NODES[@]}"; do
    echo -n "$ip: "
    ssh root@$ip "which ndbmtd ndb_mgmd mysqld 2>/dev/null | tr '\n' ' '; echo ''; rpm -qa 2>/dev/null | grep mysql-cluster | wc -l | xargs -I{} echo '({} packages)'" 2>/dev/null
done
echo ""
echo "Next: Run 02-deploy-configs.sh"
