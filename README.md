# LW-BenchHub Kitchen OOM Repro Kit for Isaac Sim develop + Isaac Lab develop

This zip contains a no-eviction diagnostic package for the Isaac Lab / LW-BenchHub kitchen memory issue.

The goal is to reproduce the original problem directly: loading, rendering, resetting, and stepping real LW-BenchHub / LIBERO kitchen scenes at increasing `num_envs`, up to the reported 256-kitchen case. The Python repro does not call `clear_refs`, `madvise`, `mmap`, or any other manual memory eviction path.

This revision targets:

```text
Isaac Sim repo: https://github.com/isaac-sim/IsaacSim.git
Isaac Sim ref:  develop, built from source by default unless overridden
Isaac Lab repo: https://github.com/isaac-sim/IsaacLab.git
Isaac Lab ref:  develop, installed from source unless overridden
Python:         3.12 conda environment by default
Gym API:        gymnasium, not the old OpenAI Gym package
```

## Two traps this package tries to avoid

### 1. Treating eviction as a fix

The gist-style eviction experiment is a diagnostic/workaround, not a fix. It can show that some resident pages are cold over a measurement window, but that does not prove the pages are permanently unnecessary or safe to discard. The eviction approach also has sharp edges: it may need to carve around GPU-communication memory such as Vulkan/CUDA/PhysX regions, because evicting the wrong range can crash PhysX or corrupt the run.

This package is intentionally **no-eviction**. It does not call `clear_refs`, `madvise`, `mmap`, `MAP_FIXED`, heap-carving code, or any manual VMA replacement. The first job is to reproduce the actual kitchen OOM without changing the process memory map.

If someone adds eviction to a local fork of the kitchen repro, do not trust a `freed N GB` number by itself. Treat it as valid only if the post-eviction checks still pass: render, step, reset, another render, and longer stepping with contacts/cameras enabled. A short no-crash window is not enough evidence that the evicted pages were truly disposable.

### 2. Treating high RSS as the root cause

High RSS reproduces the symptom; it does not identify the cause. This revision adds observational trace checkpoints around the allocator-heavy Isaac Lab phases that are most useful to investigate after the symptom is reproduced:

```text
SimulationContext.reset
InteractiveScene.clone_environments
ManagerBasedRLEnv.step
```

The trace wrappers only add checkpoints. They do not evict memory or alter allocator state. In the report, look for the largest positive deltas around `TRACE after ...` rows before drawing conclusions.

## Important note about `gymnasium.make`

The checkpoint named `after gymnasium.make` is not a branch reference and does not mean the old `gym` package. The repro imports:

```python
import gymnasium as gym
```

and then calls:

```python
env = gym.make(task_name, cfg=env_cfg, render_mode=render_mode)
```

That is the Gymnasium environment factory used by Isaac Lab examples. The log label now says `gymnasium.make` to avoid ambiguity. A large jump at `after gymnasium.make` means the memory increase happened while the Isaac Lab environment was being constructed: scene construction, USD loading, cloning, or asset duplication.

## Package layout

```text
lw_kitchen_oom_repro/
  README.md
  setup_clean_linux.sh
  requirements-analysis.txt
  scripts/
    kitchen_oom_repro.py                   # no-eviction Python repro harness
    run_kitchen_oom_sweep.sh               # simple env-count sweep wrapper
    run_suggested_tests.sh                 # recommended diagnostic matrix
    collect_system_info.sh                 # machine/env metadata collector
    verify_develop_install.sh              # confirms active Isaac Sim + Isaac Lab checkout/import paths
    verify_isaaclab_develop_install.sh     # backwards-compatible wrapper around verify_develop_install.sh
  analysis/
    build_interactive_report.py            # offline Plotly HTML report
    plot_memory_static.py                  # PNG plots with matplotlib
```

## What the repro records

For each run, `kitchen_oom_repro.py` writes these files into its `--log_dir`:

```text
memory_checkpoints.csv      # one row per memory checkpoint
summary.json                # run config, exit reason, metadata
events.jsonl                # structured checkpoints and warnings
smaps_rollup_*.txt          # /proc/self/smaps_rollup snapshots
stdout_stderr.log           # created by the bash wrappers
wrapper.log                 # command and exit status from the wrapper
```

The important checkpoints are:

