#!/usr/bin/env python3
"""Generate a many-to-many Redis client-server topology diagram with storage - LARGE FONT."""

import matplotlib.pyplot as plt
from matplotlib.patches import FancyBboxPatch

fig, ax = plt.subplots(1, 1, figsize=(18, 12))
ax.set_xlim(0, 18)
ax.set_ylim(0, 12)
ax.axis('off')
ax.set_facecolor('#0d1117')
fig.patch.set_facecolor('#0d1117')

# Title
ax.text(9, 11.5, 'Redis Benchmark: Many-to-Many Client \u2194 Server Topology',
        ha='center', va='center', fontsize=22, fontweight='bold', color='white')
ax.text(9, 10.9, 'Both Clients Hit Both NICs on Every Server  \u2022  Dual 200 Gbps per Node  \u2022  NFS Persistence to Node 105',
        ha='center', va='center', fontsize=12, color='#8b949e')

# Define nodes
clients = [
    {'name': 'Node 101\n(Client 1)', 'x': 2.8, 'y': 8.0, 'ip1': '200.0.0.101', 'ip2': '220.0.0.101',
     'detail': '32 memtier procs\n(16 per NIC \u00d7 2 servers)'},
    {'name': 'Node 102\n(Client 2)', 'x': 2.8, 'y': 4.2, 'ip1': '200.0.0.102', 'ip2': '220.0.0.102',
     'detail': '32 memtier procs\n(16 per NIC \u00d7 2 servers)'},
]

servers = [
    {'name': 'Node 104\n(Server 1)', 'x': 13.2, 'y': 8.5, 'ip1': '200.0.0.104', 'ip2': '220.0.0.104',
     'detail': '32 Redis instances\nlistening both NICs'},
    {'name': 'Node 107\n(Server 2)', 'x': 13.2, 'y': 4.8, 'ip1': '200.0.0.107', 'ip2': '220.0.0.107',
     'detail': '32 Redis instances\nlistening both NICs'},
]

storage = {'name': 'Node 105\n(NFS Storage)', 'x': 13.2, 'y': 1.5, 'ip': '220.0.0.105',
           'detail': '/mnt/nfs_rack\nappendonly AOF writes'}

# Colors
nic1_color = '#f0883e'
nic2_color = '#a371f7'
storage_color = '#39d353'

# Draw client boxes
for c in clients:
    box = FancyBboxPatch((c['x'] - 1.8, c['y'] - 1.2), 3.6, 2.4,
                         boxstyle="round,pad=0.12", facecolor='#1f3a5f', edgecolor='#58a6ff', linewidth=2.5)
    ax.add_patch(box)
    ax.text(c['x'], c['y'] + 0.65, c['name'], ha='center', va='center', fontsize=14, fontweight='bold', color='#58a6ff')
    ax.text(c['x'], c['y'] - 0.05, c['detail'], ha='center', va='center', fontsize=10, color='#c9d1d9')
    ax.text(c['x'], c['y'] - 0.75, f"NIC1: {c['ip1']}\nNIC2: {c['ip2']}", ha='center', va='center', fontsize=9, color='#8b949e')

# Draw server boxes
for s in servers:
    box = FancyBboxPatch((s['x'] - 1.8, s['y'] - 1.2), 3.6, 2.4,
                         boxstyle="round,pad=0.12", facecolor='#1a3332', edgecolor='#2f81f7', linewidth=2.5)
    ax.add_patch(box)
    ax.text(s['x'], s['y'] + 0.65, s['name'], ha='center', va='center', fontsize=14, fontweight='bold', color='#2f81f7')
    ax.text(s['x'], s['y'] - 0.05, s['detail'], ha='center', va='center', fontsize=10, color='#c9d1d9')
    ax.text(s['x'], s['y'] - 0.75, f"NIC1: {s['ip1']}\nNIC2: {s['ip2']}", ha='center', va='center', fontsize=9, color='#8b949e')

