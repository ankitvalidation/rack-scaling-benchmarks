#!/usr/bin/env python3
"""Generate a many-to-many Redis client-server topology diagram."""

import matplotlib.pyplot as plt
import matplotlib.patches as mpatches
from matplotlib.patches import FancyBboxPatch, FancyArrowPatch
import numpy as np

fig, ax = plt.subplots(1, 1, figsize=(14, 9))
ax.set_xlim(0, 14)
ax.set_ylim(0, 9)
ax.axis('off')
ax.set_facecolor('#0d1117')
fig.patch.set_facecolor('#0d1117')

# Title
ax.text(7, 8.5, 'Redis Benchmark: Many-to-Many Client ↔ Server Topology',
        ha='center', va='center', fontsize=16, fontweight='bold', color='white')
ax.text(7, 8.0, 'Dual 200 Gbps NICs per Node  •  Fire-and-Forget Architecture  •  17.3M ops/sec Peak',
        ha='center', va='center', fontsize=9, color='#8b949e')

# Define nodes
clients = [
    {'name': 'Node 101\n(Client 1)', 'x': 2.5, 'y': 5.5, 'ip1': '200.0.0.101', 'ip2': '220.0.0.101', 'procs': '32 memtier\nprocesses'},
    {'name': 'Node 102\n(Client 2)', 'x': 2.5, 'y': 2.5, 'ip1': '200.0.0.102', 'ip2': '220.0.0.102', 'procs': '32 memtier\nprocesses'},
]

servers = [
    {'name': 'Node 103\n(Server 1)', 'x': 11, 'y': 6.5, 'ip1': '200.0.0.103', 'ip2': '220.0.0.103', 'instances': '32 Redis\ninstances'},
    {'name': 'Node 104\n(Server 2)', 'x': 11, 'y': 4.0, 'ip1': '200.0.0.104', 'ip2': '220.0.0.104', 'instances': '32 Redis\ninstances'},
    {'name': 'Node 107\n(Server 3)', 'x': 11, 'y': 1.5, 'ip1': '200.0.0.107', 'ip2': '220.0.0.107', 'instances': '32 Redis\ninstances'},
]

# Draw client boxes
for c in clients:
    box = FancyBboxPatch((c['x'] - 1.3, c['y'] - 0.9), 2.6, 1.8,
                         boxstyle="round,pad=0.1", facecolor='#1f3a5f', edgecolor='#58a6ff', linewidth=2)
    ax.add_patch(box)
    ax.text(c['x'], c['y'] + 0.4, c['name'], ha='center', va='center', fontsize=10, fontweight='bold', color='#58a6ff')
    ax.text(c['x'], c['y'] - 0.15, c['procs'], ha='center', va='center', fontsize=7.5, color='#c9d1d9')
    ax.text(c['x'], c['y'] - 0.6, f"NIC1: {c['ip1']}\nNIC2: {c['ip2']}", ha='center', va='center', fontsize=6.5, color='#8b949e')

# Draw server boxes
for s in servers:
    box = FancyBboxPatch((s['x'] - 1.3, s['y'] - 0.9), 2.6, 1.8,
                         boxstyle="round,pad=0.1", facecolor='#1a3d2e', edgecolor='#3fb950', linewidth=2)
    ax.add_patch(box)
    ax.text(s['x'], s['y'] + 0.4, s['name'], ha='center', va='center', fontsize=10, fontweight='bold', color='#3fb950')
    ax.text(s['x'], s['y'] - 0.15, s['instances'], ha='center', va='center', fontsize=7.5, color='#c9d1d9')
    ax.text(s['x'], s['y'] - 0.6, f"NIC1: {s['ip1']}\nNIC2: {s['ip2']}", ha='center', va='center', fontsize=6.5, color='#8b949e')

# Draw connections (many-to-many)
# NIC1 connections (200.x network) - solid orange
# NIC2 connections (220.x network) - dashed cyan
nic1_color = '#f0883e'  # orange for 200.x
nic2_color = '#a371f7'  # purple for 220.x

for c in clients:
    for s in servers:
        # NIC1 (200.x) - upper connection
        ax.annotate('', xy=(s['x'] - 1.3, s['y'] + 0.15),
                    xytext=(c['x'] + 1.3, c['y'] + 0.15),
                    arrowprops=dict(arrowstyle='->', color=nic1_color, lw=1.5, alpha=0.7))
        # NIC2 (220.x) - lower connection
        ax.annotate('', xy=(s['x'] - 1.3, s['y'] - 0.15),
                    xytext=(c['x'] + 1.3, c['y'] - 0.15),
                    arrowprops=dict(arrowstyle='->', color=nic2_color, lw=1.5, alpha=0.7,
                                    linestyle='dashed'))

# Network labels in the middle
ax.text(6.8, 6.8, '200 Gbps', ha='center', va='center', fontsize=8, color=nic1_color, fontweight='bold', rotation=5)
ax.text(6.8, 6.4, '200 Gbps', ha='center', va='center', fontsize=8, color=nic2_color, fontweight='bold', rotation=-2)

# Legend
legend_y = 0.6
ax.plot([1.5, 2.2], [legend_y, legend_y], color=nic1_color, lw=2, solid_capstyle='round')
ax.text(2.4, legend_y, 'NIC1 (200.0.0.x) — 200 Gbps', va='center', fontsize=8, color=nic1_color)

ax.plot([6.5, 7.2], [legend_y, legend_y], color=nic2_color, lw=2, linestyle='dashed')
ax.text(7.4, legend_y, 'NIC2 (220.0.0.x) — 200 Gbps', va='center', fontsize=8, color=nic2_color)

# Stats box
stats_box = FancyBboxPatch((4.5, 3.2), 3.6, 1.8,
                           boxstyle="round,pad=0.15", facecolor='#21262d', edgecolor='#484f58', linewidth=1.5)
ax.add_patch(stats_box)
ax.text(6.3, 4.7, '⚡ Peak Performance', ha='center', va='center', fontsize=9, fontweight='bold', color='#f0883e')
ax.text(6.3, 4.3, '17.3M ops/sec (4KB values)', ha='center', va='center', fontsize=8, color='#c9d1d9')
ax.text(6.3, 3.95, '155 Gbps wire throughput', ha='center', va='center', fontsize=8, color='#c9d1d9')
ax.text(6.3, 3.6, '64 parallel processes total', ha='center', va='center', fontsize=8, color='#c9d1d9')
ax.text(6.3, 3.3, '2 clients × 3 servers × dual NIC', ha='center', va='center', fontsize=7.5, color='#8b949e')

# Hardware label
ax.text(7, 0.2, '160-core Intel Xeon (1 socket, no HT)  •  1.5 TiB RAM  •  Mellanox ConnectX-6 Dx 200G NICs',
        ha='center', va='center', fontsize=7.5, color='#484f58')

plt.tight_layout(pad=0.5)
plt.savefig('/root/rack-scaling-benchmarks/redis/diagrams/redis_topology.png', dpi=150, bbox_inches='tight',
            facecolor='#0d1117', edgecolor='none')
print("Saved: /root/rack-scaling-benchmarks/redis/diagrams/redis_topology.png")