```text
after AppLauncher
before parse_env_cfg
after parse_env_cfg
before gymnasium.make
after gymnasium.make
TRACE before/after InteractiveScene.clone_environments #N, if symbol is available
TRACE before/after SimulationContext.reset #N, if symbol is available
TRACE before/after ManagerBasedRLEnv.step #N, if symbol is available
before warmup_rendering
after warmup_rendering
before env.reset
after env.reset
before first env.render
after first env.render
before first env.step
after first env.step
after step 10 / 50 / 100
completed or exception
```

This lets you see whether the host-RAM jump happens during scene construction, environment cloning, camera/render warmup, reset/physics initialization, first render, or stepping. When trace wrappers are installed, the report can separate broad checkpoints such as `gymnasium.make` from narrower Isaac Lab calls such as `InteractiveScene.clone_environments` and `SimulationContext.reset`.

Allocator tracing is enabled by default and can be tuned from the command line:

```bash
# default behavior: trace first three calls per target
python $LW_OOM_REPRO_DIR/scripts/kitchen_oom_repro.py ... --trace_max_calls 3

# disable observational tracing if monkeypatching gets in the way of debugging
python $LW_OOM_REPRO_DIR/scripts/kitchen_oom_repro.py ... --no_trace_isaaclab_allocators
```

The bash wrappers expose the same controls:

```bash
TRACE_ALLOCATORS=1 TRACE_MAX_CALLS=3 bash $LW_OOM_REPRO_DIR/scripts/run_suggested_tests.sh
TRACE_ALLOCATORS=0 bash $LW_OOM_REPRO_DIR/scripts/run_suggested_tests.sh
```

## Requirements

Expected environment:

- Linux workstation or server with an NVIDIA GPU.
- Current NVIDIA driver. The setup script checks `nvidia-smi`, but it does not install GPU drivers.
- Ubuntu 22.04+ for Isaac Sim source builds; Ubuntu 24.04 also works, but the setup forces GCC/G++ 11 for the Isaac Sim source build.
- Large disk space for Isaac Sim source checkout/build artifacts, Isaac Lab, LW-BenchHub, Git LFS assets, logs, and generated reports.
- For a 256-kitchen OOM reproduction, run under a memory limit so the process fails cleanly instead of destabilizing the host.

Both Isaac Sim `develop` and Isaac Lab `develop` are active development branches. The default setup now clones and builds `isaac-sim/IsaacSim@develop`, then clones and installs `isaac-sim/IsaacLab@develop` with `IsaacLab/_isaac_sim` linked to the Isaac Sim source build. If the moving branch tips are temporarily incompatible, set `ISAACSIM_COMMIT` and/or `ISAACLAB_COMMIT` to a known compatible pair.

## Fresh install from a clean Linux machine

Unzip the package and run the setup helper:

```bash
unzip lw_kitchen_oom_repro_package_simlab_develop_v2.zip
cd lw_kitchen_oom_repro
chmod +x setup_clean_linux.sh scripts/*.sh scripts/*.py analysis/*.py
ISAACSIM_ACCEPT_EULA=1 ./setup_clean_linux.sh
```

Only set `ISAACSIM_ACCEPT_EULA=1` after reviewing and accepting the NVIDIA Omniverse / Isaac Sim terms. Without it, the Isaac Sim source build will prompt interactively.

By default, the installer:

1. Installs common Ubuntu packages with `apt-get`, including Git LFS and GCC/G++ 11.
2. Installs Miniconda if `conda` is missing.
3. Creates a conda env named `lw_benchhub_oom_develop` with Python 3.12.
4. Installs `uv` into that env.
5. Installs `pinocchio` from conda-forge, matching LW-BenchHub's installer behavior.
6. Clones `isaac-sim/IsaacSim` into `$HOME/lw_kitchen_oom_work/IsaacSim`.
7. Checks out `IsaacSim@develop`, unless overridden.
8. Builds Isaac Sim from source with `./build.sh --config release`.
9. Clones `isaac-sim/IsaacLab` into `$HOME/lw_kitchen_oom_work/IsaacLab`.
10. Checks out `IsaacLab@develop`, unless overridden.
11. Links `IsaacLab/_isaac_sim` to the Isaac Sim source build output.
12. Sources Isaac Sim's `setup_conda_env.sh` when available.
13. Runs `bash ./isaaclab.sh --install all` from the Isaac Lab checkout.
14. Clones `LightwheelAI/LW-BenchHub` into `$HOME/lw_kitchen_oom_work/LW-BenchHub`.
15. Installs LW-BenchHub and its `third_party/IsaacLab-Arena` submodule as editable packages without running LW-BenchHub's original `install.sh`.
16. Installs analysis dependencies: `pandas`, `plotly`, `matplotlib`, and `psutil`.
17. Copies this repro kit into the LW-BenchHub checkout as `repro_kitchen_oom`.
18. Runs lightweight Python import checks.
19. Writes an activation helper at `$HOME/lw_kitchen_oom_work/activate_lw_kitchen_oom.sh`.

