#!/usr/bin/env bash
set -euo pipefail

# Simple sweep wrapper for kitchen_oom_repro.py.
# Run one num_envs value per fresh process. This avoids confusing the diagnosis
# with memory retained from a prior in-process create/destroy cycle.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPRO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_DIR="${LW_BENCHHUB_REPO_DIR:-$(cd "$REPRO_ROOT/.." && pwd)}"
cd "$REPO_DIR"

TASK_CONFIG="${TASK_CONFIG:-example}"
LAYOUT="${LAYOUT:-libero-1-1}"
TASK="${TASK:-}"
ROBOT="${ROBOT:-}"
SCENE_BACKEND="${SCENE_BACKEND:-}"
TASK_BACKEND="${TASK_BACKEND:-}"
DEVICE="${DEVICE:-cuda:0}"
CAMERA_RESOLUTION="${CAMERA_RESOLUTION:-}"
STEPS="${STEPS:-100}"
ENVS="${ENVS:-1 2 4 8 16 32 64 96 128 192 256}"
LOG_ROOT="${LOG_ROOT:-oom_logs}"
SCRIPT="${SCRIPT:-$SCRIPT_DIR/kitchen_oom_repro.py}"
PYTHON_BIN="${PYTHON_BIN:-python}"

# Set USE_SYSTEMD_SCOPE=1 to contain the OOM to the child process.
# Example: USE_SYSTEMD_SCOPE=1 MEMORY_MAX=120G MEMORY_SWAP_MAX=0 ./run_kitchen_oom_sweep.sh
USE_SYSTEMD_SCOPE="${USE_SYSTEMD_SCOPE:-0}"
MEMORY_MAX="${MEMORY_MAX:-120G}"
MEMORY_SWAP_MAX="${MEMORY_SWAP_MAX:-0}"
ABORT_RSS_GB="${ABORT_RSS_GB:-0}"
TRACE_ALLOCATORS="${TRACE_ALLOCATORS:-1}"
TRACE_MAX_CALLS="${TRACE_MAX_CALLS:-3}"
STOP_ON_FAILURE="${STOP_ON_FAILURE:-1}"

mkdir -p "$LOG_ROOT"

for N in $ENVS; do
  RUN_DIR="$LOG_ROOT/${LAYOUT}_${N}env_$(date +%Y%m%d_%H%M%S)"
  mkdir -p "$RUN_DIR"

  cmd=("$PYTHON_BIN" "$SCRIPT"
    --headless
    --enable_cameras
    --task_config "$TASK_CONFIG"
    --layout "$LAYOUT"
    --num_envs "$N"
    --steps "$STEPS"
    --device "$DEVICE"
    --log_dir "$RUN_DIR")

  if [[ -n "$TASK" ]]; then cmd+=(--task "$TASK"); fi
  if [[ -n "$ROBOT" ]]; then cmd+=(--robot "$ROBOT"); fi
  if [[ -n "$SCENE_BACKEND" ]]; then cmd+=(--scene_backend "$SCENE_BACKEND"); fi
  if [[ -n "$TASK_BACKEND" ]]; then cmd+=(--task_backend "$TASK_BACKEND"); fi
  if [[ -n "$CAMERA_RESOLUTION" ]]; then cmd+=(--camera_resolution "$CAMERA_RESOLUTION"); fi
  if [[ "$ABORT_RSS_GB" != "0" && "$ABORT_RSS_GB" != "0.0" ]]; then cmd+=(--abort_rss_gb "$ABORT_RSS_GB"); fi
  if [[ "$TRACE_ALLOCATORS" == "0" ]]; then
    cmd+=(--no_trace_isaaclab_allocators)
  else
    cmd+=(--trace_max_calls "$TRACE_MAX_CALLS")
  fi

  echo "==== Running num_envs=$N; logs=$RUN_DIR ====" | tee "$RUN_DIR/wrapper.log"
  printf 'command:' | tee -a "$RUN_DIR/wrapper.log"
  printf ' %q' "${cmd[@]}" | tee -a "$RUN_DIR/wrapper.log"
  printf '\n' | tee -a "$RUN_DIR/wrapper.log"

  set +e
  if [[ "$USE_SYSTEMD_SCOPE" == "1" ]]; then
    systemd-run --user --scope --wait --collect \
      -p "MemoryMax=$MEMORY_MAX" \
      -p "MemorySwapMax=$MEMORY_SWAP_MAX" \
      /usr/bin/env "${cmd[@]}" 2>&1 | tee "$RUN_DIR/stdout_stderr.log"
    status=${PIPESTATUS[0]}
  else
    "${cmd[@]}" 2>&1 | tee "$RUN_DIR/stdout_stderr.log"
    status=${PIPESTATUS[0]}
  fi
  set -e
  echo "exit_status=$status" | tee -a "$RUN_DIR/wrapper.log"

  if [[ "$status" != "0" ]]; then
    echo "Failure at num_envs=$N" | tee -a "$RUN_DIR/wrapper.log"
    if [[ "$STOP_ON_FAILURE" == "1" ]]; then
      exit "$status"
    fi
  fi
done
