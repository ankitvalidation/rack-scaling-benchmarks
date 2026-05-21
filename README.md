# Intel Rack Scaling Benchmarks

Database scaling benchmarks on Intel rack nodes, demonstrating throughput and scaling capabilities across Redis, MySQL, and Cassandra workloads.

## Hardware

| Component | Spec |
|-----------|------|
| Nodes | 5 active (101–104, 107), each single-socket |
| CPU | 160 physical cores per node, no HT, 1 NUMA domain |
| Memory | 1.5 TiB DDR per node |
| Network | Dual 200 Gbps NICs per node (enP1s23f0np0 / enP1s23f1np1) |
| Storage | NVMe local (7 TB × 2 per node), NFS shared (5 TB @ 220.0.0.105) |
| OS | CentOS Stream 10, kernel 6.18.0 |

## Benchmarks

### Redis (Complete)
- **17.3M ops/sec** @ 4KB values (65.9 GB/s aggregate throughput)
- **155 Gbps** sustained single-NIC throughput (77.5% wire speed)
- **150 Gbps** sustained over 1 hour (66 TB total data moved)
- **4.8×–11.3×** faster than Supermicro FatTwin comparison system
- See [redis/SUMMARY.md](redis/SUMMARY.md) for full details

### MySQL (In Progress)
- MySQL 8.4.8, InnoDB 1400 GB buffer pool, 60 tables × 100M rows (1.4 TB dataset)
- Replicating DMR X4 experiment: oltp_read_only thread sweep
- Run A: CPU-pinned (cores 0-8) — baseline comparison
- Run B: Unconstrained (all 160 cores) — scaling showcase
- See [mysql/](mysql/) for scripts and results

### Cassandra (Planned)
- Placeholder for future Cassandra benchmarks

## Repository Structure

```
├── redis/
│   ├── BENCHMARK_REPORT.md    # Original 3-test report (256B values)
│   ├── THROUGHPUT_REPORT.md   # Comprehensive throughput report
│   ├── SUMMARY.md             # Executive summary
│   ├── scripts/               # Benchmark scripts
│   └── results/               # Raw output data
├── mysql/
│   ├── scripts/               # Setup, config, prepare, benchmark
│   └── results/               # Thread sweep results
├── cassandra/
│   ├── scripts/
│   └── results/
└── docs/
    └── hardware.md            # Detailed hardware specs
```

## Node Topology

| Node | IP (NIC1) | IP (NIC2/NFS) | Role |
|------|-----------|---------------|------|
| 101 | 200.0.0.101 | 220.0.0.101 | Client / sysbench |
| 102 | 200.0.0.102 | 220.0.0.102 | Client |
| 104 | 200.0.0.104 | 220.0.0.104 | MySQL server |
| 107 | 200.0.0.107 | 220.0.0.107 | Redis server |

Nodes 103 and 106 are currently offline.
