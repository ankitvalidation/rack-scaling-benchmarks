#!/bin/bash
#===============================================================================
# Prepare Dataset: 60 tables × 100M rows (~1.56TB)
#
# This matches the DMR X4 dataset that exceeds buffer pool (1400GB)
# so reads hit NVMe after warmup fills the buffer pool.
#
# WARNING: This will take several hours to load.
#===============================================================================
set -e

SERVER="200.0.0.104"
MYSQL_PORT=3320
TABLES=60
ROWS=100000000  # 100M per table

echo "==============================================================================="
echo " Preparing sysbench dataset"
echo " ${TABLES} tables × ${ROWS} rows = $(echo "$TABLES * $ROWS" | bc) total rows"
echo " Expected size: ~1.56 TB on disk"
echo " Target: ${SERVER}:${MYSQL_PORT}/sbtest"
echo " $(date)"
echo "==============================================================================="
echo ""
echo " WARNING: This will take several hours. Running with 32 threads."
echo ""

# Use multiple threads for faster loading
sysbench oltp_read_only \
    --mysql-host="$SERVER" \
    --mysql-port="$MYSQL_PORT" \
    --mysql-user=bench \
    --mysql-password=bench123 \
    --mysql-db=sbtest \
    --tables="$TABLES" \
    --table-size="$ROWS" \
    --threads=32 \
    prepare

echo ""
echo "=== Dataset preparation complete — $(date) ==="
echo "Next: Run 04_benchmark.sh to execute the thread sweep"
