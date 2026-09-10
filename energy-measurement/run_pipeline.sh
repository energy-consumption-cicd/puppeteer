#!/usr/bin/env bash

set -euo pipefail

RUN_NUM="${1:?run number required (e.g. 1)}"
PROJECT_NAME="puppeteer"
IMAGE_NAME="${IMAGE_NAME:-puppeteer-medicao}"
MEDICAO_DIR="$HOME/experimentos/medicao/repositorios/puppeteer"
RESULTS_DIR="${RESULTS_DIR:-$HOME/experimentos/medicao/resultados/puppeteer/runs}"
LOGS_DIR="${LOGS_DIR:-$HOME/experimentos/medicao/resultados/puppeteer/logs}"
RAPL_BASE="/sys/class/powercap/intel-rapl"
# Idle baseline measured before each run; its per-second rate is subtracted
# from every stage so reported energy reflects workload above idle.
BASELINE_DURATION=120
# Pre-condition on the bench, checked before any workload runs: an idle package
# rate above this means the bench is not idle, and the run is not started.
# Exit 90 sits outside every declared workload exit code; ENERGY_BASELINE_GATE=off
# disables it for declared diagnostic sessions only.
BASELINE_GATE_MAX_PKG_W=1.0
BASELINE_GATE_EXIT=90
ENERGY_BASELINE_GATE="${ENERGY_BASELINE_GATE:-on}"
# Stage ceiling: a hung harness costs one run, not the job's 20 h. Exit 91 sits
# outside every declared workload exit code, like 90. The values below are
# provisional; they are fixed at 1.25 to 1.5x the largest wall observed in the
# smoke run on the measurement bench, and the real cost is the ceiling plus the
# 30 s of -k. Non-default values are for declared diagnostic sessions only and
# are recorded in the sidecar.
STAGE_TIMEOUT_BUILD_DEFAULT=300
STAGE_TIMEOUT_TEST_DEFAULT=1200
ENERGY_STAGE_TIMEOUT_BUILD_S="${ENERGY_STAGE_TIMEOUT_BUILD_S:-$STAGE_TIMEOUT_BUILD_DEFAULT}"
ENERGY_STAGE_TIMEOUT_TEST_S="${ENERGY_STAGE_TIMEOUT_TEST_S:-$STAGE_TIMEOUT_TEST_DEFAULT}"
STAGE_TIMEOUT_EXIT=91
TIME_FILE="/tmp/puppeteer_time_$$.txt"
CSV_FILE="$RESULTS_DIR/run_$(printf '%02d' "$RUN_NUM").csv"
EXITS_FILE="$RESULTS_DIR/exit_codes_run_$(printf '%02d' "$RUN_NUM").txt"
BASELINE_DISCARD_FILE="$RESULTS_DIR/discarded_baseline_run_$(printf '%02d' "$RUN_NUM").txt"
TIMEOUT_DISCARD_FILE="$RESULTS_DIR/discarded_timeout_run_$(printf '%02d' "$RUN_NUM").txt"

# No swap inside the container: the limit is the bench's usable RAM.
MEM_LIMIT="${MEM_LIMIT:-12g}"
MEM_SWAP="${MEM_SWAP:-$MEM_LIMIT}"

# The image holds the build output and a primed wireit cache, which is the
# state the test job restores from the Actions cache. The build stage runs on
# a per-run volume where a setup container, outside the measured window, has
# dropped both, so the measured command compiles as the job does on a cache
# miss. The test stage runs from the untouched image.
BUILD_VOLUME=""

PIPELINE_EXIT=0
FAILED_STAGES=""

# A signal to the docker client does not stop the container; kill it by name.
CURRENT_CONTAINER=""
cleanup_container() {
  if [ -n "$CURRENT_CONTAINER" ]; then
    docker kill "$CURRENT_CONTAINER" >/dev/null 2>&1 || true
  fi
  if [ -n "$BUILD_VOLUME" ]; then
    docker volume rm -f "$BUILD_VOLUME" >/dev/null 2>&1 || true
  fi
}
trap cleanup_container EXIT INT TERM

mkdir -p "$RESULTS_DIR" "$LOGS_DIR"

if [ ! -d "$RAPL_BASE" ]; then
  echo "RAPL not available at $RAPL_BASE" >&2
  exit 1
fi

