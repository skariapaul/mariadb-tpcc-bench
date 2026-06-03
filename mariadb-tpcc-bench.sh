#!/usr/bin/env bash
# =============================================================================
# MariaDB TPC-C / TPC-H Benchmark — standalone interactive runner
# =============================================================================
# Requirements : Docker, bash 4+, curl or wget
# Supported OS : Linux x86_64 / aarch64  (Docker Desktop on macOS works too)
#
# Usage:
#   bash mariadb-tpcc-bench.sh [options]
#
# Options:
#   --cores "8 16 32"    Space-separated CPU limits to test (default: auto)
#   --warehouses N       TPC-C warehouse count      (default: 64)
#   --rampup N           Ramp-up minutes            (default: 2)
#   --duration N         Timed-run minutes           (default: 10)
#   --tpch-sf N          TPC-H scale factor (1/10/30/100) (default: 1)
#   --skip-tpch          Omit TPC-H benchmarks
#   --buffer-pool SIZE   InnoDB buffer pool, e.g. 12G (default: 75% RAM)
#   --port N             Host port mapped to MariaDB  (default: 3307)
#   --workdir PATH       Output directory (default: ./mariadb-bench-YYYYMMDD)
#   --hammerdb-dir PATH  Existing HammerDB install   (default: auto-download)
#   --mariadb-ver VER    MariaDB Docker image tag     (default: 10.11)
#   --force              Re-run configs that already have results
#   --yes                Non-interactive; use all defaults / flag values
#   --dry-run            Print plan without running anything
#   -h, --help           Show this help and exit
# =============================================================================
set -euo pipefail

# ── Colour helpers ────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  RED='\033[0;31m' YEL='\033[1;33m' GRN='\033[0;32m' CYN='\033[0;36m'
  BLD='\033[1m'    RST='\033[0m'
else
  RED='' YEL='' GRN='' CYN='' BLD='' RST=''
fi

log()  { echo -e "${CYN}[$(date '+%H:%M:%S')]${RST} $*"; }
ok()   { echo -e "${GRN}[$(date '+%H:%M:%S')] ✔ $*${RST}"; }
warn() { echo -e "${YEL}[$(date '+%H:%M:%S')] ⚠ $*${RST}"; }
die()  { echo -e "${RED}[$(date '+%H:%M:%S')] ✖ $*${RST}" >&2; exit 1; }
hr()   { echo -e "${BLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RST}"; }
section() { hr; echo -e "${BLD}  $*${RST}"; hr; }

# ── Defaults (overridden by flags or interactive prompts) ─────────────────────
CORES_LIST=""           # filled after detection if empty
WAREHOUSES=64
RAMPUP=2
DURATION=10
TPCH_SF=1
SKIP_TPCH=false
BUFFER_POOL=""          # auto-sized below
DB_PORT=3307
WORKDIR=""
HAMMERDB_DIR=""
MARIADB_VER="10.11"
FORCE=false
YES=false
DRY_RUN=false

HAMMERDB_VERSION="4.11"
HAMMERDB_URL="https://github.com/TPC-C/HammerDB/releases/download/v${HAMMERDB_VERSION}/HammerDB-${HAMMERDB_VERSION}-Linux.tar.gz"
DOCKER_COMPOSE=""     # resolved by check_deps
DB_PASS="tpccpass"
DB_USER="root"
CONTAINER="mariadb-bench"

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case $1 in
    --cores)        CORES_LIST="$2";    shift 2 ;;
    --warehouses)   WAREHOUSES="$2";    shift 2 ;;
    --rampup)       RAMPUP="$2";        shift 2 ;;
    --duration)     DURATION="$2";      shift 2 ;;
    --tpch-sf)      TPCH_SF="$2";       shift 2 ;;
    --skip-tpch)    SKIP_TPCH=true;     shift   ;;
    --buffer-pool)  BUFFER_POOL="$2";   shift 2 ;;
    --port)         DB_PORT="$2";       shift 2 ;;
    --workdir)      WORKDIR="$2";       shift 2 ;;
    --hammerdb-dir) HAMMERDB_DIR="$2";  shift 2 ;;
    --mariadb-ver)  MARIADB_VER="$2";   shift 2 ;;
    --force)        FORCE=true;         shift   ;;
    --yes|-y)       YES=true;           shift   ;;
    --dry-run)      DRY_RUN=true;       shift   ;;
    -h|--help)
      sed -n '/^# Usage:/,/^# ====/p' "$0" | grep '^#' | sed 's/^# \?//'
      exit 0 ;;
    *) die "Unknown option: $1 — use --help for usage" ;;
  esac
done

# ── Interactive prompt helper ─────────────────────────────────────────────────
# prompt VAR_NAME "question" "default"
# Sets the named variable. With --yes just echoes the default.
prompt() {
  local var="$1" question="$2" default="$3"
  if $YES; then
    printf '%s\n' "$default"
    eval "$var=\$default"
    return
  fi
  printf "${BLD}%s${RST} [${GRN}%s${RST}]: " "$question" "$default"
  local reply
  read -r reply
  eval "$var=\${reply:-$default}"
}

# ── System detection ──────────────────────────────────────────────────────────
detect_system() {
  HOST_CORES=$(nproc 2>/dev/null || sysctl -n hw.logicalcpu 2>/dev/null || echo 4)
  # RAM in GiB — Linux /proc/meminfo, macOS sysctl
  if [[ -f /proc/meminfo ]]; then
    HOST_RAM_GiB=$(awk '/MemTotal/{printf "%d", $2/1024/1024}' /proc/meminfo)
  else
    HOST_RAM_GiB=$(sysctl -n hw.memsize 2>/dev/null | awk '{printf "%d", $1/1024/1024/1024}')
  fi
  HOST_RAM_GiB=${HOST_RAM_GiB:-4}
}

