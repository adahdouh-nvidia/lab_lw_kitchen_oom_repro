#!/usr/bin/env bash
set -euo pipefail

# Clean Linux setup helper for the LW-BenchHub kitchen OOM repro kit.
#
# What this does:
#   1. Installs common Ubuntu packages needed by Isaac Sim / Isaac Lab / LW-BenchHub.
#   2. Installs Miniconda if conda is not already available.
#   3. Creates a Python 3.11 conda environment.
#   4. Clones LW-BenchHub, pulls Git LFS assets, and runs LW-BenchHub's install.sh.
#   5. Copies this repro kit into the LW-BenchHub checkout.
#   6. Writes an activation helper so the environment is ready to run tests.
#
# It does not install NVIDIA GPU drivers. Install a current NVIDIA driver first.

usage() {
  cat <<'USAGE'
Usage:
  ./setup_clean_linux.sh [--help]

Common environment variables:
  WORKDIR                 Install workspace. Default: $HOME/lw_kitchen_oom_work
  ENV_NAME                Conda env name. Default: lw_benchhub_oom
  CONDA_ROOT              Miniconda install dir if conda is missing. Default: $HOME/miniconda3
  LW_REPO_URL             Repo URL. Default: https://github.com/LightwheelAI/LW-BenchHub.git
  LW_REPO_REF             Git ref to checkout. Default: main
  SKIP_APT=1              Do not install apt packages.
  SKIP_NVIDIA_CHECK=1     Do not fail if nvidia-smi is unavailable.
  SKIP_GLIBC_CHECK=1      Do not fail if glibc looks too old.
  SKIP_LW_INSTALL=1       Clone/copy only; do not run LW-BenchHub install.sh.
  REINSTALL_ENV=1         Remove and recreate the conda environment.
  INSTALL_MINICONDA=0     Fail instead of installing Miniconda when conda is missing.

Example:
  WORKDIR=$HOME/lw_oom ENV_NAME=lw_benchhub_oom ./setup_clean_linux.sh

After completion:
  source $HOME/lw_kitchen_oom_work/activate_lw_kitchen_oom.sh
  bash $LW_OOM_REPRO_DIR/scripts/run_suggested_tests.sh
USAGE
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi

log() { printf '\n[setup] %s\n' "$*"; }
warn() { printf '\n[setup][WARN] %s\n' "$*" >&2; }
fail() { printf '\n[setup][ERROR] %s\n' "$*" >&2; exit 1; }

BUNDLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKDIR="${WORKDIR:-$HOME/lw_kitchen_oom_work}"
ENV_NAME="${ENV_NAME:-lw_benchhub_oom}"
CONDA_ROOT="${CONDA_ROOT:-$HOME/miniconda3}"
LW_REPO_URL="${LW_REPO_URL:-https://github.com/LightwheelAI/LW-BenchHub.git}"
LW_REPO_REF="${LW_REPO_REF:-main}"
SKIP_APT="${SKIP_APT:-0}"
SKIP_NVIDIA_CHECK="${SKIP_NVIDIA_CHECK:-0}"
SKIP_GLIBC_CHECK="${SKIP_GLIBC_CHECK:-0}"
SKIP_LW_INSTALL="${SKIP_LW_INSTALL:-0}"
REINSTALL_ENV="${REINSTALL_ENV:-0}"
INSTALL_MINICONDA="${INSTALL_MINICONDA:-auto}"
REPO_DIR="${REPO_DIR:-$WORKDIR/LW-BenchHub}"
REPRO_TARGET="${REPRO_TARGET:-$REPO_DIR/repro_kitchen_oom}"

if [[ ! -f "$BUNDLE_DIR/scripts/kitchen_oom_repro.py" ]]; then
  fail "Could not find scripts/kitchen_oom_repro.py next to setup_clean_linux.sh. Run this from the extracted zip."
fi

version_ge() {
  # Returns 0 if $1 >= $2 using sort -V.
  local have="$1"
  local need="$2"
  [[ "$(printf '%s\n%s\n' "$need" "$have" | sort -V | head -n1)" == "$need" ]]
}

check_glibc() {
  if [[ "$SKIP_GLIBC_CHECK" == "1" ]]; then
    warn "Skipping glibc check."
    return 0
  fi
  if ! command -v ldd >/dev/null 2>&1; then
    warn "ldd not found; cannot check glibc."
    return 0
  fi
  local line ver
  line="$(ldd --version 2>&1 | head -n1 || true)"
  ver="$(printf '%s\n' "$line" | grep -Eo '[0-9]+\.[0-9]+' | head -n1 || true)"
  if [[ -z "$ver" ]]; then
    warn "Could not parse glibc version from: $line"
    return 0
  fi
  log "Detected glibc $ver"
  if ! version_ge "$ver" "2.35"; then
    fail "Isaac Sim pip installs require glibc 2.35 or newer. Use Ubuntu 22.04+ or the Isaac Sim binary install path. Set SKIP_GLIBC_CHECK=1 only if you know this is safe."
  fi
}

check_nvidia() {
  if [[ "$SKIP_NVIDIA_CHECK" == "1" ]]; then
    warn "Skipping NVIDIA driver check."
    return 0
  fi
  if ! command -v nvidia-smi >/dev/null 2>&1; then
    fail "nvidia-smi was not found. Install a supported NVIDIA driver before running Isaac Sim. Set SKIP_NVIDIA_CHECK=1 to bypass this preflight only."
  fi
  log "NVIDIA driver info:"
  nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv || true
}

install_apt_deps() {
  if [[ "$SKIP_APT" == "1" ]]; then
    warn "Skipping apt dependency installation."
    return 0
  fi
  if ! command -v apt-get >/dev/null 2>&1; then
    warn "apt-get not found; skipping apt dependencies."
    return 0
  fi
  log "Installing Ubuntu packages. You may be prompted for sudo."
  sudo apt-get update
  sudo apt-get install -y \
    git git-lfs curl wget ca-certificates unzip jq \
    build-essential cmake ninja-build pkg-config \
    pciutils procps psmisc htop \
    libgl1 libglvnd0 libegl1 libx11-6 libxext6 libxrender1 libxrandr2 \
    libxinerama1 libxcursor1 libxi6 libsm6 libice6 libfontconfig1 \
    libxkbcommon-x11-0 libdbus-1-3 libxcb-cursor0 libglib2.0-0
  git lfs install
}

find_or_install_conda() {
  if command -v conda >/dev/null 2>&1; then
    local base
    base="$(conda info --base)"
    # shellcheck source=/dev/null
    source "$base/etc/profile.d/conda.sh"
    log "Using existing conda at $base"
    return 0
  fi

  if [[ "$INSTALL_MINICONDA" == "0" ]]; then
    fail "conda not found and INSTALL_MINICONDA=0. Install Miniconda/Conda first."
  fi

  log "Conda not found. Installing Miniconda into $CONDA_ROOT"
  mkdir -p "$(dirname "$CONDA_ROOT")"
  local installer tmp_arch
  tmp_arch="$(uname -m)"
  case "$tmp_arch" in
    x86_64|amd64) installer="Miniconda3-latest-Linux-x86_64.sh" ;;
    aarch64|arm64) installer="Miniconda3-latest-Linux-aarch64.sh" ;;
    *) fail "Unsupported architecture for automatic Miniconda install: $tmp_arch" ;;
  esac
  curl -fsSL "https://repo.anaconda.com/miniconda/$installer" -o /tmp/miniconda.sh
  bash /tmp/miniconda.sh -b -p "$CONDA_ROOT"
  rm -f /tmp/miniconda.sh
  # shellcheck source=/dev/null
  source "$CONDA_ROOT/etc/profile.d/conda.sh"
  conda config --set auto_activate_base false
}

