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

capture_git_dir() {
  local label="$1"
  local dir="$2"
  if [[ -d "$dir/.git" ]]; then
    run_capture "git_${label}_remote" git -C "$dir" remote -v
    run_capture "git_${label}_status" git -C "$dir" status --short --branch
    run_capture "git_${label}_log" git -C "$dir" log -1 --oneline --decorate
    run_capture "git_${label}_submodules" git -C "$dir" submodule status --recursive
  fi
}

{
  echo "timestamp=$(date -Is)"
  echo "user=$(id -un 2>/dev/null || true)"
  echo "hostname=$(hostname 2>/dev/null || true)"
  echo "pwd=$(pwd)"
  echo "kernel=$(uname -a)"
  echo "shell=${SHELL:-}"
  echo "conda_env=${CONDA_DEFAULT_ENV:-}"
  echo "conda_prefix=${CONDA_PREFIX:-}"
  echo "python=$(command -v python || true)"
  echo "ISAACSIM_INSTALL_MODE=${ISAACSIM_INSTALL_MODE:-}"
  echo "ISAACSIM_DIR=${ISAACSIM_DIR:-}"
  echo "ISAACSIM_REPO_REF=${ISAACSIM_REPO_REF:-}"
  echo "ISAACSIM_COMMIT=${ISAACSIM_COMMIT:-}"
  echo "ISAACSIM_PATH=${ISAACSIM_PATH:-}"
  echo "ISAACSIM_PYTHON_EXE=${ISAACSIM_PYTHON_EXE:-}"
  echo "ISAACLAB_DIR=${ISAACLAB_DIR:-}"
  echo "ISAACLAB_REPO_REF=${ISAACLAB_REPO_REF:-}"
  echo "ISAACLAB_COMMIT=${ISAACLAB_COMMIT:-}"
  echo "LW_BENCHHUB_REPO_DIR=${LW_BENCHHUB_REPO_DIR:-}"
  echo "LW_OOM_REPRO_DIR=${LW_OOM_REPRO_DIR:-}"
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
run_capture python_imports python - <<'PY'
import importlib
import importlib.metadata as md
import sys
print("python", sys.version)
for name in ["isaaclab", "isaacsim", "gymnasium", "lw_benchhub"]:
    try:
        mod = importlib.import_module(name)
        try:
            version = md.version(name.replace("_", "-"))
        except Exception:
            version = getattr(mod, "__version__", "unknown")
        print(f"{name}: version={version} file={getattr(mod, '__file__', None)}")
    except Exception as exc:
        print(f"{name}: import failed: {exc!r}")
PY
run_capture pip_freeze python -m pip freeze
if command -v uv >/dev/null 2>&1; then run_capture uv_version uv --version; fi
if command -v conda >/dev/null 2>&1; then run_capture conda_info conda info; fi
if command -v git >/dev/null 2>&1; then
  run_capture git_version git --version
  capture_git_dir "isaacsim" "${ISAACSIM_DIR:-}"
  capture_git_dir "isaaclab" "${ISAACLAB_DIR:-}"
  capture_git_dir "lw_benchhub" "${LW_BENCHHUB_REPO_DIR:-$(pwd)}"
  if git rev-parse --show-toplevel >/dev/null 2>&1; then
    capture_git_dir "cwd" "$(git rev-parse --show-toplevel)"
  fi
fi

cat > "$OUT_DIR/README.txt" <<README
This directory contains machine and environment metadata useful for interpreting
LW-BenchHub / Isaac Lab memory results. Attach it with the run logs when filing
or updating the GitHub issue.

Important files for branch targeting:
- git_isaacsim_log.txt
- git_isaacsim_status.txt
- git_isaaclab_log.txt
- git_isaaclab_status.txt
- python_imports.txt
- pip_freeze.txt
README

echo "System info written to $OUT_DIR"