if ! docker image inspect "$IMAGE_NAME" &>/dev/null; then
  echo "Docker image '$IMAGE_NAME' not found." >&2
  echo "  Build it first:" >&2
  echo "  docker build -t $IMAGE_NAME -f $MEDICAO_DIR/Dockerfile \\" >&2
  echo "    ~/experimentos/repositorios/nao-ml/puppeteer/" >&2
  exit 1
fi

: > "$EXITS_FILE"

# Records which RAPL domains the bench exposes, so a zero column is auditable.
for d in "$RAPL_BASE"/*/ "$RAPL_BASE"/*/*/; do [ -f "$d/name" ] && printf '%s,%s\n' "$(basename "$d")" "$(cat "$d/name")"; done > "$RESULTS_DIR/rapl_domains_run_$(printf '%02d' "$RUN_NUM").txt"

read_rapl() {
  local domain_name="$1"
  local value=0
  for dir in "$RAPL_BASE"/*/; do
    local name_file="$dir/name"
    [ -f "$name_file" ] || continue
    local name
    name=$(cat "$name_file")
    if [[ "$name" == "package-0" && "$domain_name" == "pkg" ]] || \
       [[ "$name" == "core"      && "$domain_name" == "cores" ]] || \
       [[ "$name" == "uncore"    && "$domain_name" == "gpu" ]] || \
       [[ "$name" == "dram"      && "$domain_name" == "ram" ]]; then
      local energy_file="$dir/energy_uj"
      [ -f "$energy_file" ] && value=$(cat "$energy_file") && break
    fi
    for subdir in "$dir"*/; do
      local sub_name_file="$subdir/name"
      [ -f "$sub_name_file" ] || continue
      local sub_name
      sub_name=$(cat "$sub_name_file")
      if [[ "$sub_name" == "core"   && "$domain_name" == "cores" ]] || \
         [[ "$sub_name" == "uncore" && "$domain_name" == "gpu" ]] || \
         [[ "$sub_name" == "dram"   && "$domain_name" == "ram" ]]; then
        local sub_energy="$subdir/energy_uj"
        [ -f "$sub_energy" ] && value=$(cat "$sub_energy") && break 2
      fi
    done
  done
  echo "$value"
}

read_rapl_max() {
  local domain_name="$1"
  local value=0
  for dir in "$RAPL_BASE"/*/; do
    local name_file="$dir/name"
    [ -f "$name_file" ] || continue
    local name
    name=$(cat "$name_file")
    if [[ "$name" == "package-0" && "$domain_name" == "pkg" ]]; then
      local max_file="$dir/max_energy_range_uj"
      [ -f "$max_file" ] && value=$(cat "$max_file") && break
    fi
    for subdir in "$dir"*/; do
      local sub_name_file="$subdir/name"
      [ -f "$sub_name_file" ] || continue
      local sub_name
      sub_name=$(cat "$sub_name_file")
      if [[ "$sub_name" == "core"   && "$domain_name" == "cores" ]] || \
         [[ "$sub_name" == "uncore" && "$domain_name" == "gpu" ]] || \
         [[ "$sub_name" == "dram"   && "$domain_name" == "ram" ]]; then
        local sub_max="$subdir/max_energy_range_uj"
        [ -f "$sub_max" ] && value=$(cat "$sub_max") && break 2
      fi
    done
  done
  [ "$value" -eq 0 ] && value=999999999999
  echo "$value"
}

# RAPL counters wrap at max_energy_range_uj; deltas are overflow-corrected.
delta_uj() {
  local ini="$1" fin="$2" max="$3"
  if [ "$fin" -ge "$ini" ]; then
    echo $(( fin - ini ))
  else
    echo $(( max - ini + fin ))
  fi
}

echo ""
echo ""
echo " Run $RUN_NUM - $PROJECT_NAME"
echo " $(date '+%Y-%m-%d %H:%M:%S')"
echo ""
echo "Baseline rest (${BASELINE_DURATION}s)..."

b_pkg_ini=$(read_rapl pkg)
b_cores_ini=$(read_rapl cores)
b_gpu_ini=$(read_rapl gpu)
b_ram_ini=$(read_rapl ram)

sleep "$BASELINE_DURATION"

b_pkg_fin=$(read_rapl pkg)
b_cores_fin=$(read_rapl cores)
b_gpu_fin=$(read_rapl gpu)
b_ram_fin=$(read_rapl ram)

max_pkg=$(read_rapl_max pkg)
max_cores=$(read_rapl_max cores)
max_gpu=$(read_rapl_max gpu)
max_ram=$(read_rapl_max ram)