Activate the environment after setup:

```bash
source $HOME/lw_kitchen_oom_work/activate_lw_kitchen_oom.sh
```

That command activates the conda env, changes directory into the LW-BenchHub repo, and sets:

```bash
ISAACSIM_INSTALL_MODE
ISAACSIM_DIR
ISAACSIM_REPO_REF
ISAACSIM_COMMIT
ISAACSIM_PATH
ISAACSIM_PYTHON_EXE
ISAACLAB_DIR
ISAACLAB_REPO_REF
ISAACLAB_COMMIT
LW_BENCHHUB_REPO_DIR
LW_OOM_REPRO_DIR
```

Confirm the active Isaac Sim and Isaac Lab checkout/import paths:

```bash
bash $LW_OOM_REPRO_DIR/scripts/verify_develop_install.sh
```

## Installer options

The setup script is controlled through environment variables.

Basic examples:

```bash
WORKDIR=$HOME/lw_oom_test ./setup_clean_linux.sh
ENV_NAME=my_lw_env ./setup_clean_linux.sh
REINSTALL_ENV=1 ./setup_clean_linux.sh
SKIP_APT=1 ./setup_clean_linux.sh
SKIP_NVIDIA_CHECK=1 ./setup_clean_linux.sh
SKIP_GLIBC_CHECK=1 ./setup_clean_linux.sh
INSTALL_MINICONDA=0 ./setup_clean_linux.sh
```

Isaac Sim and Isaac Lab branch/commit targeting:

```bash
# Default behavior: Isaac Sim develop source build + Isaac Lab develop source install
ISAACSIM_ACCEPT_EULA=1 ./setup_clean_linux.sh

# Explicit develop refs
ISAACSIM_REPO_REF=develop \
ISAACLAB_REPO_REF=develop \
ISAACSIM_ACCEPT_EULA=1 \
./setup_clean_linux.sh

# Pin to exact commits if tip-of-develop is broken or incompatible
ISAACSIM_REPO_REF=develop \
ISAACSIM_COMMIT=<isaac-sim-develop-commit> \
ISAACLAB_REPO_REF=develop \
ISAACLAB_COMMIT=<isaac-lab-develop-commit> \
ISAACSIM_ACCEPT_EULA=1 \
./setup_clean_linux.sh

# Use an Isaac Lab beta tag instead of branch tip, while still using Isaac Sim source mode
ISAACLAB_REPO_REF=v3.0.0-beta ISAACSIM_ACCEPT_EULA=1 ./setup_clean_linux.sh
```

Isaac Sim install controls:

```bash
# Default: clone and build isaac-sim/IsaacSim@develop from source
ISAACSIM_INSTALL_MODE=source ISAACSIM_REPO_REF=develop ISAACSIM_ACCEPT_EULA=1 ./setup_clean_linux.sh

# Use an already-built Isaac Sim source tree or external install
ISAACSIM_INSTALL_MODE=external ISAACSIM_PATH=/path/to/IsaacSim/_build/linux-x86_64/release ./setup_clean_linux.sh

# Fallback only: install the released Isaac Sim pip package instead of source develop.
# This does NOT target IsaacSim@develop.
ISAACSIM_INSTALL_MODE=pip ISAACSIM_VERSION=6.0.0 ./setup_clean_linux.sh

# Skip Isaac Sim install entirely if the active environment is already configured
ISAACSIM_INSTALL_MODE=skip ./setup_clean_linux.sh
```

Isaac Lab install size:

```bash
# Default: full install selector
ISAACLAB_INSTALL_SELECTOR=all ./setup_clean_linux.sh

# Smaller install selector; may not include all optional extras
ISAACLAB_INSTALL_SELECTOR=core ./setup_clean_linux.sh
```

