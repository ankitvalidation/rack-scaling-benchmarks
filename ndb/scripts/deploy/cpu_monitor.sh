#!/bin/bash
# CPU Monitor for 6-node NDB Cluster
# Uses /proc/stat delta method (proven accurate from 3-node testing)
# Run from Node 1 (S0101 / 200.0.0.101)

REPORT_DIR="/root/ndb-benchmark/cpu_reports"
mkdir -p "$REPORT_DIR"
REPORT="$REPORT_DIR/cpu_report_$(date +%Y%m%d_%H%M%S).csv"
INTERVAL=5

# All nodes to monitor
declare -A NODES
NODES[node1]="200.0.0.101"    # mgmd + mysqld + HammerDB
NODES[node2]="200.0.0.102"    # mysqld + HammerDB
NODES[data1]="200.0.0.103"    # ndbmtd
NODES[data2]="200.0.0.104"    # ndbmtd
NODES[data3]="200.0.0.106"    # ndbmtd
NODES[data4]="200.0.0.107"    # ndbmtd

# Header
echo "timestamp,node,cpu_used_pct" > "$REPORT"

# Temp files for /proc/stat snapshots
TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

# Initialize previous readings
for name in "${!NODES[@]}"; do
    ip="${NODES[$name]}"
    if [[ "$ip" == "200.0.0.101" ]]; then
        grep 'cpu ' /proc/stat > "$TMPDIR/prev_$name"
    else
        ssh -o ConnectTimeout=3 root@$ip "grep 'cpu ' /proc/stat" > "$TMPDIR/prev_$name" 2>/dev/null
    fi
done

sleep $INTERVAL

while true; do
    TS=$(date +%H:%M:%S)

    for name in node1 node2 data1 data2 data3 data4; do
        ip="${NODES[$name]}"

        # Get current /proc/stat
        if [[ "$ip" == "200.0.0.101" ]]; then
            grep 'cpu ' /proc/stat > "$TMPDIR/cur_$name"
        else
            ssh -o ConnectTimeout=3 root@$ip "grep 'cpu ' /proc/stat" > "$TMPDIR/cur_$name" 2>/dev/null || continue
        fi

        # Calculate delta
        prev=($(awk '{print $2,$3,$4,$5,$6,$7,$8}' "$TMPDIR/prev_$name"))
        curr=($(awk '{print $2,$3,$4,$5,$6,$7,$8}' "$TMPDIR/cur_$name"))

        if [[ ${#prev[@]} -eq 7 && ${#curr[@]} -eq 7 ]]; then
            d_user=$((curr[0] - prev[0]))
            d_nice=$((curr[1] - prev[1]))
            d_sys=$((curr[2] - prev[2]))
            d_idle=$((curr[3] - prev[3]))
            d_iow=$((curr[4] - prev[4]))
            d_irq=$((curr[5] - prev[5]))
            d_sirq=$((curr[6] - prev[6]))

            d_total=$((d_user + d_nice + d_sys + d_idle + d_iow + d_irq + d_sirq))
            d_used=$((d_total - d_idle))

            if [[ $d_total -gt 0 ]]; then
                pct=$(awk "BEGIN {printf \"%.1f\", $d_used * 100.0 / $d_total}")
                echo "$TS,$name,$pct" >> "$REPORT"
            fi
        fi

        # Rotate
        cp "$TMPDIR/cur_$name" "$TMPDIR/prev_$name"
    done

    sleep $INTERVAL
done
