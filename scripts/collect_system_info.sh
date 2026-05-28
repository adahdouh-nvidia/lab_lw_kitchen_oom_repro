#!/usr/bin/env bash
set -euo pipefail

# Collect reproducibility metadata for an OOM report.
# Usage:
#   bash collect_system_info.sh [output_dir]

OUT_DIR="${1:-oom_logs/system_info_$(date +%Y%m%d_%H%M%S)}"
mkdir -p "$OUT_DIR"

run_capture() {
  local name="$1"
  shift
  echo "==== $name ====" | tee "$OUT_DIR/${name}.txt"
  set +e
  "$@" 2>&1 | tee -a "$OUT_DIR/${name}.txt"
  local status=${PIPESTATUS[0]}
  set -e
  echo "exit_status=$status" | tee -a "$OUT_DIR/${name}.txt"
}

{
  echo "timestamp=$(date -Is)"
  echo "user=$(id -un 2>/dev/null || true)"
  echo "hostname=$(hostname 2>/dev/null || true)"
  echo "pwd=$(pwd)"
  echo "kernel=$(uname -a)"
  echo "shell=${SHELL:-}"
  echo "conda_env=${CONDA_DEFAULT_ENV:-}"
  echo "python=$(command -v python || true)"
} | tee "$OUT_DIR/basic.txt"

if command -v lsb_release >/dev/null 2>&1; then run_capture os_release lsb_release -a; fi
if [[ -f /etc/os-release ]]; then cp /etc/os-release "$OUT_DIR/os-release.txt"; fi
if command -v ldd >/dev/null 2>&1; then run_capture glibc ldd --version; fi
if command -v nvidia-smi >/dev/null 2>&1; then
  run_capture nvidia_smi nvidia-smi
  run_capture nvidia_query nvidia-smi --query-gpu=name,driver_version,cuda_version,memory.total,pci.bus_id --format=csv
else
  echo "nvidia-smi not found" | tee "$OUT_DIR/nvidia_smi.txt"
fi
run_capture free free -h
run_capture df df -h
run_capture ulimit bash -lc 'ulimit -a'
run_capture python_version python --version
run_capture pip_freeze python -m pip freeze
if command -v git >/dev/null 2>&1; then
  run_capture git_version git --version
  if git rev-parse --show-toplevel >/dev/null 2>&1; then
    run_capture git_status git status --short
    run_capture git_log git log -1 --oneline --decorate
    run_capture git_submodules git submodule status --recursive
  fi
fi

cat > "$OUT_DIR/README.txt" <<README
This directory contains machine and environment metadata useful for interpreting
LW-BenchHub / Isaac Lab memory results. Attach it with the run logs when filing
or updating the GitHub issue.
README

echo "System info written to $OUT_DIR"