auto_cores_list() {
  local c=$HOST_CORES
  local list=""
  for n in 4 8 16 32 64; do
    [[ $n -le $c ]] && list="$list $n"
  done
  echo "${list# }"
}

auto_buffer_pool() {
  local gb=$(( HOST_RAM_GiB * 3 / 4 ))
  [[ $gb -lt 1 ]] && gb=1
  echo "${gb}G"
}

# ── Dependency checks ─────────────────────────────────────────────────────────
check_deps() {
  command -v docker &>/dev/null || die "Docker not found. Install Docker and ensure it is running."
  docker info &>/dev/null       || die "Docker daemon not accessible. Try: sudo systemctl start docker (or add yourself to the docker group)."
  command -v curl &>/dev/null || command -v wget &>/dev/null \
    || die "Neither curl nor wget found. Install one of them."
  # Prefer Docker Compose v2 plugin; fall back to legacy standalone binary
  if docker compose version &>/dev/null 2>&1; then
    DOCKER_COMPOSE="docker compose"
  elif command -v docker-compose &>/dev/null; then
    DOCKER_COMPOSE="docker-compose"
    warn "Using legacy docker-compose v1. Upgrade to Docker Compose v2 for best results."
  else
    die "Docker Compose not found. Install the Docker Compose v2 plugin ('docker compose version' should work)."
  fi
}

# ── HammerDB setup ────────────────────────────────────────────────────────────
setup_hammerdb() {
  if [[ -n "$HAMMERDB_DIR" ]]; then
    [[ -x "$HAMMERDB_DIR/hammerdbcli" ]] \
      || die "hammerdbcli not found at $HAMMERDB_DIR/hammerdbcli"
    ok "Using existing HammerDB at $HAMMERDB_DIR"
    return
  fi

  # Check standard locations first
  for candidate in "$HOME/HammerDB" "/opt/HammerDB" "./HammerDB" \
                   "$HOME/HammerDB-${HAMMERDB_VERSION}"; do
    if [[ -x "$candidate/hammerdbcli" ]]; then
      HAMMERDB_DIR="$candidate"
      ok "Found HammerDB at $HAMMERDB_DIR"
      return
    fi
  done

  # Download
  local archive="/tmp/hammerdb-${HAMMERDB_VERSION}.tar.gz"
  local dest="$HOME/HammerDB"
  log "HammerDB not found — downloading v${HAMMERDB_VERSION} to $dest ..."
  if command -v curl &>/dev/null; then
    curl -fSL --progress-bar "$HAMMERDB_URL" -o "$archive"
  else
    wget -q --show-progress "$HAMMERDB_URL" -O "$archive"
  fi
  mkdir -p "$dest"
  tar -xzf "$archive" --strip-components=1 -C "$dest"
  rm -f "$archive"
  [[ -x "$dest/hammerdbcli" ]] || die "HammerDB extraction failed — check $dest"
  HAMMERDB_DIR="$dest"
  ok "HammerDB installed at $HAMMERDB_DIR"
}

# ── MariaDB config generator ──────────────────────────────────────────────────
# generate_cnf CORES BUFFER_POOL OUTFILE
generate_cnf() {
  local cores=$1 bp=$2 out=$3
  local rio=$(( cores / 2 ))
  local wio=$(( cores / 2 ))
  [[ $rio -lt 1 ]] && rio=1
  [[ $wio -lt 1 ]] && wio=1
  [[ $rio -gt 16 ]] && rio=16
  [[ $wio -gt 16 ]] && wio=16
  local purge=$(( cores / 4 ))
  [[ $purge -lt 2 ]] && purge=2
  [[ $purge -gt 4 ]] && purge=4
  local toci=$cores
  [[ $toci -gt 16 ]] && toci=16
  local tcs=$(( cores * 3 ))
  [[ $tcs -lt 50 ]] && tcs=50

  # Buffer pool instances: 1 per GB, capped at 16
  local bp_gb=4
  [[ "$bp" =~ ^([0-9]+)[Gg]$ ]] && bp_gb="${BASH_REMATCH[1]}"
  local bpi=$(( bp_gb < 1 ? 1 : (bp_gb > 16 ? 16 : bp_gb) ))

  # MariaDB 11.x replaced innodb_log_file_size with innodb_redo_log_capacity
  local major_ver
  major_ver=$(echo "$MARIADB_VER" | cut -d. -f1)
  local redo_log_line
  if [[ "$major_ver" -ge 11 ]]; then
    redo_log_line="innodb_redo_log_capacity      = 2G"
  else
    redo_log_line="innodb_log_file_size          = 1G"
  fi

  # Normalize to major.minor for the version-specific section header
  local ver_section
  ver_section=$(echo "$MARIADB_VER" | grep -oP '^\d+\.\d+')
  [[ -z "$ver_section" ]] && ver_section="$MARIADB_VER"

  cat > "$out" <<EOF
# MariaDB ${MARIADB_VER} — ${cores}-core benchmark configuration
# Generated by mariadb-tpcc-bench.sh on $(date)

[server]

[mysqld]
pid-file             = /run/mysqld/mysqld.pid
basedir              = /usr
bind-address         = 0.0.0.0
character-set-server = utf8mb4
collation-server     = utf8mb4_general_ci

[mariadb]
performance_schema            = OFF
max_prepared_stmt_count       = 128000
transaction_isolation         = REPEATABLE-READ
default_storage_engine        = InnoDB
skip-log-bin

innodb_buffer_pool_size       = ${bp}
innodb_buffer_pool_instances  = ${bpi}
${redo_log_line}
innodb_log_buffer_size        = 256M

innodb_file_per_table         = 1
innodb_flush_log_at_trx_commit = 0
innodb_flush_method           = O_DIRECT
innodb_open_files             = 2000
innodb_stats_on_metadata      = 0
innodb_doublewrite            = 0
innodb_max_dirty_pages_pct    = 90
innodb_max_dirty_pages_pct_lwm = 10
innodb_use_native_aio         = 1
innodb_stats_persistent       = 1
innodb_spin_wait_delay        = 6
innodb_max_purge_lag_delay    = 300000
innodb_max_purge_lag          = 0
innodb_io_capacity            = 12000
innodb_io_capacity_max        = 20000
innodb_lru_scan_depth         = 9000
innodb_change_buffering       = none
innodb_read_only              = 0
innodb_undo_log_truncate      = OFF
innodb_adaptive_flushing      = 1
innodb_flush_neighbors        = 0
innodb_adaptive_hash_index    = 0
innodb_monitor_enable         = %

# ${cores}-core tuning
innodb_read_io_threads        = ${rio}
innodb_write_io_threads       = ${wio}
innodb_purge_threads          = ${purge}

max_connections               = 4000
table_open_cache              = 8000
table_open_cache_instances    = ${toci}
back_log                      = 1500
thread_cache_size             = ${tcs}
thread_stack                  = 192K

join_buffer_size              = 64M
read_buffer_size              = 48M
read_rnd_buffer_size          = 64M
sort_buffer_size              = 64M

ft_min_word_len               = 3

[mariadb-${ver_section}]
EOF
}

