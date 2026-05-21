# Hardware Details — Intel Rack Nodes

## Per-Node Specification

- **CPU**: 1 socket, 160 physical cores (no Hyperthreading), 1 NUMA domain
- **Memory**: 1.5 TiB DDR
- **NIC 1**: 200 Gbps — `enP1s23f0np0` — subnet 200.0.0.0/24
- **NIC 2**: 200 Gbps — `enP1s23f1np1` — subnet 220.0.0.0/24 (NFS network)
- **Local NVMe**: 2× 7 TB NVMe drives + 1× 1.7 TB (OS/boot)
- **OS**: CentOS Stream 10, kernel 6.18.0

## Storage Configuration (Node 104 — MySQL)

| Device | Size | Mount | Filesystem | Purpose |
|--------|------|-------|------------|---------|
| nvme0n1p4 | 1.7T | / | ext4 | OS/root |
| nvme1n1p3 (LVM) | 6.9T | /nvme1 | ext4 | MySQL datadir |
| nvme2n1p1 | 7.0T | /nvme2 | XFS | Redo logs + tmpdir |

## NFS Shared Storage

- Server: 220.0.0.105:/intel_rack_nfs_storage
- Mount: /mnt/nfs_rack (nfs4, via 220.x.x.x NIC)
- Capacity: 5 TB

## Software Versions

| Software | Version | Location |
|----------|---------|----------|
| Redis | 7.2.10 (jemalloc-5.3.0) | /usr/local/bin/redis-server |
| memtier_benchmark | 255.255.255 | /usr/local/bin/memtier_benchmark |
| MySQL | 8.4.8 | /usr/libexec/mysqld |
| sysbench | 1.0.20 | /usr/bin/sysbench |
