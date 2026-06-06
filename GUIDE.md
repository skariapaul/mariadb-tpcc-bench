# MariaDB TPC-C / TPC-H Benchmark — Procedure Guide

## What the script does

Runs an automated, repeatable MariaDB OLTP (TPC-C) and analytics (TPC-H) benchmark
entirely inside Docker. For each CPU core count you choose it:

1. Generates a tuned `my.cnf`
2. Starts a fresh MariaDB container limited to that core count
3. Builds the TPC-C schema with HammerDB
4. Runs the timed TPC-C workload and records NOPM / TPM
5. Builds the TPC-H schema and runs the 22-query analytic suite (optional)
6. Tears down the container and moves to the next core count
7. Produces a Markdown report comparing all configurations

---

## Prerequisites

### Docker Engine

**Ubuntu 22.04 / 24.04**
```bash
sudo apt-get update
sudo apt-get install -y ca-certificates curl gnupg
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $VERSION_CODENAME) stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
sudo systemctl enable --now docker
sudo usermod -aG docker $USER && newgrp docker
```

**RHEL 8 / 9 / Rocky Linux / AlmaLinux**
```bash
sudo yum install -y yum-utils
sudo yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
sudo yum install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
sudo systemctl enable --now docker
sudo usermod -aG docker $USER && newgrp docker
```

Verify:
```bash
docker --version
docker compose version   # v2 plugin
# or
docker-compose --version # v1 fallback
```

### MariaDB client library

HammerDB's TCL driver loads `libmariadb.so.3` from the host at runtime.
Install it before running the benchmark.

**Ubuntu / Debian**
```bash
sudo apt-get install -y libmariadb3
```

**RHEL / CentOS / Rocky Linux**
```bash
sudo yum install -y mariadb-connector-c
```

Verify:
```bash
ldconfig -p | grep libmariadb
# Expected: libmariadb.so.3 (libc6,x86-64) => /lib/x86_64-linux-gnu/libmariadb.so.3
```

### Other dependencies

| Requirement | Minimum | Install |
|---|---|---|
| bash | 4+ | pre-installed on every modern Linux |
| curl **or** wget | any | `apt install curl` / `yum install curl` |
| Free disk | ≥ 20 GB | Docker images + MariaDB data + HammerDB |
| Free RAM | ≥ 4 GB | 75% reserved for InnoDB buffer pool by default |

> **Docker group tip:** if you get "permission denied" on Docker commands:
> ```bash
> sudo usermod -aG docker $USER && newgrp docker
> ```

---

## EPYC NPS4 Optimized Setup (best results)

This section documents the configuration that achieves peak TPC-C throughput on
a single-socket AMD EPYC 9005-series processor by combining BIOS-level NUMA
topology tuning, CCD-aware CPU pinning, and NUMA memory binding.

### 1. Set NPS4 in BIOS

In the BIOS, navigate to **AMD CBS → NBIO → Nodes Per Socket** and set it to **4**.
Reboot, then verify:

```bash
numactl --hardware
# Expected: "available: 4 nodes (0-3)"
# Node 0 should show CPUs 0-15, 64-79 (two CCDs, 377 GB split evenly across 4 nodes)
```

With NPS4, each pair of CCDs maps to its own NUMA node, eliminating cross-die
memory latency for a workload pinned to node 0.

### 2. Start the container (docker run — required for --cpuset-mems)

`docker-compose` does not support `--cpuset-mems`. Use `docker run` directly so
both CPU and memory are pinned to NUMA node 0:

```bash
docker rm -f mariadb-bench 2>/dev/null
docker run -d \
  --name mariadb-bench \
  --cpuset-cpus "0-15,64-79" \
  --cpuset-mems 0 \
  --cap-add IPC_LOCK \
  -e MARIADB_ROOT_PASSWORD=maria \
  -e MARIADB_DATABASE=tpcc \
  -p 3307:3306 \
  -v mariadb-bench-reference_mariadb_bench_data:/var/lib/mysql \
  -v "/path/to/mariadb-tpcc-bench/MariaDB TPC-C/50-server.cnf:/etc/mysql/mariadb.conf.d/50-server.cnf:ro" \
  -v "/path/to/mariadb-tpcc-bench/mariadb-bench-reference/configs/docker-override.cnf:/etc/mysql/mariadb.conf.d/99-docker.cnf:ro" \
  mariadb:10.11

# Wait for ready
until docker exec mariadb-bench mysqladmin -uroot -pmaria status 2>/dev/null; do sleep 2; done
```