create_env() {
  log "Creating/using conda env: $ENV_NAME"
  if conda env list | awk '{print $1}' | grep -qx "$ENV_NAME"; then
    if [[ "$REINSTALL_ENV" == "1" ]]; then
      conda env remove -n "$ENV_NAME" -y
      conda create -n "$ENV_NAME" python=3.11 -y
    fi
  else
    conda create -n "$ENV_NAME" python=3.11 -y
  fi
  conda activate "$ENV_NAME"
  python -m pip install --upgrade pip
}

clone_lw_benchhub() {
  mkdir -p "$WORKDIR"
  if [[ -d "$REPO_DIR/.git" ]]; then
    log "Using existing LW-BenchHub checkout at $REPO_DIR"
    cd "$REPO_DIR"
    git fetch --all --tags
  else
    log "Cloning LW-BenchHub into $REPO_DIR"
    git clone "$LW_REPO_URL" "$REPO_DIR"
    cd "$REPO_DIR"
  fi
  git checkout "$LW_REPO_REF"
  git submodule update --init --recursive || true
  git lfs install
  git lfs pull
}

install_lw_benchhub() {
  cd "$REPO_DIR"
  if [[ "$SKIP_LW_INSTALL" == "1" ]]; then
    warn "Skipping LW-BenchHub install.sh."
  else
    log "Running LW-BenchHub install.sh inside conda env $ENV_NAME"
    bash ./install.sh
  fi

  log "Installing analysis/reporting helpers into the same conda env"
  python -m pip install --upgrade pandas plotly matplotlib psutil
}

