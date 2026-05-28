#!/usr/bin/env bash
set -euo pipefail

# Run the suggested no-eviction diagnostic matrix for the LW-BenchHub kitchen OOM issue.
#
# Run from the LW-BenchHub repo root after sourcing the activation helper:
#   source ~/lw_kitchen_oom_work/activate_lw_kitchen_oom.sh
#   USE_SYSTEMD_SCOPE=1 MEMORY_MAX=120G MEMORY_SWAP_MAX=0 bash $LW_OOM_REPRO_DIR/scripts/run_suggested_tests.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPRO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_DIR="${LW_BENCHHUB_REPO_DIR:-$(cd "$REPRO_ROOT/.." && pwd)}"
REPRO_SCRIPT="${REPRO_SCRIPT:-$SCRIPT_DIR/kitchen_oom_repro.py}"
PYTHON_BIN="${PYTHON_BIN:-python}"

TASK_CONFIG="${TASK_CONFIG:-example}"
LAYOUT="${LAYOUT:-libero-1-1}"
ALT_LAYOUT="${ALT_LAYOUT:-libero-8-8}"
TASK="${TASK:-}"
ROBOT="${ROBOT:-}"
SCENE_BACKEND="${SCENE_BACKEND:-}"
TASK_BACKEND="${TASK_BACKEND:-}"
DEVICE="${DEVICE:-cuda:0}"
STEPS="${STEPS:-100}"
ENVS="${ENVS:-1 2 4 8 16 32 64 96 128 192 256}"
FOCUS_ENVS="${FOCUS_ENVS:-256}"
LOWRES_CAMERA_RESOLUTION="${LOWRES_CAMERA_RESOLUTION:-320x240}"
LOG_ROOT="${LOG_ROOT:-$REPO_DIR/oom_logs/suggested_$(date +%Y%m%d_%H%M%S)}"

# Use systemd cgroups to keep OOMs contained to the child process.
USE_SYSTEMD_SCOPE="${USE_SYSTEMD_SCOPE:-0}"
MEMORY_MAX="${MEMORY_MAX:-120G}"
MEMORY_SWAP_MAX="${MEMORY_SWAP_MAX:-0}"

# Optional early abort inside the Python process, before the cgroup kill point.
ABORT_RSS_GB="${ABORT_RSS_GB:-0}"

# Scenario toggles. Defaults cover the key isolations without over-running many incompatible variants.
RUN_SYSTEM_INFO="${RUN_SYSTEM_INFO:-1}"
RUN_CAMERA_SWEEP="${RUN_CAMERA_SWEEP:-1}"
RUN_NO_CAMERA_FOCUS="${RUN_NO_CAMERA_FOCUS:-1}"
RUN_LOWRES_FOCUS="${RUN_LOWRES_FOCUS:-1}"
RUN_ALT_LAYOUT_FOCUS="${RUN_ALT_LAYOUT_FOCUS:-1}"
RUN_CLONING_VARIANTS="${RUN_CLONING_VARIANTS:-0}"
RUN_ANALYSIS="${RUN_ANALYSIS:-1}"
STOP_ON_FAILURE="${STOP_ON_FAILURE:-0}"

mkdir -p "$LOG_ROOT"
cd "$REPO_DIR"

printf 'Suggested test log root: %s\n' "$LOG_ROOT" | tee "$LOG_ROOT/suite.log"
printf 'Repo dir: %s\n' "$REPO_DIR" | tee -a "$LOG_ROOT/suite.log"
printf 'Task config: %s | layout: %s | steps: %s | envs: %s\n' "$TASK_CONFIG" "$LAYOUT" "$STEPS" "$ENVS" | tee -a "$LOG_ROOT/suite.log"

run_logged() {
  local run_dir="$1"
  shift
  mkdir -p "$run_dir"
  printf '\n==== %s ====\n' "$run_dir" | tee -a "$LOG_ROOT/suite.log" "$run_dir/wrapper.log"
  printf 'command:' | tee -a "$run_dir/wrapper.log"
  printf ' %q' "$@" | tee -a "$run_dir/wrapper.log"
  printf '\n' | tee -a "$run_dir/wrapper.log"

  set +e
  if [[ "$USE_SYSTEMD_SCOPE" == "1" ]]; then
    systemd-run --user --scope --wait --collect \
      -p "MemoryMax=$MEMORY_MAX" \
      -p "MemorySwapMax=$MEMORY_SWAP_MAX" \
      /usr/bin/env "$@" 2>&1 | tee "$run_dir/stdout_stderr.log"
    status=${PIPESTATUS[0]}
  else
    "$@" 2>&1 | tee "$run_dir/stdout_stderr.log"
    status=${PIPESTATUS[0]}
  fi
  set -e

  printf 'exit_status=%s\n' "$status" | tee -a "$LOG_ROOT/suite.log" "$run_dir/wrapper.log"
  if [[ "$status" != "0" && "$STOP_ON_FAILURE" == "1" ]]; then
    exit "$status"
  fi
  return 0
}