Replace `/path/to/mariadb-tpcc-bench` with the absolute path to this repo.

### 3. Build the schema

**64 warehouses** (fast build, ~5 min):
```bash
cd /path/to/HammerDB && TMP=/tmp ./hammerdbcli auto \
  /path/to/mariadb-tpcc-bench/mariadb-bench-reference/tcl/tpcc_build.tcl
```

**128 warehouses** (recommended — reduces lock contention with 32 VUs, ~15 min):
```bash
cd /path/to/HammerDB && TMP=/tmp ./hammerdbcli auto \
  /path/to/mariadb-tpcc-bench/mariadb-bench-reference/tcl/tpcc_build_128w.tcl
```

### 4. Run the benchmark

**16 VUs** (CCD0 only — closest to Viettel PoC spec):
```bash
cd /path/to/HammerDB && TMP=/tmp ./hammerdbcli auto \
  /path/to/mariadb-tpcc-bench/mariadb-bench-reference/tcl/tpcc_run.tcl 2>&1 | tee /tmp/tpcc-run.log
```

**32 VUs** (full node 0, 2 CCDs — best throughput):
```bash
cd /path/to/HammerDB && TMP=/tmp ./hammerdbcli auto \
  /path/to/mariadb-tpcc-bench/mariadb-bench-reference/tcl/tpcc_run_32vu.tcl 2>&1 | tee /tmp/tpcc-run.log
```

### 5. Results on EPYC 9555P (64c, NPS4, Ubuntu 24.04)

| Config | VUs | Warehouses | NOPM | TPM |
|--------|-----|------------|------|-----|
| NPS1, CCD0 pin, 50-server.cnf (PoC baseline) | 16 | 64 | 327,198 | 759,994 |
| NPS4, CCD0 pin, --cpuset-mems 0 | 16 | 64 | 331,118 | 769,165 |
| NPS4, full node 0 (2 CCDs), --cpuset-mems 0 | 32 | 64 | 338,919 | 787,437 |

**+91% over AMD PoC 48-core reference (177,162 NOPM)**
**+65% over AMD PoC 64-core reference (205,004 NOPM)**

### Why this works

- **NPS4** maps each pair of CCDs to its own NUMA node — memory accesses stay
  local to the dies serving the pinned CPUs.
- **`--cpuset-mems 0`** ensures the kernel allocates all MariaDB pages from node 0
  physical memory, eliminating cross-node DRAM latency entirely.
- **`--cpuset-cpus "0-15,64-79"`** pins the container to 16 physical cores (both
  CCDs in node 0) plus their HT siblings — giving 32 logical CPUs with fully local
  L3 cache and memory.
- **`50-server.cnf`** disables performance_schema, doubles the InnoDB buffer pool
  relative to defaults, disables double-write, and sets `innodb_flush_log_at_trx_commit=0`
  for maximum throughput.

---

## Standalone Docker container

A pre-configured MariaDB container lives in `docker/`. Use it to connect
HammerDB manually, run custom workloads, or verify the tuned InnoDB config
without executing the full benchmark script.

```bash
cd docker
cp .env.example .env     # edit BENCH_CPUS, DB_PORT, passwords as needed
docker compose up -d     # or: docker-compose up -d
```

The image is built from `docker/Dockerfile` (based on `mariadb:10.11`) and
bakes in `docker/my.cnf` — a performance-tuned InnoDB configuration with:

- `performance_schema = OFF`
- `innodb_buffer_pool_size = 12G` (override via env or a second `.cnf` file)
- `innodb_flush_method = O_DIRECT`
- `max_connections = 4000`
- Binary logging disabled

