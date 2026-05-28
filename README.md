# LW-BenchHub Kitchen OOM Repro Kit

This zip contains a no-eviction diagnostic package for the Isaac Lab / LW-BenchHub kitchen memory issue.

The goal is to reproduce the original problem directly: loading, rendering, resetting, and stepping real LW-BenchHub / LIBERO kitchen scenes at increasing `num_envs`, up to the reported 256-kitchen case. The Python repro does not call `clear_refs`, `madvise`, `mmap`, or any other manual memory eviction path.

## Package layout

```text
lw_kitchen_oom_repro/
  README.md
  setup_clean_linux.sh
  requirements-analysis.txt
  scripts/
    kitchen_oom_repro.py          # no-eviction Python repro harness
    run_kitchen_oom_sweep.sh      # simple env-count sweep wrapper
    run_suggested_tests.sh        # recommended diagnostic matrix
    collect_system_info.sh        # machine/env metadata collector
  analysis/
    build_interactive_report.py   # offline Plotly HTML report
    plot_memory_static.py         # PNG plots with matplotlib
```

## What the repro records

For each run, `kitchen_oom_repro.py` writes these files into its `--log_dir`:

```text
memory_checkpoints.csv      # one row per memory checkpoint
summary.json                # run config, exit reason, metadata
/events.jsonl               # structured checkpoints and warnings
smaps_rollup_*.txt          # /proc/self/smaps_rollup snapshots
stdout_stderr.log           # created by the bash wrappers
wrapper.log                 # command and exit status from the wrapper
```

The important checkpoints are:

```text
after AppLauncher
before parse_env_cfg
after parse_env_cfg
before gym.make
after gym.make
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

This lets you see whether the host-RAM jump happens during scene construction, environment cloning, camera/render warmup, reset/physics initialization, first render, or stepping.

## Requirements

Expected environment:

- Linux workstation or server with an NVIDIA GPU.
- Current NVIDIA driver. The setup script checks `nvidia-smi`, but it does not install GPU drivers.
- Ubuntu 22.04+ is recommended because Isaac Sim pip installs require glibc 2.35 or newer.
- Large disk space for Isaac Sim, Isaac Lab, LW-BenchHub, Git LFS assets, logs, and generated reports.
- For a 256-kitchen OOM reproduction, run under a memory limit so the process fails cleanly instead of destabilizing the host.

## Fresh install from a clean Linux machine

Unzip the package and run the setup helper:

```bash
unzip lw_kitchen_oom_repro_package.zip
cd lw_kitchen_oom_repro
chmod +x setup_clean_linux.sh scripts/*.sh scripts/*.py analysis/*.py
./setup_clean_linux.sh
```

By default, the installer:

1. Installs common Ubuntu packages with `apt-get`.
2. Installs Miniconda if `conda` is missing.
3. Creates a conda env named `lw_benchhub_oom` with Python 3.11.
4. Clones `LightwheelAI/LW-BenchHub` into `$HOME/lw_kitchen_oom_work/LW-BenchHub`.
5. Runs LW-BenchHub's own `install.sh`.
6. Installs the analysis dependencies: `pandas`, `plotly`, `matplotlib`, and `psutil`.
7. Copies this repro kit into the LW-BenchHub checkout as `repro_kitchen_oom`.
8. Writes an activation helper at `$HOME/lw_kitchen_oom_work/activate_lw_kitchen_oom.sh`.

Activate the environment after setup:

```bash
source $HOME/lw_kitchen_oom_work/activate_lw_kitchen_oom.sh
```

That command activates the conda env, changes directory into the LW-BenchHub repo, and sets:

```bash
LW_BENCHHUB_REPO_DIR
LW_OOM_REPRO_DIR
```

### Installer options

The setup script is controlled through environment variables:

```bash
WORKDIR=$HOME/lw_oom_test ./setup_clean_linux.sh
ENV_NAME=my_lw_env ./setup_clean_linux.sh
LW_REPO_REF=main ./setup_clean_linux.sh
SKIP_APT=1 ./setup_clean_linux.sh
SKIP_NVIDIA_CHECK=1 ./setup_clean_linux.sh
SKIP_GLIBC_CHECK=1 ./setup_clean_linux.sh
SKIP_LW_INSTALL=1 ./setup_clean_linux.sh
REINSTALL_ENV=1 ./setup_clean_linux.sh
INSTALL_MINICONDA=0 ./setup_clean_linux.sh
```

Use `SKIP_LW_INSTALL=1` only when LW-BenchHub and its dependencies are already installed in the active environment.

## Run the recommended diagnostic matrix

After setup:

```bash
source $HOME/lw_kitchen_oom_work/activate_lw_kitchen_oom.sh
USE_SYSTEMD_SCOPE=1 MEMORY_MAX=120G MEMORY_SWAP_MAX=0 \
  bash $LW_OOM_REPRO_DIR/scripts/run_suggested_tests.sh
```

This runs the main no-eviction checks:

1. Camera-enabled sweep over `num_envs`.
2. 256 environments with cameras disabled.
3. 256 environments with lower camera resolution.
4. 256 environments on the alternate LIBERO kitchen layout.
5. Optional cloning/fabric variant if explicitly enabled.
6. Automatic HTML and PNG analysis at the end.

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
- A run summary table with exit reason, exit status, peak RSS/HWM, GPU memory, and last checkpoint.

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

Attach this directory along with the logs. It includes driver, GPU, OS, glibc, Python package, and git metadata.

## How to interpret results

- Large jump at `after gym.make`: scene construction, USD loading, cloning, or asset duplication.
- Large jump at `after warmup_rendering` or `after first env.render`: cameras, render products, annotators, renderer caches, or image buffers.
- Large jump at `after env.reset`: physics initialization, contact structures, buffers, or simulator state.
- Large jump at `after first env.step`: runtime physics, contact generation, controller/action path, or lazy initialization.
- `Anonymous` / `Private_Dirty` dominates: heap allocations, renderer/physics CPU buffers, Python/Kit allocations.
- `Locked` grows: possible pinned host memory.
- GPU memory grows much less than RSS: not automatically a bug; the host may store USD scene graphs, CPU-side render/physics structures, allocator arenas, colliders, textures, and pinned buffers.
- Linear per-env growth: likely expected scaling or unsupported workload size.
- Superlinear growth or repeated load/reset/unload growth: stronger evidence of a bug or leak.

## Suggested GitHub wording

```markdown
I packaged a no-eviction repro for the original 256-kitchen OOM. It loads the actual LW-BenchHub kitchen config, scales `num_envs`, enables cameras, forces render/reset/step checkpoints, and records RSS, VmHWM, smaps_rollup, and nvidia-smi memory.

This is different from the eviction gist: it does not discard process memory. It should show whether the OOM happens during scene loading, cloning, reset/physics init, first render/camera setup, or stepping.

The useful outputs are:

- `memory_checkpoints.csv`
- `summary.json`
- `events.jsonl`
- `smaps_rollup_*.txt`
- `stdout_stderr.log`
- generated `analysis/oom_report.html`
```
