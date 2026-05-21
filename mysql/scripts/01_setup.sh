#!/bin/bash
#===============================================================================
# MySQL 8.0 Scaling Benchmark — Setup Script
#
# Replicates the DMR X4 experiment on rack nodes:
#   Server: Node 104 (160 cores, 1.5TB RAM, 2×7TB NVMe)
#   Client: Node 101 (160 cores)
#
# Will run two configurations:
#   1. Pinned (match): MySQL on cores 0-8 (9 cores, matching their config)
#   2. Unconstrained: MySQL uses all 160 cores (showcase full hardware)
#
# Dataset: 60 tables × 100M rows (~1.56TB) — exceeds buffer pool
#===============================================================================
set -e

SERVER="200.0.0.104"
CLIENT="200.0.0.101"  # local
MYSQL_PORT=3320

echo "==============================================================================="
echo " MySQL 8.0 Benchmark Setup"
echo " Server: ${SERVER} (node 104)"
echo " Client: ${CLIENT} (node 101, local)"
echo " $(date)"
echo "==============================================================================="

#-------------------------------------------------------------------------------
echo ""
echo "=== Step 1: Mount NVMe drives on server (node 104) ==="

ssh "$SERVER" '
    # Format and mount nvme1n1p3 for data
    if ! mountpoint -q /nvme1; then
        mkdir -p /nvme1
        mkfs.xfs -f /dev/nvme1n1p3 2>/dev/null || true
        mount /dev/nvme1n1p3 /nvme1
        echo "Mounted /dev/nvme1n1p3 → /nvme1 (data)"
    else
        echo "/nvme1 already mounted"
    fi

    # Format and mount nvme2n1p1 for redo+tmp
    if ! mountpoint -q /nvme2; then
        mkdir -p /nvme2
        mkfs.xfs -f /dev/nvme2n1p1 2>/dev/null || true
        mount /dev/nvme2n1p1 /nvme2
        echo "Mounted /dev/nvme2n1p1 → /nvme2 (redo+tmp)"
    else
        echo "/nvme2 already mounted"
    fi

    df -h /nvme1 /nvme2
' 2>&1 | grep -v "oneAPI\|::\|bash:\|args:\|advisor\|ccl\|compiler\|dal\|debug\|dev-\|dnnl\|dpcpp\|dpl\|ipp\|mkl\|mpi\|tbb\|umf\|vtune\|initialized\|setvars\|latest"

#-------------------------------------------------------------------------------
echo ""
echo "=== Step 2: Install MySQL 8.0 on server (node 104) ==="

ssh "$SERVER" '
    if command -v mysqld &>/dev/null; then
        echo "MySQL already installed: $(mysqld --version 2>&1 | head -1)"
    else
        echo "Installing MySQL 8.0..."
        dnf install -y --disablerepo=grafana mysql-server mysql 2>&1 | tail -5
    fi
' 2>&1 | grep -v "oneAPI\|::\|bash:\|args:\|advisor\|ccl\|compiler\|dal\|debug\|dev-\|dnnl\|dpcpp\|dpl\|ipp\|mkl\|mpi\|tbb\|umf\|vtune\|initialized\|setvars\|latest"

#-------------------------------------------------------------------------------
echo ""
echo "=== Step 3: Install sysbench on client (local, node 101) ==="

if command -v sysbench &>/dev/null; then
    echo "sysbench already installed: $(sysbench --version)"
else
    echo "Installing sysbench..."
    dnf install -y --disablerepo=grafana sysbench 2>&1 | tail -5
fi

echo ""
echo "=== Setup complete ==="
echo "Next: Run mysql_configure.sh to configure and start MySQL"