b_delta_pkg=$(delta_uj "$b_pkg_ini" "$b_pkg_fin" "$max_pkg")
b_delta_cores=$(delta_uj "$b_cores_ini" "$b_cores_fin" "$max_cores")
b_delta_gpu=$(delta_uj "$b_gpu_ini" "$b_gpu_fin" "$max_gpu")
b_delta_ram=$(delta_uj "$b_ram_ini" "$b_ram_fin" "$max_ram")

taxa_pkg=$(awk  "BEGIN {printf \"%.6f\", $b_delta_pkg  / $BASELINE_DURATION}")
taxa_cores=$(awk "BEGIN {printf \"%.6f\", $b_delta_cores / $BASELINE_DURATION}")
taxa_gpu=$(awk  "BEGIN {printf \"%.6f\", $b_delta_gpu  / $BASELINE_DURATION}")
taxa_ram=$(awk  "BEGIN {printf \"%.6f\", $b_delta_ram  / $BASELINE_DURATION}")

# Recorded per run: the rate drives the subtraction, so it has to be auditable
# alongside the energy it produced.
taxa_pkg_w=$(awk   "BEGIN {printf \"%.6f\", $taxa_pkg   / 1e6}")
taxa_cores_w=$(awk "BEGIN {printf \"%.6f\", $taxa_cores / 1e6}")
taxa_ram_w=$(awk   "BEGIN {printf \"%.6f\", $taxa_ram   / 1e6}")

echo "Baseline rate:"
echo "   pkg:   $(awk "BEGIN {printf \"%.2f\", $taxa_pkg_w}") W"
echo "   cores: $(awk "BEGIN {printf \"%.2f\", $taxa_cores_w}") W"
echo "   ram:   $(awk "BEGIN {printf \"%.2f\", $taxa_ram_w}") W"

if [ "$ENERGY_BASELINE_GATE" != "off" ] && \
   awk "BEGIN {exit !($taxa_pkg_w > $BASELINE_GATE_MAX_PKG_W)}"; then
  {
    echo "run,$RUN_NUM"
    echo "timestamp_utc,$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "baseline_rate_pkg_w,$taxa_pkg_w"
    echo "baseline_rate_cores_w,$taxa_cores_w"
    echo "baseline_rate_ram_w,$taxa_ram_w"
    echo "threshold_pkg_w,$BASELINE_GATE_MAX_PKG_W"
  } > "$BASELINE_DISCARD_FILE"
  echo "::error title=Baseline gate::run $RUN_NUM: idle package rate ${taxa_pkg_w} W exceeds ${BASELINE_GATE_MAX_PKG_W} W; the bench is not idle. Run not started; see $BASELINE_DISCARD_FILE"
  rm -f "$EXITS_FILE"
  exit "$BASELINE_GATE_EXIT"
fi
if [ "$ENERGY_BASELINE_GATE" = "off" ]; then
  echo "::warning title=Baseline gate disabled::ENERGY_BASELINE_GATE=off for run $RUN_NUM (diagnostic session; must be declared)"
fi
if [ "$ENERGY_STAGE_TIMEOUT_BUILD_S" != "$STAGE_TIMEOUT_BUILD_DEFAULT" ] || \
   [ "$ENERGY_STAGE_TIMEOUT_TEST_S" != "$STAGE_TIMEOUT_TEST_DEFAULT" ]; then
  echo "::warning title=Stage ceiling changed::build ${ENERGY_STAGE_TIMEOUT_BUILD_S}s, test ${ENERGY_STAGE_TIMEOUT_TEST_S}s for run $RUN_NUM (pre-registered ${STAGE_TIMEOUT_BUILD_DEFAULT}s/${STAGE_TIMEOUT_TEST_DEFAULT}s; diagnostic session; must be declared)"
fi

echo "run,stage,energy_pkg_j,energy_cores_j,energy_gpu_j,energy_ram_j,wall_time_s,user_time_s,sys_time_s,energy_ram_liquid_raw_j,wall_time_container_s,baseline_rate_pkg_w,baseline_rate_cores_w,baseline_rate_ram_w" \
  > "$CSV_FILE"

total_pkg=0; total_cores=0; total_gpu=0; total_ram=0; total_ram_raw=0
total_wall=0; total_user=0; total_sys=0; total_wall_container=0