# Draw storage box
box = FancyBboxPatch((storage['x'] - 1.8, storage['y'] - 1.0), 3.6, 2.0,
                     boxstyle="round,pad=0.12", facecolor='#1a2d1a', edgecolor=storage_color, linewidth=2.5)
ax.add_patch(box)
ax.text(storage['x'], storage['y'] + 0.45, storage['name'], ha='center', va='center', fontsize=14, fontweight='bold', color=storage_color)
ax.text(storage['x'], storage['y'] - 0.15, storage['detail'], ha='center', va='center', fontsize=10, color='#c9d1d9')
ax.text(storage['x'], storage['y'] - 0.7, storage['ip'], ha='center', va='center', fontsize=9, color='#8b949e')

# Draw connections: Client -> Server (both NICs from each client to each server)
for ci, c in enumerate(clients):
    for si, s in enumerate(servers):
        y_off_nic1 = 0.25
        y_off_nic2 = -0.25

        ax.annotate('', xy=(s['x'] - 1.8, s['y'] + y_off_nic1),
                    xytext=(c['x'] + 1.8, c['y'] + y_off_nic1 + (si - ci) * 0.1),
                    arrowprops=dict(arrowstyle='->', color=nic1_color, lw=2.2, alpha=0.8,
                                    connectionstyle=f'arc3,rad={0.04 * (ci*2 + si - 1.5)}'))

        ax.annotate('', xy=(s['x'] - 1.8, s['y'] + y_off_nic2),
                    xytext=(c['x'] + 1.8, c['y'] + y_off_nic2 + (si - ci) * 0.1),
                    arrowprops=dict(arrowstyle='->', color=nic2_color, lw=2.2, alpha=0.8,
                                    linestyle='dashed',
                                    connectionstyle=f'arc3,rad={0.06 * (ci*2 + si - 1.5)}'))

# Draw storage connections: Servers -> NFS (via 220.x / NIC2)
for s in servers:
    ax.annotate('', xy=(storage['x'], storage['y'] + 1.0),
                xytext=(s['x'], s['y'] - 1.2),
                arrowprops=dict(arrowstyle='->', color=storage_color, lw=2.5, alpha=0.8,
                                linestyle='dotted',
                                connectionstyle='arc3,rad=0'))

# NFS annotation
ax.text(7.5, 2.2, 'AOF persistence via NIC2 (220.0.0.x)',
        ha='center', va='center', fontsize=11, color=storage_color, fontstyle='italic')
ax.text(7.5, 1.7, 'appendonly=yes  \u2022  NFS mount 220.0.0.105:/intel_rack_nfs_storage',
        ha='center', va='center', fontsize=10, color='#8b949e')

# Legend at bottom
legend_y = 0.5
ax.plot([1.2, 2.2], [legend_y, legend_y], color=nic1_color, lw=3, solid_capstyle='round')
ax.text(2.5, legend_y, 'NIC1 (200.0.0.x) \u2014 200 Gbps', va='center', fontsize=11, color=nic1_color)

ax.plot([7.0, 8.0], [legend_y, legend_y], color=nic2_color, lw=3, linestyle='dashed')
ax.text(8.3, legend_y, 'NIC2 (220.0.0.x) \u2014 200 Gbps', va='center', fontsize=11, color=nic2_color)

ax.plot([13.0, 14.0], [legend_y, legend_y], color=storage_color, lw=3, linestyle='dotted')
ax.text(14.3, legend_y, 'NFS writes (220.x)', va='center', fontsize=11, color=storage_color)

plt.tight_layout(pad=0.5)
plt.savefig('/root/rack-scaling-benchmarks/redis/diagrams/redis_topology.png', dpi=180, bbox_inches='tight',
            facecolor='#0d1117', edgecolor='none')
print("Saved: /root/rack-scaling-benchmarks/redis/diagrams/redis_topology.png")