base_args() {
  local run_dir="$1"
  local num_envs="$2"
  local layout="$3"
  shift 3
  local cmd=("$PYTHON_BIN" "$REPRO_SCRIPT"
    --headless
    --task_config "$TASK_CONFIG"
    --layout "$layout"
    --num_envs "$num_envs"
    --steps "$STEPS"
    --device "$DEVICE"
    --log_dir "$run_dir")

  if [[ -n "$TASK" ]]; then cmd+=(--task "$TASK"); fi
  if [[ -n "$ROBOT" ]]; then cmd+=(--robot "$ROBOT"); fi
  if [[ -n "$SCENE_BACKEND" ]]; then cmd+=(--scene_backend "$SCENE_BACKEND"); fi
  if [[ -n "$TASK_BACKEND" ]]; then cmd+=(--task_backend "$TASK_BACKEND"); fi
  if [[ "$ABORT_RSS_GB" != "0" && "$ABORT_RSS_GB" != "0.0" ]]; then cmd+=(--abort_rss_gb "$ABORT_RSS_GB"); fi
  cmd+=("$@")
  printf '%s\0' "${cmd[@]}"
}

run_case() {
  local scenario="$1"
  local num_envs="$2"
  local layout="$3"
  local camera_mode="$4"
  local camera_res="$5"
  shift 5

  local safe_layout safe_scenario stamp run_dir
  safe_layout="${layout//[^A-Za-z0-9_.-]/_}"
  safe_scenario="${scenario//[^A-Za-z0-9_.-]/_}"
  stamp="$(date +%Y%m%d_%H%M%S)"
  run_dir="$LOG_ROOT/$safe_scenario/${safe_layout}_${num_envs}env_$stamp"

  local extra=(--metadata "scenario=$scenario" --metadata "suite_log_root=$LOG_ROOT")
  if [[ "$camera_mode" == "cameras" ]]; then
    extra+=(--enable_cameras)
    if [[ "$camera_res" != "-" ]]; then
      extra+=(--camera_resolution "$camera_res")
    fi
  else
    extra+=(--render_mode none)
  fi
  extra+=("$@")

  local -a cmd
  mapfile -d '' cmd < <(base_args "$run_dir" "$num_envs" "$layout" "${extra[@]}")
  run_logged "$run_dir" "${cmd[@]}"
}

if [[ "$RUN_SYSTEM_INFO" == "1" ]]; then
  bash "$SCRIPT_DIR/collect_system_info.sh" "$LOG_ROOT/system_info" || true
fi

if [[ "$RUN_CAMERA_SWEEP" == "1" ]]; then
  for n in $ENVS; do
    run_case "01_camera_sweep_default" "$n" "$LAYOUT" cameras -
  done
fi

if [[ "$RUN_NO_CAMERA_FOCUS" == "1" ]]; then
  for n in $FOCUS_ENVS; do
    run_case "02_no_cameras_focus" "$n" "$LAYOUT" no_cameras -
  done
fi

if [[ "$RUN_LOWRES_FOCUS" == "1" ]]; then
  for n in $FOCUS_ENVS; do
    run_case "03_lowres_cameras_focus" "$n" "$LAYOUT" cameras "$LOWRES_CAMERA_RESOLUTION"
  done
fi

if [[ "$RUN_ALT_LAYOUT_FOCUS" == "1" ]]; then
  for n in $FOCUS_ENVS; do
    run_case "04_alt_layout_cameras_focus" "$n" "$ALT_LAYOUT" cameras -
  done
fi

if [[ "$RUN_CLONING_VARIANTS" == "1" ]]; then
  for n in $FOCUS_ENVS; do
    run_case "05_replicate_clone_fabric_focus" "$n" "$LAYOUT" cameras - \
      --replicate_physics true --clone_in_fabric true --create_stage_in_memory true
  done
fi

if [[ "$RUN_ANALYSIS" == "1" ]]; then
  mkdir -p "$LOG_ROOT/analysis"
  "$PYTHON_BIN" "$REPRO_ROOT/analysis/build_interactive_report.py" "$LOG_ROOT" --output "$LOG_ROOT/analysis/oom_report.html" || true
  "$PYTHON_BIN" "$REPRO_ROOT/analysis/plot_memory_static.py" "$LOG_ROOT" --output-dir "$LOG_ROOT/analysis" || true
fi

printf '\nSuggested test suite finished. Logs: %s\n' "$LOG_ROOT" | tee -a "$LOG_ROOT/suite.log"
if [[ -f "$LOG_ROOT/analysis/oom_report.html" ]]; then
  printf 'Interactive report: %s\n' "$LOG_ROOT/analysis/oom_report.html" | tee -a "$LOG_ROOT/suite.log"
fi
