#!/usr/bin/env bash
set -euo pipefail

# Clean Linux setup helper for the LW-BenchHub kitchen OOM repro kit.
#
# Default target:
#   Isaac Sim source checkout: https://github.com/isaac-sim/IsaacSim.git @ develop
#   Isaac Lab source checkout: https://github.com/isaac-sim/IsaacLab.git @ develop
#   Isaac Lab _isaac_sim link: points at the Isaac Sim develop source build output
#   Python: 3.12 conda environment
#
# This script does not install NVIDIA GPU drivers. Install a current NVIDIA driver first.
# It also does not accept the NVIDIA Omniverse/Isaac Sim EULA on your behalf. The source
# build will prompt unless you set ISAACSIM_ACCEPT_EULA=1 after reviewing the terms.

usage() {
  cat <<'USAGE'
Usage:
  ./setup_clean_linux.sh [--help]

Common environment variables:
  WORKDIR                   Install workspace. Default: $HOME/lw_kitchen_oom_work
  ENV_NAME                  Conda env name. Default: lw_benchhub_oom_develop
  PYTHON_VERSION            Python version for conda env. Default: 3.12
  CONDA_ROOT                Miniconda install dir if conda is missing. Default: $HOME/miniconda3

Isaac Sim targeting:
  ISAACSIM_INSTALL_MODE     source, pip, external, or skip. Default: source
  ISAACSIM_REPO_URL         Default: https://github.com/isaac-sim/IsaacSim.git
  ISAACSIM_REPO_REF         Default: develop
  ISAACSIM_COMMIT           Optional exact commit to checkout after ISAACSIM_REPO_REF.
  ISAACSIM_DIR              Default: $WORKDIR/IsaacSim
  ISAACSIM_BUILD            Build source checkout after cloning. Default: 1
  ISAACSIM_BUILD_ARGS       Default: --config release
  ISAACSIM_ACCEPT_EULA=1    Pre-create .eula_accepted in the Isaac Sim checkout after you have reviewed/accepted the terms.
  ISAACSIM_PATH             External/built Isaac Sim root. For source mode this is computed as $ISAACSIM_DIR/_build/<platform>/release.
  ISAACSIM_VERSION          Pip mode only. Default: 6.0.0
  ISAACSIM_PIP_SPEC         Pip mode only. Default: isaacsim[all,extscache]==$ISAACSIM_VERSION

Isaac Lab targeting:
  ISAACLAB_REPO_URL         Default: https://github.com/isaac-sim/IsaacLab.git
  ISAACLAB_REPO_REF         Default: develop
  ISAACLAB_COMMIT           Optional exact commit to checkout after ISAACLAB_REPO_REF.
  ISAACLAB_DIR              Default: $WORKDIR/IsaacLab
  ISAACLAB_INSTALL_SELECTOR Default: all. Use core for a smaller Isaac Lab install.

LW-BenchHub targeting:
  LW_REPO_URL               Default: https://github.com/LightwheelAI/LW-BenchHub.git
  LW_REPO_REF               Git ref to checkout. Default: main
  REPO_DIR                  Default: $WORKDIR/LW-BenchHub
  RUN_LW_INSTALL_SH=1       Run LW-BenchHub's original install.sh. Default: 0.
                            Not recommended for this develop-source repro because it may install a different stack.
  SKIP_LW_INSTALL=1         Clone/copy only; do not install LW-BenchHub editable package.
  SKIP_ARENA_INSTALL=1      Do not install third_party/IsaacLab-Arena editable package.

Other controls:
  SKIP_APT=1                Do not install apt packages.
  FORCE_GCC11=0             Do not switch gcc/g++ alternatives to gcc-11/g++-11. Default: 1.
  SKIP_NVIDIA_CHECK=1       Do not fail if nvidia-smi is unavailable.
  SKIP_GLIBC_CHECK=1        Do not fail if glibc looks too old.
  SKIP_ISAACLAB_INSTALL=1   Clone Isaac Lab but do not run isaaclab.sh --install.
  INSTALL_PINOCCHIO=0       Do not conda-install pinocchio.
  INSTALL_TORCH=0           Do not explicitly install torch/torchvision.
  SKIP_VERIFY=1             Do not run lightweight Python import checks.
  VERIFY_SIM=1              Run a simulator smoke test after install.
  REINSTALL_ENV=1           Remove and recreate the conda environment.
  INSTALL_MINICONDA=0       Fail instead of installing Miniconda when conda is missing.

Default source-develop install:
  ISAACSIM_ACCEPT_EULA=1 ./setup_clean_linux.sh

Pinned compatible pair example, useful while both develop branches are moving:
  ISAACSIM_REPO_REF=develop \
  ISAACLAB_REPO_REF=develop \
  ISAACLAB_COMMIT=f0234a82e432e2a0b0f0a26ca3c5b59e527ddaaa \
  ISAACSIM_ACCEPT_EULA=1 \
  ./setup_clean_linux.sh

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
ENV_NAME="${ENV_NAME:-lw_benchhub_oom_develop}"
PYTHON_VERSION="${PYTHON_VERSION:-3.12}"
CONDA_ROOT="${CONDA_ROOT:-$HOME/miniconda3}"

ISAACSIM_INSTALL_MODE="${ISAACSIM_INSTALL_MODE:-source}"
ISAACSIM_REPO_URL="${ISAACSIM_REPO_URL:-https://github.com/isaac-sim/IsaacSim.git}"
ISAACSIM_REPO_REF="${ISAACSIM_REPO_REF:-develop}"
ISAACSIM_COMMIT="${ISAACSIM_COMMIT:-}"
ISAACSIM_DIR="${ISAACSIM_DIR:-$WORKDIR/IsaacSim}"
ISAACSIM_BUILD="${ISAACSIM_BUILD:-1}"
ISAACSIM_BUILD_ARGS="${ISAACSIM_BUILD_ARGS:---config release}"
ISAACSIM_ACCEPT_EULA="${ISAACSIM_ACCEPT_EULA:-0}"
ISAACSIM_VERSION="${ISAACSIM_VERSION:-6.0.0}"
ISAACSIM_PIP_SPEC="${ISAACSIM_PIP_SPEC:-isaacsim[all,extscache]==$ISAACSIM_VERSION}"
ISAACSIM_PATH="${ISAACSIM_PATH:-}"
ISAACSIM_PYTHON_EXE="${ISAACSIM_PYTHON_EXE:-}"
FORCE_GCC11="${FORCE_GCC11:-1}"

ISAACLAB_REPO_URL="${ISAACLAB_REPO_URL:-https://github.com/isaac-sim/IsaacLab.git}"
ISAACLAB_REPO_REF="${ISAACLAB_REPO_REF:-develop}"
ISAACLAB_COMMIT="${ISAACLAB_COMMIT:-}"
ISAACLAB_DIR="${ISAACLAB_DIR:-$WORKDIR/IsaacLab}"
ISAACLAB_INSTALL_SELECTOR="${ISAACLAB_INSTALL_SELECTOR:-all}"
SKIP_ISAACLAB_INSTALL="${SKIP_ISAACLAB_INSTALL:-0}"

LW_REPO_URL="${LW_REPO_URL:-https://github.com/LightwheelAI/LW-BenchHub.git}"
LW_REPO_REF="${LW_REPO_REF:-main}"
REPO_DIR="${REPO_DIR:-$WORKDIR/LW-BenchHub}"
REPRO_TARGET="${REPRO_TARGET:-$REPO_DIR/repro_kitchen_oom}"
RUN_LW_INSTALL_SH="${RUN_LW_INSTALL_SH:-0}"
SKIP_LW_INSTALL="${SKIP_LW_INSTALL:-0}"
SKIP_ARENA_INSTALL="${SKIP_ARENA_INSTALL:-0}"
INSTALL_PINOCCHIO="${INSTALL_PINOCCHIO:-1}"

SKIP_APT="${SKIP_APT:-0}"
SKIP_NVIDIA_CHECK="${SKIP_NVIDIA_CHECK:-0}"
SKIP_GLIBC_CHECK="${SKIP_GLIBC_CHECK:-0}"
SKIP_VERIFY="${SKIP_VERIFY:-0}"
VERIFY_SIM="${VERIFY_SIM:-0}"
REINSTALL_ENV="${REINSTALL_ENV:-0}"
INSTALL_MINICONDA="${INSTALL_MINICONDA:-auto}"
INSTALL_TORCH="${INSTALL_TORCH:-1}"
TORCH_VERSION="${TORCH_VERSION:-2.10.0}"
TORCHVISION_VERSION="${TORCHVISION_VERSION:-0.25.0}"

if [[ ! -f "$BUNDLE_DIR/scripts/kitchen_oom_repro.py" ]]; then
  fail "Could not find scripts/kitchen_oom_repro.py next to setup_clean_linux.sh. Run this from the extracted zip."
fi

version_ge() {
  local have="$1"
  local need="$2"
  [[ "$(printf '%s\n%s\n' "$need" "$have" | sort -V | head -n1)" == "$need" ]]
}

platform_token() {
  case "$(uname -m)" in
    x86_64|amd64) printf 'linux-x86_64' ;;
    aarch64|arm64) printf 'linux-aarch64' ;;
    *) fail "Unsupported architecture for Isaac Sim source build: $(uname -m)" ;;
  esac
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
  if [[ "$ISAACSIM_INSTALL_MODE" == "pip" ]] && ! version_ge "$ver" "2.35"; then
    fail "Isaac Sim pip installs require glibc 2.35 or newer. Use source/external mode or Ubuntu 22.04+."
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

  local packages=(
    git git-lfs curl wget ca-certificates unzip jq
    build-essential cmake ninja-build pkg-config gcc-11 g++-11
    pciutils procps psmisc htop
    libgl1 libgl1-mesa-dev libglvnd0 libegl1
    libx11-6 libx11-dev libxext6 libxrender1 libxrandr2 libxrandr-dev
    libxinerama1 libxinerama-dev libxcursor1 libxcursor-dev
    libxi6 libxi-dev libsm6 libice6 libfontconfig1
    libxkbcommon-x11-0 libdbus-1-3 libxcb-cursor0 libglib2.0-0
  )
  if apt-cache show python3.12-dev >/dev/null 2>&1; then
    packages+=(python3.12-dev)
  else
    warn "python3.12-dev is not available from apt on this distro; continuing because conda will provide Python $PYTHON_VERSION."
  fi
  sudo apt-get install -y "${packages[@]}"
  git lfs install

  if [[ "$FORCE_GCC11" == "1" ]] && command -v gcc-11 >/dev/null 2>&1 && command -v g++-11 >/dev/null 2>&1; then
    log "Configuring gcc/g++ alternatives to GCC 11 for Isaac Sim source build."
    sudo update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-11 200 || true
    sudo update-alternatives --install /usr/bin/g++ g++ /usr/bin/g++-11 200 || true
  fi
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
  log "Creating/using conda env: $ENV_NAME with Python $PYTHON_VERSION"
  if conda env list | awk '{print $1}' | grep -qx "$ENV_NAME"; then
    if [[ "$REINSTALL_ENV" == "1" ]]; then
      conda env remove -n "$ENV_NAME" -y
      conda create -n "$ENV_NAME" "python=$PYTHON_VERSION" -y
    fi
  else
    conda create -n "$ENV_NAME" "python=$PYTHON_VERSION" -y
  fi
  conda activate "$ENV_NAME"
  python -m pip install --upgrade pip uv
  python --version
}