# Ceiling reached: no measurement exists, so no CSV row; the sidecar records the
# ceiling applied and the last known progress marker, and the run exits 91.
abort_stage_timeout() {
  local stage="$1" ceiling="$2" texit="$3" cname="$4" start_utc="$5" stage_log="$6" wall="$7"
  local abort_utc kill_result marker last_line last_utc
  abort_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  if docker kill "$cname" >/dev/null 2>&1; then kill_result="ok"; else kill_result="no-such-container"; fi
  docker rm -f "$cname" >/dev/null 2>&1 || true
  CURRENT_CONTAINER=""
  if [ -n "$BUILD_VOLUME" ]; then
    docker volume rm -f "$BUILD_VOLUME" >/dev/null 2>&1 || true
    BUILD_VOLUME=""
  fi
  # Every lookup below may legitimately find nothing; none may trip errexit.
  marker=$(grep -E '^=== .*: start ' "$stage_log" 2>/dev/null | tail -n 1 || true)
  last_line=$(tail -n 1 "$stage_log" 2>/dev/null | sed 's/\x1b\[[0-9;]*[A-Za-z]//g' | cut -c1-200 || true)
  last_utc=$(date -u -r "$stage_log" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "-")
  {
    echo "run,$RUN_NUM"
    echo "stage,$stage"
    echo "timeout_s,$ceiling"
    echo "timeout_exit,$texit"
    echo "start_utc,$start_utc"
    echo "abort_utc,$abort_utc"
    echo "wall_observed_s,$wall"
    echo "container,$cname"
    echo "docker_kill,$kill_result"
    echo "stage_log,logs/$(basename "$stage_log")"
    echo "last_step_marker,${marker:--}"
    echo "last_log_line_utc,$last_utc"
    echo "last_log_line,${last_line:--}"
    echo "csv_row_written,no"
  } > "$TIMEOUT_DISCARD_FILE"
  echo "$RUN_NUM,$stage,$STAGE_TIMEOUT_EXIT" >> "$EXITS_FILE"
  rm -f "$CSV_FILE" "$TIME_FILE"
  echo "::error title=Stage ceiling::run $RUN_NUM, stage '$stage': ${wall}s exceeded the ${ceiling}s ceiling (timeout exit $texit); container $cname killed ($kill_result). No CSV; see $TIMEOUT_DISCARD_FILE"
  exit "$STAGE_TIMEOUT_EXIT"
}

