#!/usr/bin/env python3
"""Generate a many-to-many Redis client-server topology diagram with storage."""

import matplotlib.pyplot as plt
import matplotlib.patches as mpatches
from matplotlib.patches import FancyBboxPatch
import numpy as np

fig, ax = plt.subplots(1, 1, figsize=(14, 10))
ax.set_xlim(0, 14)
ax.set_ylim(0, 10)
ax.axis('off')
ax.set_facecolor('#0d1117')
fig.patch.set_facecolor('#0d1117')

# Title
ax.text(7, 9.5, 'Redis Benchmark: Many-to-Many Client \u2194 Server Topology',
        ha='center', va='center', fontsize=16, fontweight='bold', color='white')
ax.text(7, 9.05, 'Both Clients Hit Both NICs on Every Server  \u2022  Dual 200 Gbps per Node  \u2022  NFS Persistence to Node 105',
        ha='center', va='center', fontsize=9, color='#8b949e')

# Define nodes
clients = [
    {'name': 'Node 101\n(Client 1)', 'x': 2.0, 'y': 6.5, 'ip1': '200.0.0.101', 'ip2': '220.0.0.101',
     'detail': '32 memtier procs\n(16 per NIC \u00d7 2 servers)'},
    {'name': 'Node 102\n(Client 2)', 'x': 2.0, 'y': 3.5, 'ip1': '200.0.0.102', 'ip2': '220.0.0.102',
     'detail': '32 memtier procs\n(16 per NIC \u00d7 2 servers)'},
]

servers = [
    {'name': 'Node 104\n(Server 1)', 'x': 10.0, 'y': 7.0, 'ip1': '200.0.0.104', 'ip2': '220.0.0.104',
     'detail': '32 Redis instances\nlistening both NICs'},
    {'name': 'Node 107\n(Server 2)', 'x': 10.0, 'y': 4.0, 'ip1': '200.0.0.107', 'ip2': '220.0.0.107',
     'detail': '32 Redis instances\nlistening both NICs'},
]

storage = {'name': 'Node 105\n(NFS Storage)', 'x': 10.0, 'y': 1.2, 'ip': '220.0.0.105',
           'detail': '/mnt/nfs_rack\nappendonly AOF writes'}

# Colors
nic1_color = '#f0883e'  # orange for 200.x
nic2_color = '#a371f7'  # purple for 220.x
storage_color = '#39d353'  # green for storage

# Draw client boxes
for c in clients:
    box = FancyBboxPatch((c['x'] - 1.4, c['y'] - 1.0), 2.8, 2.0,
                         boxstyle="round,pad=0.1", facecolor='#1f3a5f', edgecolor='#58a6ff', linewidth=2)
    ax.add_patch(box)
    ax.text(c['x'], c['y'] + 0.5, c['name'], ha='center', va='center', fontsize=10, fontweight='bold', color='#58a6ff')
    ax.text(c['x'], c['y'] - 0.0, c['detail'], ha='center', va='center', fontsize=7, color='#c9d1d9')
    ax.text(c['x'], c['y'] - 0.6, f"NIC1: {c['ip1']}\nNIC2: {c['ip2']}", ha='center', va='center', fontsize=6.5, color='#8b949e')

# Draw server boxes
for s in servers:
    box = FancyBboxPatch((s['x'] - 1.4, s['y'] - 1.0), 2.8, 2.0,
                         boxstyle="round,pad=0.1", facecolor='#1a3332', edgecolor='#2f81f7', linewidth=2)
    ax.add_patch(box)
    ax.text(s['x'], s['y'] + 0.5, s['name'], ha='center', va='center', fontsize=10, fontweight='bold', color='#2f81f7')
    ax.text(s['x'], s['y'] - 0.0, s['detail'], ha='center', va='center', fontsize=7, color='#c9d1d9')
    ax.text(s['x'], s['y'] - 0.6, f"NIC1: {s['ip1']}\nNIC2: {s['ip2']}", ha='center', va='center', fontsize=6.5, color='#8b949e')

# Draw storage box
box = FancyBboxPatch((storage['x'] - 1.4, storage['y'] - 0.8), 2.8, 1.6,
                     boxstyle="round,pad=0.1", facecolor='#1a2d1a', edgecolor=storage_color, linewidth=2)
ax.add_patch(box)
ax.text(storage['x'], storage['y'] + 0.35, storage['name'], ha='center', va='center', fontsize=10, fontweight='bold', color=storage_color)
ax.text(storage['x'], storage['y'] - 0.15, storage['detail'], ha='center', va='center', fontsize=7, color='#c9d1d9')
ax.text(storage['x'], storage['y'] - 0.55, storage['ip'], ha='center', va='center', fontsize=6.5, color='#8b949e')