install_pinocchio_if_requested() {
  if [[ "$INSTALL_PINOCCHIO" != "1" ]]; then
    warn "Skipping conda install pinocchio."
    return 0
  fi
  log "Installing pinocchio from conda-forge, matching LW-BenchHub's installer behavior."
  conda install pinocchio -c conda-forge -y
}

clone_isaacsim_source() {
  if [[ "$ISAACSIM_INSTALL_MODE" != "source" ]]; then
    return 0
  fi
  mkdir -p "$WORKDIR"
  if [[ -d "$ISAACSIM_DIR/.git" ]]; then
    log "Using existing Isaac Sim checkout at $ISAACSIM_DIR"
    cd "$ISAACSIM_DIR"
    git fetch --all --tags
  else
    log "Cloning Isaac Sim into $ISAACSIM_DIR"
    git clone "$ISAACSIM_REPO_URL" "$ISAACSIM_DIR"
    cd "$ISAACSIM_DIR"
    git fetch --all --tags
  fi

  git checkout "$ISAACSIM_REPO_REF"
  if [[ -n "$ISAACSIM_COMMIT" ]]; then
    git checkout "$ISAACSIM_COMMIT"
  fi
  git lfs install
  git lfs pull || true
  git submodule update --init --recursive || true
  log "Isaac Sim checkout: $(git rev-parse --short HEAD) ($(git rev-parse --abbrev-ref HEAD 2>/dev/null || true))"
}