Connect once the container is ready:
```bash
mysql -h 127.0.0.1 -P 3308 -uroot -ptpccpass
```

Stop and remove the container and its data volume:
```bash
docker compose down -v
```

> **Port:** the standalone container defaults to `3308` to avoid conflicts with
> a benchmark run, which uses `3307` by default. Override with `DB_PORT=XXXX`
> in `.env`.

---

## Quick start (all defaults, non-interactive)

```bash
chmod +x mariadb-tpcc-bench.sh
bash mariadb-tpcc-bench.sh --yes
```

Results land in `./mariadb-bench-YYYYMMDD/results/`.

---

## Step-by-step interactive run

```bash
bash mariadb-tpcc-bench.sh
```

The script walks you through each setting. Press **Enter** to accept the default
shown in green, or type a new value.

```
CPU core configs to test  [4 8 16]   ← space-separated list, must be ≤ host cores
TPC-C warehouses          [64]        ← ≥ 2× your max VU count recommended
TPC-C ramp-up minutes     [2]
TPC-C timed-run minutes   [10]
Run TPC-H analytics?      [yes]
TPC-H scale factor        [1]        ← 1=~1 GB, 10=~10 GB, 30=~30 GB
InnoDB buffer pool size   [12G]       ← auto-set to 75% of RAM
Host port for MariaDB     [3307]
MariaDB Docker image tag  [10.11]
Output directory          [./mariadb-bench-20260603]
HammerDB directory        [auto-download]
```

After confirming the plan it runs fully unattended.

---

## Common invocation examples

```bash
# Test only 8 and 16 cores, skip TPC-H, 30-minute timed run
bash mariadb-tpcc-bench.sh --cores "8 16" --duration 30 --skip-tpch --yes

# MariaDB 11.4 with a custom buffer pool and port
bash mariadb-tpcc-bench.sh --mariadb-ver 11.4 --buffer-pool 24G --port 3308 --yes

# Large warehouse count for a serious benchmark
bash mariadb-tpcc-bench.sh --warehouses 512 --rampup 5 --duration 30 --yes

# Dry run — print the plan without touching anything
bash mariadb-tpcc-bench.sh --dry-run

# Re-run a specific configuration that already finished
bash mariadb-tpcc-bench.sh --cores "16" --force --yes

# Use an existing HammerDB install (skip download)
bash mariadb-tpcc-bench.sh --hammerdb-dir ~/HammerDB --yes
```

---

## Output layout

```
mariadb-bench-YYYYMMDD/
├── docker-compose.yml          ← generated Compose file (per benchmark run)
├── configs/
│   ├── 4core.cnf               ← tuned my.cnf per core count
│   ├── 8core.cnf
│   └── ...
├── tcl/
│   ├── tpcc_build.tcl
│   ├── tpcc_run.tcl
│   ├── tpcc_result.tcl
│   ├── tpch_build.tcl
│   ├── tpch_run.tcl
│   └── tpch_result.tcl
└── results/
    ├── benchmark_report.md     ← final comparison report
    ├── 4core/
    │   ├── tpcc_build.log
    │   ├── tpcc_run.log
    │   ├── tpcc_result.log
    │   ├── tpcc_summary.txt    ← NOPM, TPM, VUs
    │   ├── tpcc_latency.log    ← per-transaction percentiles (if available)
    │   ├── tpch_build.log
    │   ├── tpch_run.log
    │   ├── tpch_result.log
    │   └── tpch_summary.txt    ← geomean query time, stream time
    └── 8core/
        └── ...
```

---

## Key metrics explained

| Metric | Meaning |
|---|---|
| **NOPM** | New Orders Per Minute — the primary TPC-C throughput metric |
| **TPM** | Transactions Per Minute across all five TPC-C transaction types |
| **TPM/VU** | Per-user efficiency; a steep drop as VUs increase = lock/latch contention |
| **DELIVERY p99** | 99th-percentile latency for Delivery transactions — most sensitive to row-lock pressure |
| **TPC-H geomean** | Geometric mean of the 22 analytic query runtimes (lower is better) |