measure_stage() {
  local stage="$1"
  echo ""
  echo " Stage: $stage - $(date '+%H:%M:%S')"

  local timing_dir
  timing_dir=$(mktemp -d)

  local ini_pkg ini_cores ini_gpu ini_ram
  ini_pkg=$(read_rapl pkg)
  ini_cores=$(read_rapl cores)
  ini_gpu=$(read_rapl gpu)
  ini_ram=$(read_rapl ram)

  local stage_log="$LOGS_DIR/run_$(printf '%02d' "$RUN_NUM")_${stage}.log"
  local stage_exit=0
  local stage_timeout cname stage_start_utc
  case "$stage" in
    build) stage_timeout="$ENERGY_STAGE_TIMEOUT_BUILD_S" ;;
    *)     stage_timeout="$ENERGY_STAGE_TIMEOUT_TEST_S" ;;
  esac
  cname="puppeteer-run$(printf '%02d' "$RUN_NUM")-${stage}"
  # A residual container of the same name is exactly the case the ceiling exists for.
  docker rm -f "$cname" >/dev/null 2>&1 || true

  local volume_args=()
  if [ "$stage" = "build" ]; then
    BUILD_VOLUME="${cname}-workspace"
    docker volume rm -f "$BUILD_VOLUME" >/dev/null 2>&1 || true
    docker volume create "$BUILD_VOLUME" >/dev/null
    # Setup, outside the measured window: the volume is populated from the
    # image on first mount and the build output and wireit cache are removed.
    local setup_start setup_exit
    setup_start=$(date +%s.%N)
    set +e
    docker run --rm --name "${cname}-setup" --network none       -v "$BUILD_VOLUME:/workspace"       -v "$MEDICAO_DIR:/medicao:ro"       "$IMAGE_NAME" bash /medicao/commands.sh clean > "$LOGS_DIR/run_$(printf '%02d' "$RUN_NUM")_build_setup.log" 2>&1
    setup_exit=$?
    set -e
    echo "  build setup (clean on the run volume, outside the measured window): $(awk "BEGIN {printf \"%.1f\", $(date +%s.%N) - $setup_start}")s exit=$setup_exit"
    if [ "$setup_exit" -ne 0 ]; then
      echo "build setup failed (exit $setup_exit); see $LOGS_DIR/run_$(printf '%02d' "$RUN_NUM")_build_setup.log" >&2
      exit 1
    fi
    volume_args=(-v "$BUILD_VOLUME:/workspace")
  fi

  CURRENT_CONTAINER="$cname"
  stage_start_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  set +e
  # --network none: all inputs are pre-baked into the image; measured energy
  # must not include network traffic (construct definition).
  # fd3 preserves the workload stderr while `time` captures wall/user/sys inside
  # the container, so child CPU time is attributed to the stage.
  /usr/bin/time -f "%e" -o "$TIME_FILE" \
    timeout --foreground -s TERM -k 30 "$stage_timeout" \
    docker run --rm --name "$cname" --privileged --network none \
      --memory="$MEM_LIMIT" --memory-swap="$MEM_SWAP" \
      -v "$MEDICAO_DIR:/medicao:ro" \
      -v "$timing_dir:/timing" \
      "${volume_args[@]}" \
      -e "STAGE=$stage" \
      "$IMAGE_NAME" \
      bash -c 'exec 3>&2; TIMEFORMAT="%R %U %S"; { time bash /medicao/commands.sh "$STAGE" 2>&3; } 2>/timing/time.txt' \
      2>&1 | tee "$stage_log"
  stage_exit=${PIPESTATUS[0]}
  set -e
  echo "  stage log: $stage_log"

  local wall_now
  wall_now=$(tail -n 1 "$TIME_FILE" 2>/dev/null || echo 0)
  [[ "$wall_now" =~ ^[0-9]+(\.[0-9]+)?$ ]] || wall_now=0
  # 124: timeout sent TERM. 137 is also the workload's own SIGKILL exit, so it
  # only counts as the ceiling when the wall actually reached it.
  if [ "$stage_exit" -eq 124 ] || { [ "$stage_exit" -eq 137 ] && awk "BEGIN {exit !($wall_now >= $stage_timeout)}"; }; then
    rm -rf "$timing_dir"
    abort_stage_timeout "$stage" "$stage_timeout" "$stage_exit" "$cname" "$stage_start_utc" "$stage_log" "$wall_now"
  fi
  CURRENT_CONTAINER=""
  if [ -n "$BUILD_VOLUME" ]; then
    docker volume rm -f "$BUILD_VOLUME" >/dev/null 2>&1 || true
    BUILD_VOLUME=""
  fi

  # The exit code is the only rejection criterion; the measurement is kept
  # either way.
  echo "$RUN_NUM,$stage,$stage_exit" >> "$EXITS_FILE"
  if [ "$stage_exit" -ne 0 ]; then
    echo "  stage '$stage': container exited with exit=$stage_exit (measurement PRESERVED, see $EXITS_FILE)"
    PIPELINE_EXIT="$stage_exit"
    FAILED_STAGES="${FAILED_STAGES:+$FAILED_STAGES }$stage(exit=$stage_exit)"
    if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
      echo "::warning title=Stage exited non-zero::Run $RUN_NUM, stage '$stage': exit=$stage_exit. The CSV row WAS written."
    fi
  else
    echo "  stage '$stage': container exited 0"
  fi

  local fin_pkg fin_cores fin_gpu fin_ram
  fin_pkg=$(read_rapl pkg)
  fin_cores=$(read_rapl cores)
  fin_gpu=$(read_rapl gpu)
  fin_ram=$(read_rapl ram)

  local wall wall_container_t user_t sys_t
  # GNU time prepends a status line on non-zero exit; the elapsed value is last.
  wall=$(tail -n 1 "$TIME_FILE")
  if ! [[ "$wall" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    echo "  non-numeric wall_time ('$wall') - writing 0 and continuing" >&2
    wall="0.00"
  fi
  if [ -f "$timing_dir/time.txt" ]; then
    read -r wall_container_t user_t sys_t < "$timing_dir/time.txt"
  else
    wall_container_t="0.000"; user_t="0.000"; sys_t="0.000"
  fi
  rm -rf "$timing_dir"

  local d_pkg d_cores d_gpu d_ram
  d_pkg=$(delta_uj   "$ini_pkg"   "$fin_pkg"   "$max_pkg")
  d_cores=$(delta_uj "$ini_cores" "$fin_cores" "$max_cores")
  d_gpu=$(delta_uj   "$ini_gpu"   "$fin_gpu"   "$max_gpu")
  d_ram=$(delta_uj   "$ini_ram"   "$fin_ram"   "$max_ram")

  local j_pkg j_cores j_gpu j_ram j_ram_raw
  j_pkg=$(awk   "BEGIN {v=($d_pkg   - $taxa_pkg   * $wall) / 1e6; printf \"%.6f\", (v>0?v:0)}")
  j_cores=$(awk "BEGIN {v=($d_cores - $taxa_cores * $wall) / 1e6; printf \"%.6f\", (v>0?v:0)}")
  j_gpu=$(awk   "BEGIN {v=($d_gpu   - $taxa_gpu   * $wall) / 1e6; printf \"%.6f\", (v>0?v:0)}")
  j_ram=$(awk   "BEGIN {v=($d_ram   - $taxa_ram   * $wall) / 1e6; printf \"%.6f\", (v>0?v:0)}")

  j_ram_raw=$(awk "BEGIN {printf \"%.6f\", ($d_ram - $taxa_ram * $wall) / 1e6}")

  echo "  ram: delta=${d_ram}uJ baseline=$(awk "BEGIN {printf \"%.0f\", $taxa_ram * $wall}")uJ net=$(awk "BEGIN {printf \"%.3f\", ($d_ram - $taxa_ram * $wall) / 1e6}")J clamped=${j_ram}J"

  echo "$RUN_NUM,$stage,$j_pkg,$j_cores,$j_gpu,$j_ram,$wall,$user_t,$sys_t,$j_ram_raw,$wall_container_t,$taxa_pkg_w,$taxa_cores_w,$taxa_ram_w" >> "$CSV_FILE"

  total_pkg=$(awk   "BEGIN {printf \"%.6f\", $total_pkg   + $j_pkg}")
  total_cores=$(awk "BEGIN {printf \"%.6f\", $total_cores + $j_cores}")
  total_gpu=$(awk   "BEGIN {printf \"%.6f\", $total_gpu   + $j_gpu}")
  total_ram=$(awk   "BEGIN {printf \"%.6f\", $total_ram   + $j_ram}")
  total_ram_raw=$(awk "BEGIN {printf \"%.6f\", $total_ram_raw + $j_ram_raw}")
  total_wall=$(awk  "BEGIN {printf \"%.3f\", $total_wall  + $wall}")
  total_user=$(awk  "BEGIN {printf \"%.3f\", $total_user  + $user_t}")
  total_sys=$(awk   "BEGIN {printf \"%.3f\", $total_sys   + $sys_t}")
  total_wall_container=$(awk "BEGIN {printf \"%.3f\", $total_wall_container + $wall_container_t}")

  echo "    pkg: ${j_pkg}J | cores: ${j_cores}J | ram: ${j_ram}J | wall: ${wall}s"
}

measure_stage build
measure_stage test

echo "$RUN_NUM,total,$total_pkg,$total_cores,$total_gpu,$total_ram,$total_wall,$total_user,$total_sys,$total_ram_raw,$total_wall_container,$taxa_pkg_w,$taxa_cores_w,$taxa_ram_w" \
  >> "$CSV_FILE"

echo ""
echo ""
echo "Run $RUN_NUM finished - $(date '+%H:%M:%S')"
echo " CSV: $CSV_FILE"
echo " Total: pkg=${total_pkg}J | wall=${total_wall}s"
echo ""
echo ""

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  cat >> "$GITHUB_STEP_SUMMARY" <<EOF

## Run $RUN_NUM - $PROJECT_NAME

| Stage | pkg (J) | cores (J) | gpu (J) | ram (J) | wall (s) | exit |
|-------|---------|-----------|---------|---------|----------|------|
$(grep "^$RUN_NUM," "$CSV_FILE" | awk -F',' -v ex="$EXITS_FILE" 'BEGIN { while ((getline l < ex) > 0) { split(l, a, ","); e[a[2]] = a[3] } } {printf "| %s | %s | %s | %s | %s | %s | %s |\n", $2,$3,$4,$5,$6,$7,($2 in e ? e[$2] : "-")}')
EOF
fi

rm -f "$TIME_FILE"

if [ "$PIPELINE_EXIT" -ne 0 ]; then
  echo "Run $RUN_NUM: stage(s) with non-zero exit  $FAILED_STAGES"
  echo "  CSV: $CSV_FILE  exit codes: $EXITS_FILE"
  exit "$PIPELINE_EXIT"
fi