build_isaacsim_source() {
  if [[ "$ISAACSIM_INSTALL_MODE" != "source" ]]; then
    return 0
  fi
  cd "$ISAACSIM_DIR"
  if [[ "$ISAACSIM_ACCEPT_EULA" == "1" ]]; then
    log "ISAACSIM_ACCEPT_EULA=1 set; creating .eula_accepted in Isaac Sim checkout."
    touch .eula_accepted
  else
    warn "Isaac Sim build may prompt for the NVIDIA Omniverse/Isaac Sim EULA. Set ISAACSIM_ACCEPT_EULA=1 only after reviewing and accepting the terms."
  fi

  if [[ "$ISAACSIM_BUILD" == "1" ]]; then
    log "Building Isaac Sim source checkout with: ./build.sh $ISAACSIM_BUILD_ARGS"
    # shellcheck disable=SC2086
    bash ./build.sh $ISAACSIM_BUILD_ARGS
  else
    warn "Skipping Isaac Sim build because ISAACSIM_BUILD=$ISAACSIM_BUILD. The expected build output must already exist."
  fi

  local platform
  platform="$(platform_token)"
  ISAACSIM_PATH="${ISAACSIM_PATH:-$ISAACSIM_DIR/_build/$platform/release}"
  ISAACSIM_PYTHON_EXE="${ISAACSIM_PYTHON_EXE:-$ISAACSIM_PATH/python.sh}"

  if [[ ! -d "$ISAACSIM_PATH" ]]; then
    fail "Isaac Sim build output not found: $ISAACSIM_PATH"
  fi
  if [[ ! -x "$ISAACSIM_PATH/isaac-sim.sh" ]]; then
    warn "Expected executable missing or not executable: $ISAACSIM_PATH/isaac-sim.sh"
  fi
  log "Isaac Sim source build path: $ISAACSIM_PATH"
}