# Draw connections: Client -> Server (both NICs from each client to each server)
for ci, c in enumerate(clients):
    for si, s in enumerate(servers):
        y_off_nic1 = 0.2
        y_off_nic2 = -0.2

        # NIC1 (200.x) connections - solid orange
        ax.annotate('', xy=(s['x'] - 1.4, s['y'] + y_off_nic1),
                    xytext=(c['x'] + 1.4, c['y'] + y_off_nic1 + (si - ci) * 0.1),
                    arrowprops=dict(arrowstyle='->', color=nic1_color, lw=1.8, alpha=0.75,
                                    connectionstyle=f'arc3,rad={0.05 * (ci*2 + si - 1.5)}'))

        # NIC2 (220.x) connections - dashed purple
        ax.annotate('', xy=(s['x'] - 1.4, s['y'] + y_off_nic2),
                    xytext=(c['x'] + 1.4, c['y'] + y_off_nic2 + (si - ci) * 0.1),
                    arrowprops=dict(arrowstyle='->', color=nic2_color, lw=1.8, alpha=0.75,
                                    linestyle='dashed',
                                    connectionstyle=f'arc3,rad={0.08 * (ci*2 + si - 1.5)}'))

# Draw storage connections: Servers -> NFS (via 220.x / NIC2)
for s in servers:
    ax.annotate('', xy=(storage['x'], storage['y'] + 0.8),
                xytext=(s['x'], s['y'] - 1.0),
                arrowprops=dict(arrowstyle='->', color=storage_color, lw=2.0, alpha=0.8,
                                linestyle='dotted',
                                connectionstyle='arc3,rad=0'))

# Annotation: how it splits
split_box = FancyBboxPatch((4.3, 4.2), 3.4, 2.0,
                           boxstyle="round,pad=0.12", facecolor='#21262d', edgecolor='#484f58', linewidth=1)
ax.add_patch(split_box)
ax.text(6.0, 5.9, 'Per-Server Split', ha='center', va='center', fontsize=9, fontweight='bold', color='white')
ax.text(6.0, 5.5, '8 procs: Client1 \u2192 NIC1 (200.x)', ha='center', va='center', fontsize=7.5, color=nic1_color)
ax.text(6.0, 5.15, '8 procs: Client1 \u2192 NIC2 (220.x)', ha='center', va='center', fontsize=7.5, color=nic2_color)
ax.text(6.0, 4.8, '8 procs: Client2 \u2192 NIC1 (200.x)', ha='center', va='center', fontsize=7.5, color=nic1_color)
ax.text(6.0, 4.45, '8 procs: Client2 \u2192 NIC2 (220.x)', ha='center', va='center', fontsize=7.5, color=nic2_color)

# NFS annotation
ax.text(6.0, 1.9, 'AOF persistence via NIC2 (220.0.0.x)',
        ha='center', va='center', fontsize=8, color=storage_color, fontstyle='italic')
ax.text(6.0, 1.5, 'appendonly=yes  \u2022  NFS mount 220.0.0.105:/intel_rack_nfs_storage',
        ha='center', va='center', fontsize=7, color='#8b949e')

# Legend at bottom
legend_y = 0.35
ax.plot([1.0, 1.8], [legend_y, legend_y], color=nic1_color, lw=2.5, solid_capstyle='round')
ax.text(2.0, legend_y, 'NIC1 (200.0.0.x) \u2014 200 Gbps', va='center', fontsize=7.5, color=nic1_color)

ax.plot([5.0, 5.8], [legend_y, legend_y], color=nic2_color, lw=2.5, linestyle='dashed')
ax.text(6.0, legend_y, 'NIC2 (220.0.0.x) \u2014 200 Gbps', va='center', fontsize=7.5, color=nic2_color)

ax.plot([9.5, 10.3], [legend_y, legend_y], color=storage_color, lw=2.5, linestyle='dotted')
ax.text(10.5, legend_y, 'NFS writes (220.x)', va='center', fontsize=7.5, color=storage_color)

# Totals
ax.text(6.0, 3.3, '= 32 procs per server  \u00d7  2 servers  =  64 total processes',
        ha='center', va='center', fontsize=8, fontweight='bold', color='#c9d1d9')

plt.tight_layout(pad=0.5)
plt.savefig('/root/rack-scaling-benchmarks/redis/diagrams/redis_topology.png', dpi=150, bbox_inches='tight',
            facecolor='#0d1117', edgecolor='none')
print("Saved: /root/rack-scaling-benchmarks/redis/diagrams/redis_topology.png")