# ── docker-compose generator ──────────────────────────────────────────────────
generate_compose() {
  local out="$1"
  cat > "$out" <<EOF
services:
  mariadb:
    image: mariadb:${MARIADB_VER}
    container_name: ${CONTAINER}
    restart: "no"
    environment:
      MARIADB_ROOT_PASSWORD: ${DB_PASS}
      MARIADB_DATABASE: tpcc
      MARIADB_USER: benchuser
      MARIADB_PASSWORD: ${DB_PASS}
    ports:
      - "${DB_PORT}:3306"
    deploy:
      resources:
        limits:
          cpus: "\${BENCH_CPUS:-1}"
    volumes:
      - mariadb_bench_data:/var/lib/mysql
      - \${BENCH_CNF}:/etc/mysql/mariadb.conf.d/99-bench.cnf:ro

volumes:
  mariadb_bench_data:
EOF
}

# ── TCL script generators ─────────────────────────────────────────────────────
generate_tcl() {
  local tcl_dir="$1"
  mkdir -p "$tcl_dir"

  # tpcc_build.tcl — reads BENCH_WARE, BENCH_PORT, BENCH_PASS from env
  cat > "$tcl_dir/tpcc_build.tcl" <<'EOF'
puts "SETTING CONFIGURATION (TPC-C build)"
dbset db maria
dbset bm TPC-C

set port  [expr {[info exists ::env(BENCH_PORT)] ? $::env(BENCH_PORT) : 3307}]
set ware  [expr {[info exists ::env(BENCH_WARE)] ? $::env(BENCH_WARE) : 64}]
set pass  [expr {[info exists ::env(BENCH_PASS)] ? $::env(BENCH_PASS) : "tpccpass"}]
set lvu   [expr {[info exists ::env(BENCH_LVU)]  ? $::env(BENCH_LVU)  : 8}]

diset connection maria_host   127.0.0.1
diset connection maria_port   $port
diset connection maria_socket null
diset connection maria_ssl    false

diset tpcc maria_count_ware      $ware
diset tpcc maria_num_vu          $lvu
diset tpcc maria_user            root
diset tpcc maria_pass            $pass
diset tpcc maria_dbase           tpcc
diset tpcc maria_storage_engine  innodb
diset tpcc maria_history_pk      false
diset tpcc maria_partition       false

puts "SCHEMA BUILD STARTED"
buildschema
puts "SCHEMA BUILD COMPLETED"
EOF

  # tpcc_run.tcl
  cat > "$tcl_dir/tpcc_run.tcl" <<'EOF'
set tmpdir [expr {[info exists ::env(TMP)] ? $::env(TMP) : "/tmp"}]
set vu     [expr {[info exists ::env(BENCH_VU)]   ? $::env(BENCH_VU)   : 8}]
set port   [expr {[info exists ::env(BENCH_PORT)] ? $::env(BENCH_PORT) : 3307}]
set pass   [expr {[info exists ::env(BENCH_PASS)] ? $::env(BENCH_PASS) : "tpccpass"}]
set ramp   [expr {[info exists ::env(BENCH_RAMP)] ? $::env(BENCH_RAMP) : 2}]
set dur    [expr {[info exists ::env(BENCH_DUR)]  ? $::env(BENCH_DUR)  : 10}]

puts "SETTING CONFIGURATION (TPC-C run, $vu VUs, ${ramp}m ramp, ${dur}m timed)"
dbset db maria
dbset bm TPC-C

diset connection maria_host   127.0.0.1
diset connection maria_port   $port
diset connection maria_socket null
diset connection maria_ssl    false

diset tpcc maria_user          root
diset tpcc maria_pass          $pass
diset tpcc maria_dbase         tpcc
diset tpcc maria_history_pk    false
diset tpcc maria_driver        timed
diset tpcc maria_rampup        $ramp
diset tpcc maria_duration      $dur
diset tpcc maria_allwarehouse  true
diset tpcc maria_timeprofile   true

loadscript
puts "TEST STARTED"
vuset vu $vu
vucreate
tcstart
tcstatus
set jobid [vurun]
vudestroy
tcstop
puts "TEST COMPLETE"
set of [open $tmpdir/maria_tprocc w]
puts $of $jobid
close $of
EOF

  # tpcc_result.tcl
  cat > "$tcl_dir/tpcc_result.tcl" <<'EOF'
set tmpdir [expr {[info exists ::env(TMP)] ? $::env(TMP) : "/tmp"}]
set ::outputfile $tmpdir/maria_tprocc
source ./scripts/tcl/generic/generic_tprocc_result.tcl
EOF

  # tpch_build.tcl
  cat > "$tcl_dir/tpch_build.tcl" <<'EOF'
puts "SETTING CONFIGURATION (TPC-H build)"
dbset db maria
dbset bm TPC-H

set port [expr {[info exists ::env(BENCH_PORT)] ? $::env(BENCH_PORT) : 3307}]
set sf   [expr {[info exists ::env(BENCH_SF)]   ? $::env(BENCH_SF)   : 1}]
set pass [expr {[info exists ::env(BENCH_PASS)] ? $::env(BENCH_PASS) : "tpccpass"}]
set lvu  [expr {[info exists ::env(BENCH_LVU)]  ? $::env(BENCH_LVU)  : 4}]

diset connection maria_host   127.0.0.1
diset connection maria_port   $port
diset connection maria_socket null
diset connection maria_ssl    false

diset tpch maria_scale_fact           $sf
diset tpch maria_num_tpch_threads     $lvu
diset tpch maria_tpch_user            root
diset tpch maria_tpch_pass            $pass
diset tpch maria_tpch_dbase           tpch
diset tpch maria_tpch_storage_engine  innodb

puts "SCHEMA BUILD STARTED"
buildschema
puts "SCHEMA BUILD COMPLETED"
EOF

  # tpch_run.tcl
  cat > "$tcl_dir/tpch_run.tcl" <<'EOF'
set tmpdir [expr {[info exists ::env(TMP)] ? $::env(TMP) : "/tmp"}]
set vu   [expr {[info exists ::env(BENCH_VU)]   ? $::env(BENCH_VU)   : 4}]
set port [expr {[info exists ::env(BENCH_PORT)] ? $::env(BENCH_PORT) : 3307}]
set sf   [expr {[info exists ::env(BENCH_SF)]   ? $::env(BENCH_SF)   : 1}]
set pass [expr {[info exists ::env(BENCH_PASS)] ? $::env(BENCH_PASS) : "tpccpass"}]

puts "SETTING CONFIGURATION (TPC-H run, $vu streams, SF=$sf)"
dbset db maria
dbset bm TPC-H

diset connection maria_host   127.0.0.1
diset connection maria_port   $port
diset connection maria_socket null
diset connection maria_ssl    false

diset tpch maria_scale_fact           $sf
diset tpch maria_num_tpch_threads     $vu
diset tpch maria_tpch_user            root
diset tpch maria_tpch_pass            $pass
diset tpch maria_tpch_dbase           tpch
diset tpch maria_tpch_storage_engine  innodb
diset tpch maria_total_querysets      1
diset tpch maria_raise_query_error    false
diset tpch maria_verbose              false
diset tpch maria_refresh_on           false
diset tpch maria_update_sets          1
diset tpch maria_trickle_refresh      0
diset tpch maria_refresh_verbose      false
diset tpch maria_cloud_query          false

loadscript
puts "TEST STARTED"
vuset vu $vu
vucreate
set jobid [vurun]
vudestroy
puts "TEST COMPLETE"
set of [open $tmpdir/maria_tproch w]
puts $of $jobid
close $of
EOF

  # tpch_result.tcl
  cat > "$tcl_dir/tpch_result.tcl" <<'EOF'
set tmpdir [expr {[info exists ::env(TMP)] ? $::env(TMP) : "/tmp"}]
set ::outputfile $tmpdir/maria_tproch
source ./scripts/tcl/generic/generic_tproch_result.tcl
EOF
}