clone_isaaclab() {
  mkdir -p "$WORKDIR"
  if [[ -d "$ISAACLAB_DIR/.git" ]]; then
    log "Using existing Isaac Lab checkout at $ISAACLAB_DIR"
    cd "$ISAACLAB_DIR"
    git fetch --all --tags
  else
    log "Cloning Isaac Lab into $ISAACLAB_DIR"
    git clone "$ISAACLAB_REPO_URL" "$ISAACLAB_DIR"
    cd "$ISAACLAB_DIR"
    git fetch --all --tags
  fi

  git checkout "$ISAACLAB_REPO_REF"
  if [[ -n "$ISAACLAB_COMMIT" ]]; then
    git checkout "$ISAACLAB_COMMIT"
  fi
  git submodule update --init --recursive || true
  log "Isaac Lab checkout: $(git rev-parse --short HEAD) ($(git rev-parse --abbrev-ref HEAD 2>/dev/null || true))"
}

install_isaacsim() {
  case "$ISAACSIM_INSTALL_MODE" in
    source)
      clone_isaacsim_source
      build_isaacsim_source
      ;;
    pip)
      log "Installing Isaac Sim pip package: $ISAACSIM_PIP_SPEC"
      uv pip install "$ISAACSIM_PIP_SPEC" \
        --extra-index-url https://pypi.nvidia.com \
        --index-strategy unsafe-best-match \
        --prerelease=allow
      ;;
    external)
      log "Using external Isaac Sim install."
      if [[ -z "$ISAACSIM_PATH" ]]; then
        fail "ISAACSIM_INSTALL_MODE=external requires ISAACSIM_PATH=/path/to/built/or/installed/IsaacSim"
      fi
      if [[ ! -d "$ISAACSIM_PATH" ]]; then
        fail "ISAACSIM_PATH was set but does not exist: $ISAACSIM_PATH"
      fi
      ISAACSIM_PYTHON_EXE="${ISAACSIM_PYTHON_EXE:-$ISAACSIM_PATH/python.sh}"
      ;;
    skip)
      warn "Skipping Isaac Sim installation. Assuming the active environment is already configured."
      ;;
    *)
      fail "Unknown ISAACSIM_INSTALL_MODE=$ISAACSIM_INSTALL_MODE. Use source, pip, external, or skip."
      ;;
  esac
}