---

## Tuning the defaults

### Warehouses

Rule of thumb: `warehouses ≥ 2 × max_VUs`. At 64 warehouses with 64 VUs you will
see artificial contention on the hot rows; use 128 or 256 for cleaner scaling data.

### Duration

- **Quick smoke test**: `--rampup 1 --duration 5`
- **Publishable result**: `--rampup 5 --duration 30` (allows the buffer pool to warm)

### Buffer pool

The script defaults to 75% of host RAM. If other processes are running, reduce it:
```bash
--buffer-pool 8G
```

### MariaDB version

Any tag available on Docker Hub works:
```bash
--mariadb-ver 10.6
--mariadb-ver 10.11
--mariadb-ver 11.4
--mariadb-ver lts   # latest LTS
```

---

## Troubleshooting

### "Docker daemon not accessible"
```bash
sudo systemctl start docker
sudo usermod -aG docker $USER
newgrp docker
```

### "libmariadb.so.3: cannot open shared object file"
HammerDB's MariaDB driver is missing its host dependency:
```bash
# Ubuntu/Debian
sudo apt-get install -y libmariadb3

# RHEL/CentOS
sudo yum install -y mariadb-connector-c
```

### "MariaDB did not start within 3 minutes"
Port 3307 may already be in use. Change it:
```bash
bash mariadb-tpcc-bench.sh --port 3308
```
Or check for a stale container: `docker ps -a | grep mariadb-bench`

### HammerDB download fails
The script auto-detects your OS and downloads the matching HammerDB 5.0 package
from `github.com/TPC-Council/HammerDB`. If the network is restricted, download
manually and point the script at your copy:

| OS | URL |
|---|---|
| Ubuntu 24.04 | `https://github.com/TPC-Council/HammerDB/releases/download/v5.0/HammerDB-5.0-Prod-Lin-UBU24.tar.gz` |
| Ubuntu 22.04 | `https://github.com/TPC-Council/HammerDB/releases/download/v5.0/HammerDB-5.0-Prod-Lin-UBU22.tar.gz` |
| RHEL 9 | `https://github.com/TPC-Council/HammerDB/releases/download/v5.0/HammerDB-5.0-Prod-Lin-RHEL9.tar.gz` |
| RHEL 8 | `https://github.com/TPC-Council/HammerDB/releases/download/v5.0/HammerDB-5.0-Prod-Lin-RHEL8.tar.gz` |

```bash
curl -L <URL> | tar -xz --strip-components=1 -C ~/HammerDB
bash mariadb-tpcc-bench.sh --hammerdb-dir ~/HammerDB --yes
```

### "Results for N-core already exist"
Use `--force` to overwrite, or delete the specific result directory:
```bash
rm -rf mariadb-bench-YYYYMMDD/results/16core
```

### Benchmarks complete but NOPM shows "see_log"
Open `results/Ncore/tpcc_result.log` and search for `NOPM` or `System achieved`.
The regex extraction falls back gracefully; the raw number is always in the log.

### TPC-H queries time out or error
TPC-H SF=1 requires ~1 GB of data loaded. If the container runs out of disk:
- Reduce `--tpch-sf` or use `--skip-tpch`
- Check Docker's disk limit: `docker system df`

---

## Stopping a run mid-way

Press **Ctrl+C** — the trap handler calls `docker compose down -v` automatically to
clean up the container and its volume before exiting.

---

## Interpreting the report

Open `results/benchmark_report.md` in any Markdown viewer. Look for:

1. **Scaling efficiency** — does NOPM grow linearly with cores? Sublinear = contention.
2. **TPM/VU drop** — more VUs per core than ~10–20 usually degrades per-user throughput.
3. **DELIVERY p99** — values above 1000 ms indicate serious InnoDB row-lock queuing.
4. **TPC-H vs TPC-C trade-off** — if running mixed workloads, compare analytics query
   times at different core counts to find the best OLTP/OLAP balance.