LW-BenchHub install behavior:

```bash
# Default: do not run LW-BenchHub's original install.sh
./setup_clean_linux.sh

# Only use this if you intentionally want LW-BenchHub's original installer.
# It may install a different Isaac Lab / Isaac Sim stack and defeat the develop-source targeting.
RUN_LW_INSTALL_SH=1 ./setup_clean_linux.sh

# Clone/copy only, useful if dependencies are already installed
SKIP_LW_INSTALL=1 ./setup_clean_linux.sh

# Skip the IsaacLab-Arena editable install
SKIP_ARENA_INSTALL=1 ./setup_clean_linux.sh
```

## Run the recommended diagnostic matrix

After setup:

```bash
source $HOME/lw_kitchen_oom_work/activate_lw_kitchen_oom.sh
USE_SYSTEMD_SCOPE=1 MEMORY_MAX=120G MEMORY_SWAP_MAX=0 \
  bash $LW_OOM_REPRO_DIR/scripts/run_suggested_tests.sh
```

This runs the main no-eviction checks:

1. Verifies the active Isaac Sim and Isaac Lab checkout/import paths.
2. Collects system metadata.
3. Camera-enabled sweep over `num_envs`.
4. 256 environments with cameras disabled.
5. 256 environments with lower camera resolution.
6. 256 environments on the alternate LIBERO kitchen layout.
7. Optional cloning/fabric variant if explicitly enabled.
8. Automatic HTML and PNG analysis at the end.

Default sweep:

```bash
ENVS="1 2 4 8 16 32 64 96 128 192 256"
FOCUS_ENVS="256"
LAYOUT="libero-1-1"
ALT_LAYOUT="libero-8-8"
STEPS="100"
```

Useful overrides:

```bash
# Short smoke test
ENVS="1 2" FOCUS_ENVS="2" STEPS=5 bash $LW_OOM_REPRO_DIR/scripts/run_suggested_tests.sh

# Full suggested suite with cgroup protection
USE_SYSTEMD_SCOPE=1 MEMORY_MAX=120G MEMORY_SWAP_MAX=0 \
ENVS="1 2 4 8 16 32 64 96 128 192 256" \
FOCUS_ENVS="256" \
STOP_ON_FAILURE=0 \
bash $LW_OOM_REPRO_DIR/scripts/run_suggested_tests.sh

# Abort inside the Python process before the cgroup kill point
ABORT_RSS_GB=118 USE_SYSTEMD_SCOPE=1 MEMORY_MAX=120G MEMORY_SWAP_MAX=0 \
bash $LW_OOM_REPRO_DIR/scripts/run_suggested_tests.sh

# Also test optimized cloning/fabric flags where compatible
RUN_CLONING_VARIANTS=1 USE_SYSTEMD_SCOPE=1 MEMORY_MAX=120G MEMORY_SWAP_MAX=0 \
bash $LW_OOM_REPRO_DIR/scripts/run_suggested_tests.sh
```

The log root is printed at the start and end. You can also set it manually:

```bash
LOG_ROOT=$PWD/oom_logs/manual_run_001 bash $LW_OOM_REPRO_DIR/scripts/run_suggested_tests.sh
```

## Run scripts individually

### Single 256-kitchen run with cameras

```bash
source $HOME/lw_kitchen_oom_work/activate_lw_kitchen_oom.sh
python $LW_OOM_REPRO_DIR/scripts/kitchen_oom_repro.py \
  --headless \
  --enable_cameras \
  --task_config example \
  --layout libero-1-1 \
  --num_envs 256 \
  --steps 100 \
  --log_dir oom_logs/libero_1_1_256
```

### Single 256-kitchen run without cameras

```bash
python $LW_OOM_REPRO_DIR/scripts/kitchen_oom_repro.py \
  --headless \
  --task_config example \
  --layout libero-1-1 \
  --num_envs 256 \
  --steps 100 \
  --render_mode none \
  --log_dir oom_logs/libero_1_1_256_no_cameras
```

### Lower camera resolution

```bash
python $LW_OOM_REPRO_DIR/scripts/kitchen_oom_repro.py \
  --headless \
  --enable_cameras \
  --task_config example \
  --layout libero-1-1 \
  --num_envs 256 \
  --camera_resolution 320x240 \
  --steps 100 \
  --log_dir oom_logs/libero_1_1_256_320x240
```