link_isaacsim_into_isaaclab() {
  if [[ "$ISAACSIM_INSTALL_MODE" == "pip" || "$ISAACSIM_INSTALL_MODE" == "skip" ]]; then
    warn "No IsaacLab/_isaac_sim symlink is created for ISAACSIM_INSTALL_MODE=$ISAACSIM_INSTALL_MODE."
    return 0
  fi
  if [[ -z "$ISAACSIM_PATH" || ! -d "$ISAACSIM_PATH" ]]; then
    fail "Cannot link Isaac Sim into Isaac Lab; ISAACSIM_PATH is not a valid directory: ${ISAACSIM_PATH:-<empty>}"
  fi
  mkdir -p "$ISAACLAB_DIR"
  if [[ -L "$ISAACLAB_DIR/_isaac_sim" || -e "$ISAACLAB_DIR/_isaac_sim" ]]; then
    local current
    current="$(readlink -f "$ISAACLAB_DIR/_isaac_sim" 2>/dev/null || true)"
    if [[ "$current" == "$(readlink -f "$ISAACSIM_PATH")" ]]; then
      log "Isaac Lab _isaac_sim already points to $ISAACSIM_PATH"
    else
      warn "Replacing existing Isaac Lab _isaac_sim link/path: $ISAACLAB_DIR/_isaac_sim -> $current"
      rm -rf "$ISAACLAB_DIR/_isaac_sim"
      ln -s "$ISAACSIM_PATH" "$ISAACLAB_DIR/_isaac_sim"
    fi
  else
    ln -s "$ISAACSIM_PATH" "$ISAACLAB_DIR/_isaac_sim"
  fi
  export ISAACSIM_PATH
  export ISAACSIM_PYTHON_EXE
  log "Linked $ISAACLAB_DIR/_isaac_sim -> $ISAACSIM_PATH"
}

source_isaacsim_env_if_available() {
  local setup_file=""
  if [[ -n "$ISAACSIM_PATH" && -f "$ISAACSIM_PATH/setup_conda_env.sh" ]]; then
    setup_file="$ISAACSIM_PATH/setup_conda_env.sh"
  elif [[ -f "$ISAACLAB_DIR/_isaac_sim/setup_conda_env.sh" ]]; then
    setup_file="$ISAACLAB_DIR/_isaac_sim/setup_conda_env.sh"
  fi

  if [[ -n "$setup_file" ]]; then
    log "Sourcing Isaac Sim conda env setup: $setup_file"
    # shellcheck source=/dev/null
    source "$setup_file" >/dev/null 2>&1 || warn "Failed to source $setup_file; continuing."
  else
    warn "No Isaac Sim setup_conda_env.sh found. This is normal for pip mode, but source/external mode may need manual PYTHONPATH setup."
  fi
}

