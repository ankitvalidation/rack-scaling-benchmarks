#!/bin/bash
# CPU Monitor for 6-node NDB Cluster
# Uses /proc/stat delta method
# Fixed: filters oneAPI banner from SSH output

REPORT_DIR="/root/ndb-benchmark/cpu_reports"
mkdir -p "$REPORT_DIR"
REPORT="$REPORT_DIR/cpu_report_$(date +%Y%m%d_%H%M%S).csv"
INTERVAL=5

# All nodes to monitor
declare -A NODES
NODES[node1]="200.0.0.101"
NODES[node2]="200.0.0.102"
NODES[data1]="200.0.0.103"
NODES[data2]="200.0.0.104"
NODES[data3]="200.0.0.106"
NODES[data4]="200.0.0.107"

# Header
echo "timestamp,node,cpu_used_pct" > "$REPORT"

TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

get_cpu_stat() {
    local ip="$1" outfile="$2"
    if [[ "$ip" == "200.0.0.101" ]]; then
        grep '^cpu ' /proc/stat > "$outfile"
    else
        ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no root@"$ip" "grep '^cpu ' /proc/stat" 2>/dev/null | grep '^cpu ' > "$outfile"
    fi
}

# Initialize previous readings
for name in node1 node2 data1 data2 data3 data4; do
    ip="${NODES[$name]}"
    get_cpu_stat "$ip" "$TMPDIR/prev_$name"
done

sleep $INTERVAL

while true; do
    TS=$(date +%H:%M:%S)

    for name in node1 node2 data1 data2 data3 data4; do
        ip="${NODES[$name]}"
        get_cpu_stat "$ip" "$TMPDIR/cur_$name"
        [[ ! -s "$TMPDIR/cur_$name" ]] && continue

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

        cp "$TMPDIR/cur_$name" "$TMPDIR/prev_$name"
    done

    sleep $INTERVAL
done
