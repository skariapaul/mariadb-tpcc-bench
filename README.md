# mariadb-tpcc-bench

Interactive MariaDB TPC-C / TPC-H benchmark runner using HammerDB and Docker.

Tests MariaDB performance across multiple CPU core counts with a fully tuned InnoDB configuration, then produces a Markdown comparison report. Supports NUMA-aware CPU pinning for accurate multi-socket results.

---

## Requirements

- Docker Engine 20.10+ with Compose v2 (`docker compose`) or Compose v1 (`docker-compose`)
- bash 4+
- `curl` or `wget`
- `libmariadb3` — MariaDB client library (required by HammerDB's TCL driver)
  - Ubuntu/Debian: `sudo apt-get install -y libmariadb3`
  - RHEL/CentOS: `sudo yum install -y mariadb-connector-c`
- ~20 GB free disk, ≥ 4 GB RAM

---

## Docker container (standalone)

A ready-to-use MariaDB container with benchmark-optimized defaults is in `docker/`:

```bash
cd docker
cp .env.example .env          # adjust BENCH_CPUS, buffer pool, etc.
docker compose up -d           # or: docker-compose up -d
```

The `my.cnf` in that directory contains the base InnoDB tuning. Mount a custom override file for per-run adjustments.

---

## Quick start

```bash
# Non-interactive — all defaults
bash mariadb-tpcc-bench.sh --yes

# Interactive — press Enter to accept each default
bash mariadb-tpcc-bench.sh
```

Results and a Markdown report are written to `./mariadb-bench-YYYYMMDD/results/`.

---

## Common options

| Flag | Default | Description |
|---|---|---|
| `--cores "8 16 32"` | auto | CPU core counts to test (space-separated) |
| `--warehouses N` | 64 | TPC-C warehouse count |
| `--rampup N` | 2 | Ramp-up minutes |
| `--duration N` | 10 | Timed-run minutes |
| `--tpch-sf N` | 1 | TPC-H scale factor (1 / 10 / 30 / 100) |
| `--skip-tpch` | — | Skip TPC-H analytics benchmark |
| `--buffer-pool SIZE` | 75% RAM | InnoDB buffer pool (e.g. `12G`) |
| `--mariadb-ver VER` | 10.11 | MariaDB Docker image tag |
| `--numa-node N` | — | Pin container to NUMA node N; auto-derives cpuset per core count |
| `--cpuset RANGE` | — | Pin container to explicit CPUs (e.g. `"0-7"` or `"0,2,4,6"`) |
| `--list-numa` | — | Show NUMA topology and exit |
| `--force` | — | Re-run configs that already have results |
| `--dry-run` | — | Print plan without running anything |

### Examples

```bash
# Quick smoke test — 2 core configs, no TPC-H, short run
bash mariadb-tpcc-bench.sh --cores "8 16" --rampup 1 --duration 5 --skip-tpch --yes

# Serious benchmark — larger warehouse count, longer run
bash mariadb-tpcc-bench.sh --warehouses 256 --rampup 5 --duration 30 --yes

# Test MariaDB 11.4 with a custom buffer pool
bash mariadb-tpcc-bench.sh --mariadb-ver 11.4 --buffer-pool 24G --yes

# NUMA-aware run — pin to node 0, cpuset auto-derived per core count
bash mariadb-tpcc-bench.sh --cores "8 16 32" --numa-node 0 --yes

# Pin to specific cores explicitly
bash mariadb-tpcc-bench.sh --cores "8 16" --cpuset "0-15" --yes

# Inspect NUMA topology before choosing a node
bash mariadb-tpcc-bench.sh --list-numa

# Preview the plan without running anything
bash mariadb-tpcc-bench.sh --dry-run
```

---

## NUMA-aware CPU pinning

On multi-socket systems, cross-NUMA memory accesses add latency that can mask true per-core performance. The `--numa-node` flag eliminates this:

```
--numa-node 0   →  8-core run  uses cpuset 0-7   (first 8  CPUs of node 0)
                   16-core run uses cpuset 0-15  (first 16 CPUs of node 0)
                   32-core run uses cpuset 0-31  (first 32 CPUs of node 0)
```

Use `--list-numa` to inspect your topology first:

```bash
bash mariadb-tpcc-bench.sh --list-numa
```

`numactl` is used when available; the script falls back to sysfs (`/sys/devices/system/node/`) if not installed.

---

## What it benchmarks

**TPC-C (OLTP)** — five transaction types simulating a warehouse order-entry system. Primary metric is NOPM (New Orders Per Minute).

**TPC-H (Analytics)** — 22 decision-support queries over a star-schema dataset. Primary metric is geometric mean query time.

For each core count the script:
1. Generates a tuned `my.cnf` scaled to that core count
2. Starts a fresh MariaDB container limited to that CPU budget (and cpuset if pinning is enabled)
3. Builds the schema with HammerDB
4. Runs the timed workload and records results
5. Tears down the container before the next config

> **Warehouse sizing:** for linear scaling, use `--warehouses` ≥ 10× your highest VU count.  
> At the default of 64 warehouses, scaling plateaus around 8–16 VUs due to hot-row contention.

---

## Output

```
mariadb-bench-YYYYMMDD/
├── configs/          # per-core my.cnf files
├── tcl/              # HammerDB TCL scripts
└── results/
    ├── benchmark_report.md   # comparison report
    ├── 8core/
    │   ├── tpcc_summary.txt  # NOPM, TPM, VUs, elapsed
    │   ├── tpcc_run.log
    │   ├── tpcc_result.log   # per-transaction latency percentiles
    │   └── tpcc_latency.log
    └── 16core/
        └── ...
```

---

## Full documentation

See [GUIDE.md](GUIDE.md) for step-by-step instructions, metric explanations, tuning advice, and troubleshooting.