install_torch_if_requested() {
  if [[ "$INSTALL_TORCH" != "1" ]]; then
    warn "Skipping explicit torch/torchvision install."
    return 0
  fi
  local arch torch_index
  arch="$(uname -m)"
  case "$arch" in
    aarch64|arm64) torch_index="https://download.pytorch.org/whl/cu130" ;;
    *) torch_index="https://download.pytorch.org/whl/cu128" ;;
  esac
  log "Installing torch==$TORCH_VERSION torchvision==$TORCHVISION_VERSION from $torch_index"
  uv pip install -U "torch==$TORCH_VERSION" "torchvision==$TORCHVISION_VERSION" --index-url "$torch_index"
}

install_isaaclab_develop() {
  if [[ "$SKIP_ISAACLAB_INSTALL" == "1" ]]; then
    warn "Skipping Isaac Lab install."
    return 0
  fi
  cd "$ISAACLAB_DIR"
  log "Installing Isaac Lab from source checkout: $ISAACLAB_DIR"
  if [[ -n "$ISAACLAB_INSTALL_SELECTOR" ]]; then
    bash ./isaaclab.sh --install "$ISAACLAB_INSTALL_SELECTOR"
  else
    bash ./isaaclab.sh --install
  fi
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
  git lfs pull || true
}

install_lw_benchhub() {
  cd "$REPO_DIR"
  if [[ "$RUN_LW_INSTALL_SH" == "1" ]]; then
    warn "Running LW-BenchHub's original install.sh. This may replace or override the Isaac Sim/Lab develop-targeted stack."
    bash ./install.sh
  elif [[ "$SKIP_LW_INSTALL" == "1" ]]; then
    warn "Skipping LW-BenchHub editable install."
  else
    log "Installing LW-BenchHub without running its original install.sh."
    git submodule update --init --recursive || true
    if [[ "$SKIP_ARENA_INSTALL" != "1" && -d "$REPO_DIR/third_party/IsaacLab-Arena" ]]; then
      log "Installing IsaacLab-Arena editable package from LW-BenchHub submodule."
      cd "$REPO_DIR/third_party/IsaacLab-Arena"
      if [[ -f pyproject.toml || -f setup.py ]]; then
        uv pip install -e .
      else
        warn "third_party/IsaacLab-Arena has no pyproject.toml or setup.py; skipping editable install."
      fi
      cd "$REPO_DIR"
    fi
    log "Installing LW-BenchHub editable package."
    uv pip install -e .
  fi

  log "Installing analysis/reporting helpers into the same conda env."
  uv pip install --upgrade pandas plotly matplotlib psutil
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
export ISAACSIM_INSTALL_MODE="$ISAACSIM_INSTALL_MODE"
export ISAACSIM_REPO_URL="$ISAACSIM_REPO_URL"
export ISAACSIM_REPO_REF="$ISAACSIM_REPO_REF"
export ISAACSIM_COMMIT="$ISAACSIM_COMMIT"
export ISAACSIM_DIR="$ISAACSIM_DIR"
export ISAACSIM_PATH="$ISAACSIM_PATH"
export ISAACSIM_PYTHON_EXE="$ISAACSIM_PYTHON_EXE"
export ISAACLAB_DIR="$ISAACLAB_DIR"
export ISAACLAB_REPO_URL="$ISAACLAB_REPO_URL"
export ISAACLAB_REPO_REF="$ISAACLAB_REPO_REF"
export ISAACLAB_COMMIT="$ISAACLAB_COMMIT"
export LW_BENCHHUB_REPO_DIR="$REPO_DIR"
export LW_OOM_REPRO_DIR="$REPRO_TARGET"
if [[ -n "\${ISAACSIM_PATH:-}" && -f "\${ISAACSIM_PATH}/setup_conda_env.sh" ]]; then
  source "\${ISAACSIM_PATH}/setup_conda_env.sh" >/dev/null 2>&1 || true
elif [[ -f "$ISAACLAB_DIR/_isaac_sim/setup_conda_env.sh" ]]; then
  source "$ISAACLAB_DIR/_isaac_sim/setup_conda_env.sh" >/dev/null 2>&1 || true
fi
cd "$REPO_DIR"
echo "Activated conda env: $ENV_NAME"
echo "Isaac Sim mode: $ISAACSIM_INSTALL_MODE"
echo "Isaac Sim dir: $ISAACSIM_DIR"
echo "Isaac Sim path: $ISAACSIM_PATH"
echo "Isaac Lab dir: $ISAACLAB_DIR"
echo "LW-BenchHub repo: $REPO_DIR"
echo "Repro kit: $REPRO_TARGET"
echo "Run suggested tests with: bash \$LW_OOM_REPRO_DIR/scripts/run_suggested_tests.sh"
ACTIVATE
  chmod +x "$helper"
  log "Activation helper written to $helper"
}

