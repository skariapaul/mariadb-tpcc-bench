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

| Requirement | Version | Install |
|---|---|---|
| Docker Engine | 20.10+ | https://docs.docker.com/engine/install/ |
| Docker Compose | v2 plugin (`docker compose`) or v1 (`docker-compose`) | included with Docker Desktop; `apt install docker-compose-plugin` on Ubuntu |
| bash | 4+ | pre-installed on every modern Linux |
| curl **or** wget | any | `apt install curl` |
| Free disk | ≥ 20 GB | for Docker images, MariaDB data, and HammerDB |
| Free RAM | ≥ 4 GB | script reserves 75% for the InnoDB buffer pool by default |

> **Docker group**: if you get "permission denied" errors, add yourself and re-login:
> ```bash
> sudo usermod -aG docker $USER && newgrp docker
> ```

---

## Quick start (all defaults, non-interactive)

```bash
# Download the script (or use the copy you already have)
chmod +x mariadb-tpcc-bench.sh

# Run with all defaults — answers every prompt automatically
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

# TPC-H at scale factor 10 only (no TPC-C)
# Not directly supported — run with --skip-tpch and comment out TPC-C in the script,
# or use --duration 1 to minimise TPC-C time.

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
├── docker-compose.yml          ← generated Compose file
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

The script defaults to 75 % of host RAM. If other processes are running, reduce it:
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

### "MariaDB did not start within 3 minutes"
Port 3307 may already be in use. Change it:
```bash
bash mariadb-tpcc-bench.sh --port 3308
```
Or check for a stale container: `docker ps -a | grep mariadb-bench`

### HammerDB download fails
The script tries GitHub. If the network is restricted, download manually:
```
https://github.com/TPC-C/HammerDB/releases/download/v4.11/HammerDB-4.11-Linux.tar.gz
```
Extract to `~/HammerDB` and pass `--hammerdb-dir ~/HammerDB`.

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