# ── Container helpers ─────────────────────────────────────────────────────────
container_start() {
  local cores=$1 cnf=$2 workdir=$3
  log "Starting MariaDB ${MARIADB_VER} container (cpus=${cores}) ..."
  export BENCH_CPUS="$cores"
  export BENCH_CNF="$cnf"
  ( cd "$workdir" && $DOCKER_COMPOSE down -v --remove-orphans 2>/dev/null ) || true
  $DRY_RUN && { log "[dry-run] $DOCKER_COMPOSE up -d"; return; }
  ( cd "$workdir" && $DOCKER_COMPOSE up -d )
  log "Waiting for MariaDB on port ${DB_PORT} ..."
  local waited=0
  until docker exec "$CONTAINER" mysql -u"$DB_USER" -p"$DB_PASS" \
        -e "SELECT 1" &>/dev/null 2>&1; do
    printf "."; sleep 3; waited=$(( waited + 3 ))
    [[ $waited -gt 180 ]] && { echo ""; die "MariaDB did not start within 3 minutes"; }
  done
  echo " ready."
  log "Buffer pool / I/O threads:"
  docker exec "$CONTAINER" mysql -u"$DB_USER" -p"$DB_PASS" -e "
    SELECT @@innodb_buffer_pool_size/1024/1024/1024 AS buffer_pool_GB,
           @@innodb_read_io_threads  AS read_io,
           @@innodb_write_io_threads AS write_io,
           @@innodb_purge_threads    AS purge;" 2>/dev/null || true
}

container_stop() {
  local workdir=$1
  log "Tearing down container ..."
  $DRY_RUN && { log "[dry-run] $DOCKER_COMPOSE down -v"; return; }
  ( cd "$workdir" && $DOCKER_COMPOSE down -v --remove-orphans 2>/dev/null ) || true
}