### Alternate kitchen layout

```bash
python $LW_OOM_REPRO_DIR/scripts/kitchen_oom_repro.py \
  --headless \
  --enable_cameras \
  --task_config example \
  --layout libero-8-8 \
  --num_envs 256 \
  --steps 100 \
  --log_dir oom_logs/libero_8_8_256
```

### Simple env-count sweep

```bash
ENVS="1 2 4 8 16 32 64 96 128 192 256" \
TASK_CONFIG=example \
LAYOUT=libero-1-1 \
STEPS=100 \
SCRIPT=$LW_OOM_REPRO_DIR/scripts/kitchen_oom_repro.py \
bash $LW_OOM_REPRO_DIR/scripts/run_kitchen_oom_sweep.sh
```

With cgroup memory protection:

```bash
USE_SYSTEMD_SCOPE=1 MEMORY_MAX=120G MEMORY_SWAP_MAX=0 \
ENVS="1 2 4 8 16 32 64 96 128 192 256" \
SCRIPT=$LW_OOM_REPRO_DIR/scripts/kitchen_oom_repro.py \
bash $LW_OOM_REPRO_DIR/scripts/run_kitchen_oom_sweep.sh
```

## Generate reports and plots

The suggested test runner automatically generates analysis if `RUN_ANALYSIS=1`, which is the default.

To generate the interactive HTML report manually:

```bash
python $LW_OOM_REPRO_DIR/analysis/build_interactive_report.py \
  oom_logs/suggested_YYYYMMDD_HHMMSS \
  --output oom_logs/suggested_YYYYMMDD_HHMMSS/analysis/oom_report.html
```

To generate static PNGs manually:

```bash
python $LW_OOM_REPRO_DIR/analysis/plot_memory_static.py \
  oom_logs/suggested_YYYYMMDD_HHMMSS \
  --output-dir oom_logs/suggested_YYYYMMDD_HHMMSS/analysis
```

The HTML report is self-contained and can be opened locally in a browser. It includes:

- RSS over time by run.
- Peak host memory versus `num_envs`.
- Peak process GPU memory versus `num_envs`.
- Memory-component plots from `smaps_rollup`.
- A largest-checkpoint-delta table and `checkpoint_deltas.csv`, which are the first place to look for likely cause localization.
- A run summary table with exit reason, exit status, peak RSS/HWM, GPU memory, and last checkpoint.

The static plot helper also writes `largest_rss_deltas.png` and `static_checkpoint_deltas.csv`.

## Suggested manual testing steps

Use these steps if you want to build a clean GitHub comment or maintainer-facing diagnosis.

### 1. Confirm the real no-eviction workload

Run the real kitchen scene with cameras enabled and no memory eviction:

```bash
python $LW_OOM_REPRO_DIR/scripts/kitchen_oom_repro.py \
  --headless --enable_cameras \
  --task_config example \
  --layout libero-1-1 \
  --num_envs 256 \
  --steps 100 \
  --log_dir oom_logs/real_kitchen_256
```

Attach `memory_checkpoints.csv`, `summary.json`, `stdout_stderr.log`, and the latest `smaps_rollup_*.txt` files.

### 2. Produce a scaling table

Run:

```bash
ENVS="1 2 4 8 16 32 64 96 128 192 256" \
USE_SYSTEMD_SCOPE=1 MEMORY_MAX=120G MEMORY_SWAP_MAX=0 \
SCRIPT=$LW_OOM_REPRO_DIR/scripts/kitchen_oom_repro.py \
bash $LW_OOM_REPRO_DIR/scripts/run_kitchen_oom_sweep.sh
```

Then generate the HTML report. The key question is whether memory grows roughly linearly with `num_envs`, jumps at a specific checkpoint, or grows superlinearly.

### 3. Isolate cameras and rendering

Compare:

