# mariadb-tpcc-bench

Interactive MariaDB TPC-C / TPC-H benchmark runner using HammerDB and Docker.

Tests MariaDB performance across multiple CPU core counts with a fully tuned InnoDB configuration, then produces a Markdown comparison report.

---

## Requirements

- Docker Engine 20.10+ with Compose v2 (`docker compose`)
- bash 4+
- `curl` or `wget`
- ~20 GB free disk, ≥ 4 GB RAM

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

# Preview the plan without running anything
bash mariadb-tpcc-bench.sh --dry-run
```

---

## What it benchmarks

**TPC-C (OLTP)** — five transaction types simulating a warehouse order-entry system. Primary metric is NOPM (New Orders Per Minute).

**TPC-H (Analytics)** — 22 decision-support queries over a star-schema dataset. Primary metric is geometric mean query time.

For each core count the script:
1. Generates a tuned `my.cnf` scaled to that core count
2. Starts a fresh MariaDB container limited to that CPU budget
3. Builds the schema with HammerDB
4. Runs the timed workload and records results
5. Tears down the container before the next config

---

## Output

```
mariadb-bench-YYYYMMDD/
├── configs/          # per-core my.cnf files
├── tcl/              # HammerDB TCL scripts
└── results/
    ├── benchmark_report.md   # comparison report
    ├── 8core/
    │   ├── tpcc_summary.txt  # NOPM, TPM, VUs
    │   ├── tpcc_run.log
    │   └── tpcc_result.log
    └── 16core/
        └── ...
```

---

## Full documentation

See [GUIDE.md](GUIDE.md) for step-by-step instructions, metric explanations, tuning advice, and troubleshooting.