# ── HammerDB run helper ───────────────────────────────────────────────────────
hdb_run() {
  local label=$1 script=$2 logfile=$3
  log "HammerDB: $label ..."
  $DRY_RUN && { log "[dry-run] hammerdbcli auto $script"; return; }
  rm -f /tmp/hammer.DB
  export TMP=/tmp
  cd "$HAMMERDB_DIR"
  ./hammerdbcli auto "$script" 2>&1 | tee "$logfile"
}

hdb_result() {
  local label=$1 script=$2 logfile=$3
  log "Extracting $label results ..."
  $DRY_RUN && { log "[dry-run] hammerdbcli auto $script"; return; }
  rm -f /tmp/hammer.DB
  export TMP=/tmp
  cd "$HAMMERDB_DIR"
  ./hammerdbcli auto "$script" 2>&1 | tee "$logfile" || true
}

# ── Per-config benchmark ──────────────────────────────────────────────────────
run_config() {
  local cores=$1 workdir=$2 tcl_dir=$3
  local tpcc_vu=$cores
  [[ $tpcc_vu -gt 128 ]] && tpcc_vu=128
  local tpch_vu=$(( cores / 2 ))
  [[ $tpch_vu -lt 2 ]] && tpch_vu=2
  local rdir="$workdir/results/${cores}core"

  # Skip if results already exist and --force not set
  if ! $FORCE && [[ -f "$rdir/tpcc_summary.txt" ]]; then
    warn "Results for ${cores}-core already exist — skipping (use --force to re-run)"
    return
  fi

  mkdir -p "$rdir"
  hr
  log "STARTING ${cores}-CORE BENCHMARK  (TPC-C VUs=${tpcc_vu}  TPC-H VUs=${tpch_vu})"
  hr

  local cnf="$workdir/configs/${cores}core.cnf"
  local t0=$SECONDS

  # Export env vars for TCL scripts
  export BENCH_PORT="$DB_PORT"
  export BENCH_PASS="$DB_PASS"
  export BENCH_WARE="$WAREHOUSES"
  export BENCH_RAMP="$RAMPUP"
  export BENCH_DUR="$DURATION"
  export BENCH_SF="$TPCH_SF"
  export BENCH_LVU=8   # loader VUs for schema build

  container_start "$cores" "$cnf" "$workdir"

  # ── TPC-C ──────────────────────────────────────────────────────────────────
  local build_est=$(( WAREHOUSES * 15 / 60 + 1 ))
  log "=== TPC-C: building schema (${WAREHOUSES} warehouses, 8 loader VUs) ==="
  log "Expected: ${build_est}-$((build_est*2)) min"
  hdb_run "TPC-C build" "$tcl_dir/tpcc_build.tcl" "$rdir/tpcc_build.log"

  log "=== TPC-C: timed run (${tpcc_vu} VUs, ${RAMPUP}m ramp + ${DURATION}m timed) ==="
  export BENCH_VU="$tpcc_vu"
  hdb_run "TPC-C run" "$tcl_dir/tpcc_run.tcl" "$rdir/tpcc_run.log"

  log "=== TPC-C: extracting results ==="
  hdb_result "TPC-C" "$tcl_dir/tpcc_result.tcl" "$rdir/tpcc_result.log"

  [[ -f /tmp/hdbxtprofile.log ]] && cp /tmp/hdbxtprofile.log "$rdir/tpcc_latency.log"

  local nopm tpm
  nopm=$(grep -oP "(?<=System achieved )\d+" "$rdir/tpcc_result.log" 2>/dev/null \
         || grep -oP "\d+(?= NOPM)" "$rdir/tpcc_run.log" 2>/dev/null \
         || echo "see_log")
  tpm=$(grep -oP "\d+(?= MariaDB TPM)" "$rdir/tpcc_result.log" 2>/dev/null \
        || echo "see_log")
  {
    echo "NOPM=$nopm"
    echo "TPM=$tpm"
    echo "VUs=$tpcc_vu"
    echo "warehouses=$WAREHOUSES"
    echo "cores=$cores"
  } > "$rdir/tpcc_summary.txt"
  ok "TPC-C: NOPM=$nopm  TPM=$tpm"

  # ── TPC-H ──────────────────────────────────────────────────────────────────
  if ! $SKIP_TPCH; then
    log "=== TPC-H: building schema (SF=${TPCH_SF}, 4 loader threads) ==="
    hdb_run "TPC-H build" "$tcl_dir/tpch_build.tcl" "$rdir/tpch_build.log"

    log "=== TPC-H: timed run (${tpch_vu} streams) ==="
    export BENCH_VU="$tpch_vu"
    hdb_run "TPC-H run" "$tcl_dir/tpch_run.tcl" "$rdir/tpch_run.log"

    log "=== TPC-H: extracting results ==="
    hdb_result "TPC-H" "$tcl_dir/tpch_result.tcl" "$rdir/tpch_result.log"

    local geomean total_t
    geomean=$(grep -oP '(?<=Geometric mean of query times returning rows \(22\) is ")[0-9.]+' \
              "$rdir/tpch_result.log" 2>/dev/null || echo "see_log")
    total_t=$(grep -oP '\d+(?= seconds)' "$rdir/tpch_result.log" 2>/dev/null | tail -1 || echo "see_log")
    {
      echo "VUs=$tpch_vu"
      echo "SF=$TPCH_SF"
      echo "cores=$cores"
      echo "geomean_s=$geomean"
      echo "stream_total_s=$total_t"
    } > "$rdir/tpch_summary.txt"
    ok "TPC-H: geomean=${geomean}s  stream=${total_t}s"
  fi

  container_stop "$workdir"

  local elapsed=$(( SECONDS - t0 ))
  echo "elapsed_seconds=$elapsed" >> "$rdir/tpcc_summary.txt"
  log "COMPLETED ${cores}-CORE in ${elapsed}s"
  hr
}