```bash
# With cameras
python $LW_OOM_REPRO_DIR/scripts/kitchen_oom_repro.py --headless --enable_cameras \
  --task_config example --layout libero-1-1 --num_envs 256 --steps 100 \
  --log_dir oom_logs/cameras_on_256

# Without cameras
python $LW_OOM_REPRO_DIR/scripts/kitchen_oom_repro.py --headless \
  --task_config example --layout libero-1-1 --num_envs 256 --steps 100 \
  --render_mode none --log_dir oom_logs/cameras_off_256

# Lower resolution
python $LW_OOM_REPRO_DIR/scripts/kitchen_oom_repro.py --headless --enable_cameras \
  --task_config example --layout libero-1-1 --num_envs 256 --steps 100 \
  --camera_resolution 320x240 --log_dir oom_logs/cameras_320x240_256
```

A jump after `warmup_rendering` or `first env.render` points to the camera/render path.

### 4. Isolate scene layout

Compare `libero-1-1` and `libero-8-8`:

```bash
LAYOUT=libero-1-1 FOCUS_ENVS=256 RUN_CAMERA_SWEEP=0 bash $LW_OOM_REPRO_DIR/scripts/run_suggested_tests.sh
LAYOUT=libero-8-8 FOCUS_ENVS=256 RUN_CAMERA_SWEEP=0 bash $LW_OOM_REPRO_DIR/scripts/run_suggested_tests.sh
```

If one layout is much heavier, inspect the generated stage stats in `events.jsonl`.

### 5. Try optimized cloning/fabric flags where compatible

```bash
python $LW_OOM_REPRO_DIR/scripts/kitchen_oom_repro.py \
  --headless --enable_cameras \
  --task_config example \
  --layout libero-1-1 \
  --num_envs 256 \
  --replicate_physics true \
  --clone_in_fabric true \
  --create_stage_in_memory true \
  --steps 100 \
  --log_dir oom_logs/optimized_clone_256
```

If this changes behavior, report both the memory change and whether the scene remains correct.

### 6. Compare PhysX buffer configurations

This harness does not change PhysX `gpu_*` buffers directly. To test that axis, edit the LW-BenchHub / Isaac Lab task config or environment config that sets those buffers, then rerun the same command and attach the resulting `summary.json` plus `memory_checkpoints.csv`.

Useful variants:

```text
A. Default PhysX buffers
B. Current custom PhysX buffers
C. Smallest custom buffers that avoid PhysX overflow warnings/errors
```

A large change in `Private_Dirty`, `Anonymous`, or `Locked` memory between these runs suggests intentional CPU-side or pinned host buffer allocation rather than a leak.

### 7. Attach system metadata

```bash
bash $LW_OOM_REPRO_DIR/scripts/collect_system_info.sh oom_logs/system_info
```

Attach this directory along with the logs. It includes driver, GPU, OS, glibc, Python package, Isaac Lab git branch/commit, LW-BenchHub git branch/commit, and import-path metadata.

## How to interpret results

Start with `analysis/checkpoint_deltas.csv` or the "Largest checkpoint RSS deltas" section in `analysis/oom_report.html`. The biggest positive deltas show where to aim next; they do not automatically prove a leak.

- Large jump at `TRACE after InteractiveScene.clone_environments`: environment cloning, USD duplication, asset/reference behavior, physics replication, or scenegraph instancing.
- Large jump at `TRACE after SimulationContext.reset`: physics initialization, PhysX buffers, collider/contact structures, simulator state, or render/physics synchronization.
- Large jump at `TRACE after ManagerBasedRLEnv.step`: first warm step, contact generation, lazy runtime buffers, controller/action path, or observation generation.
- Large jump at `after gymnasium.make`: scene construction, USD loading, cloning, or asset duplication. Use trace rows, if present, to split this broad phase into narrower causes.
- Large jump at `after warmup_rendering` or `after first env.render`: cameras, render products, annotators, renderer caches, or image buffers.
- Large jump at `after env.reset`: physics initialization, contact structures, buffers, or simulator state.
- Large jump at `after first env.step`: runtime physics, contact generation, controller/action path, or lazy initialization.
- `Anonymous` / `Private_Dirty` dominates: heap allocations, renderer/physics CPU buffers, Python/Kit allocations.
- `Locked` grows: possible pinned host memory.
- GPU memory grows much less than RSS: not automatically a bug; the host may store USD scene graphs, CPU-side render/physics structures, allocator arenas, colliders, textures, and pinned buffers.
- Linear per-env growth: likely expected scaling or unsupported workload size.
- Superlinear growth or repeated load/reset/unload growth: stronger evidence of a bug or leak.