verify_python_imports() {
  if [[ "$SKIP_VERIFY" == "1" ]]; then
    warn "Skipping lightweight import verification."
    return 0
  fi
  log "Running lightweight Python import verification."
  source_isaacsim_env_if_available
  python - <<'PY'
import importlib
import importlib.metadata as md
import os
import sys

print("python", sys.version)
print("ISAACSIM_PATH", os.environ.get("ISAACSIM_PATH"))
for name in ["isaaclab", "gymnasium", "lw_benchhub"]:
    try:
        mod = importlib.import_module(name)
        try:
            version = md.version(name.replace("_", "-"))
        except Exception:
            version = getattr(mod, "__version__", "unknown")
        print(f"import {name}: ok version={version} file={getattr(mod, '__file__', None)}")
    except Exception as exc:
        print(f"import {name}: FAILED {exc!r}")
        raise
try:
    import isaacsim  # noqa: F401
    print("import isaacsim: ok")
except Exception as exc:
    print(f"import isaacsim: warning {exc!r}")
PY
  if [[ "$VERIFY_SIM" == "1" ]]; then
    log "Running Isaac Lab simulator smoke test."
    cd "$ISAACLAB_DIR"
    bash ./isaaclab.sh -p scripts/tutorials/00_sim/create_empty.py --headless
  fi
}

main() {
  log "Starting setup from bundle: $BUNDLE_DIR"
  log "Target Isaac Sim ref: $ISAACSIM_REPO_REF${ISAACSIM_COMMIT:+ @ $ISAACSIM_COMMIT} via $ISAACSIM_INSTALL_MODE mode"
  log "Target Isaac Lab ref: $ISAACLAB_REPO_REF${ISAACLAB_COMMIT:+ @ $ISAACLAB_COMMIT}"
  check_glibc
  check_nvidia
  install_apt_deps
  find_or_install_conda
  create_env
  install_pinocchio_if_requested
  install_isaacsim
  clone_isaaclab
  link_isaacsim_into_isaaclab
  source_isaacsim_env_if_available
  install_torch_if_requested
  install_isaaclab_develop
  clone_lw_benchhub
  install_lw_benchhub
  copy_repro_kit
  verify_python_imports
  write_activation_helper
  log "Setup complete."
  cat <<DONE

Next steps:
  source "$WORKDIR/activate_lw_kitchen_oom.sh"
  bash "\$LW_OOM_REPRO_DIR/scripts/collect_system_info.sh" "oom_logs/system_info"
  bash "\$LW_OOM_REPRO_DIR/scripts/verify_develop_install.sh"
  USE_SYSTEMD_SCOPE=1 MEMORY_MAX=120G MEMORY_SWAP_MAX=0 bash "\$LW_OOM_REPRO_DIR/scripts/run_suggested_tests.sh"

DONE
}

main "$@"