copy_repro_kit() {
  log "Copying repro kit into $REPRO_TARGET"
  mkdir -p "$REPRO_TARGET/scripts" "$REPRO_TARGET/analysis" "$REPRO_TARGET/docs"
  cp "$BUNDLE_DIR/README.md" "$REPRO_TARGET/README.md"
  cp "$BUNDLE_DIR/setup_clean_linux.sh" "$REPRO_TARGET/setup_clean_linux.sh"
  cp "$BUNDLE_DIR/requirements-analysis.txt" "$REPRO_TARGET/requirements-analysis.txt"
  cp "$BUNDLE_DIR/scripts/"* "$REPRO_TARGET/scripts/"
  cp "$BUNDLE_DIR/analysis/"* "$REPRO_TARGET/analysis/"
  if compgen -G "$BUNDLE_DIR/docs/*" >/dev/null; then
    cp "$BUNDLE_DIR/docs/"* "$REPRO_TARGET/docs/"
  fi
  chmod +x "$REPRO_TARGET/scripts/"*.sh "$REPRO_TARGET/scripts/"*.py "$REPRO_TARGET/setup_clean_linux.sh" || true
}

write_activation_helper() {
  local helper="$WORKDIR/activate_lw_kitchen_oom.sh"
  cat > "$helper" <<ACTIVATE
#!/usr/bin/env bash
# Source this file before running the OOM repro scripts.
# Example:
#   source "$helper"

set -euo pipefail
if [[ -f "$CONDA_ROOT/etc/profile.d/conda.sh" ]]; then
  source "$CONDA_ROOT/etc/profile.d/conda.sh"
elif command -v conda >/dev/null 2>&1; then
  source "\$(conda info --base)/etc/profile.d/conda.sh"
else
  echo "conda not found" >&2
  return 1 2>/dev/null || exit 1
fi
conda activate "$ENV_NAME"
export LW_BENCHHUB_REPO_DIR="$REPO_DIR"
export LW_OOM_REPRO_DIR="$REPRO_TARGET"
cd "$REPO_DIR"
echo "Activated conda env: $ENV_NAME"
echo "LW-BenchHub repo: $REPO_DIR"
echo "Repro kit: $REPRO_TARGET"
echo "Run suggested tests with: bash \$LW_OOM_REPRO_DIR/scripts/run_suggested_tests.sh"
ACTIVATE
  chmod +x "$helper"
  log "Activation helper written to $helper"
}

main() {
  log "Starting setup from bundle: $BUNDLE_DIR"
  check_glibc
  check_nvidia
  install_apt_deps
  find_or_install_conda
  create_env
  clone_lw_benchhub
  install_lw_benchhub
  copy_repro_kit
  write_activation_helper
  log "Setup complete."
  cat <<DONE

Next steps:
  source "$WORKDIR/activate_lw_kitchen_oom.sh"
  bash "\$LW_OOM_REPRO_DIR/scripts/collect_system_info.sh" "oom_logs/system_info"
  USE_SYSTEMD_SCOPE=1 MEMORY_MAX=120G MEMORY_SWAP_MAX=0 bash "\$LW_OOM_REPRO_DIR/scripts/run_suggested_tests.sh"

DONE
}

main "$@"