# ── Report generator ──────────────────────────────────────────────────────────
generate_report() {
  local workdir=$1
  local rpt="$workdir/results/benchmark_report.md"

  section "Generating report ..."

  # Collect results
  local cores_done=()
  for d in "$workdir/results"/*/; do
    local c
    c=$(basename "$d" | sed 's/core//')
    [[ -f "$d/tpcc_summary.txt" ]] && cores_done+=("$c")
  done

  if [[ ${#cores_done[@]} -eq 0 ]]; then
    warn "No completed results found — skipping report"
    return
  fi

  # Sort numerically
  IFS=$'\n' cores_done=($(sort -n <<<"${cores_done[*]}")); unset IFS

  {
    echo "# MariaDB ${MARIADB_VER} TPC-C / TPC-H Benchmark Report"
    echo ""
    echo "**Generated:** $(date)"
    echo ""
    echo "---"
    echo ""
    echo "## Configuration"
    echo ""
    echo "| Parameter | Value |"
    echo "|-----------|-------|"
    echo "| MariaDB version | ${MARIADB_VER} |"
    echo "| TPC-C warehouses | ${WAREHOUSES} |"
    echo "| TPC-C ramp / timed | ${RAMPUP} min / ${DURATION} min |"
    echo "| TPC-H scale factor | ${TPCH_SF} |"
    echo "| InnoDB buffer pool | ${BUFFER_POOL} |"
    echo "| Host CPU cores | ${HOST_CORES} |"
    echo "| Host RAM | ${HOST_RAM_GiB} GiB |"
    echo "| HammerDB version | ${HAMMERDB_VERSION} |"
    echo ""

    echo "---"
    echo ""
    echo "## TPC-C Results (OLTP)"
    echo ""
    echo "| Cores | VUs | NOPM | MariaDB TPM | TPM/VU |"
    echo "|-------|-----|------|-------------|--------|"
    local baseline_nopm=0
    for c in "${cores_done[@]}"; do
      local d="$workdir/results/${c}core"
      local nopm vu tpm
      nopm=$(grep -oP "(?<=NOPM=).*" "$d/tpcc_summary.txt" 2>/dev/null || echo "—")
      tpm=$(grep  -oP "(?<=TPM=).*"  "$d/tpcc_summary.txt" 2>/dev/null || echo "—")
      vu=$(grep   -oP "(?<=VUs=).*"  "$d/tpcc_summary.txt" 2>/dev/null | head -1 || echo "—")
      local tpm_vu="—"
      if [[ "$tpm" =~ ^[0-9]+$ && "$vu" =~ ^[0-9]+$ ]]; then
        tpm_vu=$(( tpm / vu ))
      fi
      [[ $baseline_nopm -eq 0 && "$nopm" =~ ^[0-9]+$ ]] && baseline_nopm=$nopm
      echo "| ${c} | ${vu} | ${nopm} | ${tpm} | ${tpm_vu} |"
    done
    echo ""

    echo "### Transaction Latency (ms)"
    echo ""
    echo "#### NEWORD (New Order — ~55% of mix)"
    echo ""
    echo "| Cores | p50 | p95 | p99 | avg | max |"
    echo "|-------|-----|-----|-----|-----|-----|"
    for c in "${cores_done[@]}"; do
      local rf="$workdir/results/${c}core/tpcc_result.log"
      [[ -f "$rf" ]] || continue
      local p50 p95 p99 avg mx
      p50=$(grep -A30 '"NEWORD"' "$rf" | grep p50_ms  | grep -oP '[0-9.]+' || echo "—")
      p95=$(grep -A30 '"NEWORD"' "$rf" | grep p95_ms  | grep -oP '[0-9.]+' || echo "—")
      p99=$(grep -A30 '"NEWORD"' "$rf" | grep p99_ms  | grep -oP '[0-9.]+' || echo "—")
      avg=$(grep -A30 '"NEWORD"' "$rf" | grep '"avg_ms"' | grep -oP '[0-9.]+' || echo "—")
      mx=$(grep  -A30 '"NEWORD"' "$rf" | grep '"max_ms"' | grep -oP '[0-9.]+' || echo "—")
      echo "| ${c} | ${p50} | ${p95} | ${p99} | ${avg} | ${mx} |"
    done
    echo ""

    echo "#### DELIVERY (~14% of mix — most lock-sensitive)"
    echo ""
    echo "| Cores | p50 | p95 | p99 | avg | max |"
    echo "|-------|-----|-----|-----|-----|-----|"
    for c in "${cores_done[@]}"; do
      local rf="$workdir/results/${c}core/tpcc_result.log"
      [[ -f "$rf" ]] || continue
      local p50 p95 p99 avg mx
      p50=$(grep -A30 '"DELIVERY"' "$rf" | grep p50_ms   | grep -oP '[0-9.]+' || echo "—")
      p95=$(grep -A30 '"DELIVERY"' "$rf" | grep p95_ms   | grep -oP '[0-9.]+' || echo "—")
      p99=$(grep -A30 '"DELIVERY"' "$rf" | grep p99_ms   | grep -oP '[0-9.]+' || echo "—")
      avg=$(grep -A30 '"DELIVERY"' "$rf" | grep '"avg_ms"' | grep -oP '[0-9.]+' || echo "—")
      mx=$(grep  -A30 '"DELIVERY"' "$rf" | grep '"max_ms"' | grep -oP '[0-9.]+' || echo "—")
      echo "| ${c} | ${p50} | ${p95} | ${p99} | ${avg} | ${mx} |"
    done
    echo ""

    if ! $SKIP_TPCH; then
      echo "---"
      echo ""
      echo "## TPC-H Results (Analytics, SF=${TPCH_SF})"
      echo ""
      echo "| Cores | Streams | Stream time (s) | Geomean query time (s) |"
      echo "|-------|---------|----------------|------------------------|"
      for c in "${cores_done[@]}"; do
        local sf="$workdir/results/${c}core/tpch_summary.txt"
        [[ -f "$sf" ]] || continue
        local vu geomean total_t
        vu=$(      grep -oP "(?<=VUs=).*"          "$sf" 2>/dev/null || echo "—")
        geomean=$( grep -oP "(?<=geomean_s=).*"    "$sf" 2>/dev/null || echo "—")
        total_t=$( grep -oP "(?<=stream_total_s=).*" "$sf" 2>/dev/null || echo "—")
        echo "| ${c} | ${vu} | ${total_t} | ${geomean} |"
      done
      echo ""
    fi

    echo "---"
    echo ""
    echo "## Notes"
    echo ""
    echo "- \`NOPM\` (New Orders Per Minute) is the primary TPC-C metric; TPM includes all five transaction types."
    echo "- \`TPM/VU\` measures per-user efficiency; a large drop as VUs increase indicates lock/latch contention."
    echo "- DELIVERY p99 is the most sensitive indicator of InnoDB row-lock pressure."
    echo "- TPC-H geomean is computed over the 22 queries that return rows; Q17/Q22 are often excluded by some tools."
    echo "- \`innodb_flush_log_at_trx_commit=0\` and \`innodb_doublewrite=0\` are used for maximum throughput; production deployments should use safer values."
  } > "$rpt"

  ok "Report written to $rpt"

  # Print ASCII summary table
  echo ""
  section "Results Summary"
  printf "${BLD}%-8s %-6s %-10s %-12s %-10s${RST}\n" "Cores" "VUs" "NOPM" "TPM" "TPM/VU"
  for c in "${cores_done[@]}"; do
    local d="$workdir/results/${c}core"
    local nopm vu tpm tpm_vu
    nopm=$(grep -oP "(?<=NOPM=).*" "$d/tpcc_summary.txt" 2>/dev/null || echo "—")
    tpm=$(grep  -oP "(?<=TPM=).*"  "$d/tpcc_summary.txt" 2>/dev/null || echo "—")
    vu=$(grep   -oP "(?<=VUs=).*"  "$d/tpcc_summary.txt" 2>/dev/null | head -1 || echo "—")
    tpm_vu="—"
    if [[ "$tpm" =~ ^[0-9]+$ && "$vu" =~ ^[0-9]+$ ]]; then
      tpm_vu=$(printf "%'.0f" $(( tpm / vu )) 2>/dev/null || echo $(( tpm / vu )))
    fi
    [[ "$nopm" =~ ^[0-9]+$ ]] && nopm=$(printf "%'.0f" "$nopm" 2>/dev/null || echo "$nopm")
    [[ "$tpm"  =~ ^[0-9]+$ ]] && tpm=$(printf  "%'.0f" "$tpm"  2>/dev/null || echo "$tpm")
    printf "%-8s %-6s %-10s %-12s %-10s\n" "$c" "$vu" "$nopm" "$tpm" "$tpm_vu"
  done

  if ! $SKIP_TPCH; then
    echo ""
    printf "${BLD}%-8s %-8s %-16s %-20s${RST}\n" "Cores" "Streams" "Stream time (s)" "Geomean query (s)"
    for c in "${cores_done[@]}"; do
      local sf="$workdir/results/${c}core/tpch_summary.txt"
      [[ -f "$sf" ]] || continue
      local vu geomean total_t
      vu=$(      grep -oP "(?<=VUs=).*"            "$sf" 2>/dev/null || echo "—")
      geomean=$( grep -oP "(?<=geomean_s=).*"      "$sf" 2>/dev/null || echo "—")
      total_t=$( grep -oP "(?<=stream_total_s=).*" "$sf" 2>/dev/null || echo "—")
      printf "%-8s %-8s %-16s %-20s\n" "$c" "$vu" "$total_t" "$geomean"
    done
  fi
  echo ""
}

# ── Cleanup trap ──────────────────────────────────────────────────────────────
WORKDIR_TRAP=""
cleanup() {
  if [[ -n "$WORKDIR_TRAP" && -f "$WORKDIR_TRAP/docker-compose.yml" ]]; then
    log "Caught signal — stopping container if running ..."
    ( cd "$WORKDIR_TRAP" && ${DOCKER_COMPOSE:-docker compose} down -v --remove-orphans 2>/dev/null ) || true
  fi
}
trap cleanup EXIT INT TERM

# ═════════════════════════════════════════════════════════════════════════════
#  MAIN
# ═════════════════════════════════════════════════════════════════════════════
main() {
  section "MariaDB TPC-C / TPC-H Benchmark Setup"

  check_deps
  detect_system

  log "Host: ${HOST_CORES} logical CPUs, ${HOST_RAM_GiB} GiB RAM"

  # ── Interactive configuration ─────────────────────────────────────────────
  echo ""
  log "Press Enter to accept defaults shown in [green]."
  $YES && log "(--yes flag set — using all defaults)"
  echo ""

  # Core list
  local suggested_cores
  suggested_cores=$(auto_cores_list)
  [[ -z "$suggested_cores" ]] && suggested_cores="4"
  [[ -z "$CORES_LIST" ]] && \
    prompt CORES_LIST \
      "CPU core configs to test (space-separated, must be ≤ ${HOST_CORES})" \
      "$suggested_cores"

  # Warehouses
  local ware_suggest=$WAREHOUSES
  prompt WAREHOUSES "TPC-C warehouses (≥ 2× max VUs recommended)" "$ware_suggest"

  # Ramp / duration
  prompt RAMPUP   "TPC-C ramp-up minutes"  "$RAMPUP"
  prompt DURATION "TPC-C timed-run minutes" "$DURATION"

  # TPC-H
  if ! $SKIP_TPCH; then
    local tpch_ans
    prompt tpch_ans "Run TPC-H analytics benchmark? (yes/no)" "yes"
    [[ "$tpch_ans" == no* ]] && SKIP_TPCH=true
  fi
  if ! $SKIP_TPCH; then
    prompt TPCH_SF "TPC-H scale factor (1 / 10 / 30 / 100)" "$TPCH_SF"
  fi

  # Buffer pool
  local auto_bp
  auto_bp=$(auto_buffer_pool)
  [[ -z "$BUFFER_POOL" ]] && BUFFER_POOL="$auto_bp"
  prompt BUFFER_POOL "InnoDB buffer pool size (e.g. ${auto_bp})" "$BUFFER_POOL"

  # Port
  prompt DB_PORT "Host port for MariaDB" "$DB_PORT"

  # MariaDB version
  prompt MARIADB_VER "MariaDB Docker image tag" "$MARIADB_VER"

  # Workdir
  local default_wd="./mariadb-bench-$(date '+%Y%m%d')"
  [[ -z "$WORKDIR" ]] && WORKDIR="$default_wd"
  prompt WORKDIR "Output / working directory" "$WORKDIR"

  # HammerDB dir (shown only if not already found)
  if [[ -z "$HAMMERDB_DIR" ]]; then
    local hdb_exists=""
    for candidate in "$HOME/HammerDB" "/opt/HammerDB" "./HammerDB" \
                     "$HOME/HammerDB-${HAMMERDB_VERSION}"; do
      [[ -x "$candidate/hammerdbcli" ]] && { hdb_exists="$candidate"; break; }
    done
    if [[ -n "$hdb_exists" ]]; then
      prompt HAMMERDB_DIR "HammerDB directory" "$hdb_exists"
    else
      prompt HAMMERDB_DIR \
        "HammerDB directory (leave blank to auto-download v${HAMMERDB_VERSION})" ""
    fi
  fi

  # ── Validate ──────────────────────────────────────────────────────────────
  # Validate core list
  local cores_arr=()
  for c in $CORES_LIST; do
    [[ "$c" =~ ^[0-9]+$ ]] || die "Invalid core count: $c"
    [[ $c -gt $HOST_CORES ]] && \
      warn "Requested ${c} cores but host only has ${HOST_CORES} — Docker will be limited by physical cores"
    cores_arr+=("$c")
  done
  [[ ${#cores_arr[@]} -eq 0 ]] && die "No valid core configs specified"

  # ── Summary before running ────────────────────────────────────────────────
  echo ""
  section "Run Plan"
  echo -e "  Core configs    : ${BLD}${CORES_LIST}${RST}"
  echo -e "  Warehouses      : ${BLD}${WAREHOUSES}${RST}"
  echo -e "  TPC-C           : ${RAMPUP}m ramp + ${DURATION}m timed"
  if ! $SKIP_TPCH; then
    echo -e "  TPC-H           : SF-${TPCH_SF}"
  else
    echo -e "  TPC-H           : skipped"
  fi
  echo -e "  Buffer pool     : ${BLD}${BUFFER_POOL}${RST}"
  echo -e "  MariaDB port    : ${DB_PORT}"
  echo -e "  MariaDB version : ${MARIADB_VER}"
  echo -e "  Working dir     : ${BLD}${WORKDIR}${RST}"
  echo ""

  local est_min=0
  for c in "${cores_arr[@]}"; do
    local build_min=$(( WAREHOUSES / 4 + 5 ))
    local run_min=$(( RAMPUP + DURATION + 2 ))
    local tpch_min=0
    $SKIP_TPCH || tpch_min=$(( TPCH_SF * 10 + 5 ))
    est_min=$(( est_min + build_min + run_min + tpch_min + 5 ))
  done
  echo -e "  Estimated time  : ~${est_min} minutes total"
  echo ""

  if ! $YES && ! $DRY_RUN; then
    local go
    printf "${BLD}Proceed? (yes/no) [yes]:${RST} "
    read -r go
    [[ "${go:-yes}" == no* ]] && { log "Aborted."; exit 0; }
  fi

  # ── Setup workdir ─────────────────────────────────────────────────────────
  mkdir -p "$WORKDIR/configs" "$WORKDIR/results"
  WORKDIR="$(cd "$WORKDIR" && pwd)"   # absolute path
  WORKDIR_TRAP="$WORKDIR"

  # Generate docker-compose
  generate_compose "$WORKDIR/docker-compose.yml"

  # Generate TCL scripts
  local tcl_dir="$WORKDIR/tcl"
  generate_tcl "$tcl_dir"

  # Generate MariaDB configs
  for c in "${cores_arr[@]}"; do
    generate_cnf "$c" "$BUFFER_POOL" "$WORKDIR/configs/${c}core.cnf"
  done

  # Setup HammerDB (download if needed)
  setup_hammerdb

  # Make TCL scripts use absolute paths for sourcing HammerDB generics
  # HammerDB result scripts source from relative paths — we run from $HAMMERDB_DIR
  # which is already handled in hdb_run/hdb_result (cd into HAMMERDB_DIR first).

  ok "Files generated in $WORKDIR"
  log "HammerDB: $HAMMERDB_DIR"

  # ── Run benchmarks ────────────────────────────────────────────────────────
  section "Running Benchmarks"
  for c in "${cores_arr[@]}"; do
    run_config "$c" "$WORKDIR" "$tcl_dir"
  done

  # ── Generate report ───────────────────────────────────────────────────────
  generate_report "$WORKDIR"

  ok "All done. Results and report in: $WORKDIR/results/"
}

main
