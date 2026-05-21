#!/bin/bash
#===============================================================================
# MySQL Configuration — matching DMR X4 config
#
# Key params matched:
#   - Buffer pool: 1400GB, 64 instances
#   - Redo log: 20GB on separate NVMe
#   - I/O: read_io=64, write_io=64, io_capacity=20000/40000, O_DIRECT
#   - ACID: flush_log_at_trx_commit=1, doublewrite=ON
#   - Dataset: 60 tables × 100M rows
#===============================================================================
set -e

SERVER="200.0.0.104"
MYSQL_PORT=3320

echo "=== Configuring MySQL on node 104 ==="

ssh "$SERVER" '
    # Stop any running MySQL
    systemctl stop mysqld 2>/dev/null || true
    pkill -9 mysqld 2>/dev/null || true
    sleep 2

    # Create directory structure
    mkdir -p /nvme1/mysql/data
    mkdir -p /nvme2/mysql/redo
    mkdir -p /nvme2/mysql/tmp
    mkdir -p /var/log/mysql
    mkdir -p /var/run/mysqld

    # Write MySQL config
    cat > /etc/my.cnf << "EOF"
[mysqld]
# --- Connection & Network ---
port=3320
bind-address=0.0.0.0
skip-name-resolve
max_connections=600
back_log=1500

# --- Directories ---
datadir=/nvme1/mysql/data
tmpdir=/nvme2/mysql/tmp
socket=/var/run/mysqld/mysqld.sock
pid-file=/var/run/mysqld/mysqld.pid
log-error=/var/log/mysql/mysqld.log

# --- InnoDB Buffer Pool ---
innodb_buffer_pool_size=1400G
innodb_buffer_pool_instances=64
innodb_buffer_pool_dump_at_shutdown=ON
innodb_buffer_pool_load_at_startup=ON
innodb_buffer_pool_dump_pct=75

# --- InnoDB Redo Log (on separate NVMe) ---
innodb_redo_log_capacity=20G
innodb_log_group_home_dir=/nvme2/mysql/redo

# --- InnoDB I/O ---
innodb_read_io_threads=64
innodb_write_io_threads=64
innodb_io_capacity=20000
innodb_io_capacity_max=40000
innodb_flush_method=O_DIRECT
innodb_use_native_aio=ON

# --- ACID ---
innodb_flush_log_at_trx_commit=1
innodb_doublewrite=ON

# --- Table/File ---
table_open_cache=10000
innodb_open_files=10000
innodb_file_per_table=ON

# --- Performance ---
innodb_thread_concurrency=0
innodb_spin_wait_delay=6
innodb_adaptive_hash_index=ON

# --- Misc ---
character-set-server=utf8mb4
default-authentication-plugin=mysql_native_password

[client]
port=3320
socket=/var/run/mysqld/mysqld.sock
EOF

    # Set ownership
    chown -R mysql:mysql /nvme1/mysql /nvme2/mysql /var/log/mysql /var/run/mysqld 2>/dev/null || true

    # Initialize if needed
    if [ ! -d "/nvme1/mysql/data/mysql" ]; then
        echo "Initializing MySQL data directory..."
        mysqld --initialize-insecure --user=root --datadir=/nvme1/mysql/data 2>&1 | tail -3
        echo "Initialized."
    else
        echo "Data directory already exists."
    fi

    # Start MySQL
    echo "Starting MySQL..."
    mysqld --user=root &
    sleep 5

    # Verify
    if mysqladmin --socket=/var/run/mysqld/mysqld.sock --port=3320 ping 2>/dev/null; then
        echo "MySQL is running on port 3320"
    else
        echo "ERROR: MySQL failed to start"
        tail -20 /var/log/mysql/mysqld.log
        exit 1
    fi

    # Create benchmark user
    mysql --socket=/var/run/mysqld/mysqld.sock --port=3320 -e "
        CREATE USER IF NOT EXISTS '"'"'bench'"'"'@'"'"'%'"'"' IDENTIFIED BY '"'"'bench123'"'"';
        GRANT ALL PRIVILEGES ON *.* TO '"'"'bench'"'"'@'"'"'%'"'"';
        CREATE DATABASE IF NOT EXISTS sbtest;
        FLUSH PRIVILEGES;
    " 2>/dev/null
    echo "User bench@% and database sbtest created."

' 2>&1 | grep -v "oneAPI\|::\|bash:\|args:\|advisor\|ccl\|compiler\|dal\|debug\|dev-\|dnnl\|dpcpp\|dpl\|ipp\|mkl\|mpi\|tbb\|umf\|vtune\|initialized\|setvars\|latest"

echo ""
echo "=== MySQL configured and running on ${SERVER}:${MYSQL_PORT} ==="
echo "    User: bench / bench123"
echo "    Database: sbtest"
echo ""
echo "Next: Run 03_prepare_data.sh to load the dataset"
