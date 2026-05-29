#!/usr/bin/env python3
"""
No-eviction LW-BenchHub / Isaac Lab kitchen OOM reproducer.

Goal:
  Reproduce the original claim: loading + rendering many real LW-BenchHub
  kitchen environments exhausts host RAM. This script does not clear refs,
  madvise, mmap over process memory, or evict any pages.

Run one num_envs value per process. Use the companion shell script for a sweep.

Example:
  python kitchen_oom_repro.py \
    --headless --enable_cameras \
    --task_config example \
    --layout libero-1-1 \
    --num_envs 256 \
    --steps 100 \
    --log_dir oom_logs/libero_1_1_256

Safer OOM repro:
  Run this under a cgroup/systemd memory limit so the process is killed instead
  of the whole workstation becoming unusable, e.g. MemoryMax=120G.
"""

from __future__ import annotations

import argparse
import csv
import functools
import importlib
import inspect
import json
import os
import pathlib
import random
import re
import subprocess
import sys
import time
import traceback
from types import SimpleNamespace
from typing import Any

# LW-BenchHub follows the Isaac Lab pattern: import AppLauncher first, parse args,
# then launch the Omniverse app before importing most simulation modules.
from isaaclab.app import AppLauncher
from lw_benchhub.utils.config_loader import config_loader


# ----------------------------- CLI -----------------------------------------

parser = argparse.ArgumentParser(
    description="No-eviction reproducer for LW-BenchHub kitchen host-RAM OOM."
)
parser.add_argument("--task_config", type=str, default="example", help="LW-BenchHub YAML config name")
parser.add_argument("--num_envs", type=int, required=True, help="Number of parallel kitchen envs to create")
parser.add_argument("--steps", type=int, default=100, help="Number of post-reset random/zero steps to run")
parser.add_argument("--log_dir", type=str, default=None, help="Directory for CSV, JSON, and smaps logs")
parser.add_argument("--layout", type=str, default=None, help="Override scene/layout, e.g. libero-1-1 or libero-8-8")
parser.add_argument("--task", type=str, default=None, help="Override LW-BenchHub task name")
parser.add_argument("--robot", type=str, default=None, help="Override robot name")
parser.add_argument("--scene_backend", type=str, default=None, help="Override scene backend")
parser.add_argument("--task_backend", type=str, default=None, help="Override task backend")
parser.add_argument("--render_mode", type=str, default="auto", choices=["auto", "none", "rgb_array"])
parser.add_argument("--camera_resolution", type=str, default=None, help="Override replay_cfgs.render_resolution as WIDTHxHEIGHT, e.g. 640x480")
parser.add_argument("--replicate_physics", type=str, default=None, choices=["true", "false"], help="Override env_cfg.scene.replicate_physics when present")
parser.add_argument("--clone_in_fabric", type=str, default=None, choices=["true", "false"], help="Override env_cfg.scene.clone_in_fabric when present")
parser.add_argument("--create_stage_in_memory", type=str, default=None, choices=["true", "false"], help="Override env_cfg.sim.create_stage_in_memory when present")
parser.add_argument("--disable_warmup_rendering", action="store_true", help="Do not call LW-BenchHub warmup_rendering")
parser.add_argument("--skip_steps", action="store_true", help="Only build and reset; do not step")
parser.add_argument("--abort_rss_gb", type=float, default=0.0, help="If >0, exit before intentionally exceeding this RSS")
parser.add_argument("--metadata", action="append", default=[], help="Extra key=value metadata to place in summary.json")
parser.add_argument("--print_env_cfg", action="store_true", help="Print env_cfg after construction")
parser.add_argument("--no_close", action="store_true", help="Do not close env at exit; useful only for post-mortem debugging")
parser.add_argument(
    "--trace_isaaclab_allocators",
    dest="trace_isaaclab_allocators",
    action="store_true",
    default=True,
    help="Checkpoint around known Isaac Lab allocation-heavy phases: SimulationContext.reset, InteractiveScene.clone_environments, and ManagerBasedRLEnv.step. Enabled by default.",
)
parser.add_argument(
    "--no_trace_isaaclab_allocators",
    dest="trace_isaaclab_allocators",
    action="store_false",
    help="Disable monkeypatch-based allocator phase tracing.",
)
parser.add_argument("--trace_max_calls", type=int, default=3, help="Maximum calls per traced method to checkpoint. Use 1 for minimal overhead; default: 3.")

# AppLauncher adds --headless, --enable_cameras, --device-like launcher args, etc.
AppLauncher.add_app_launcher_args(parser)
args_cli = parser.parse_args()

# Merge order:
#   1. argparse/AppLauncher defaults
#   2. LW-BenchHub YAML config
#   3. script control arguments and explicit CLI overrides
# This prevents argparse defaults such as enable_cameras=False or device=cuda:0
# from accidentally overwriting the real task_config values.
cli_raw = vars(args_cli).copy()
yaml_args = config_loader.load(args_cli.task_config)
yaml_dict = vars(yaml_args).copy()

merged = dict(cli_raw)
merged.update(yaml_dict)

# Script controls are not part of the LW-BenchHub task config, so keep the CLI values.
for key in [
    "task_config",
    "num_envs",
    "steps",
    "log_dir",
    "render_mode",
    "camera_resolution",
    "replicate_physics",
    "clone_in_fabric",
    "create_stage_in_memory",
    "disable_warmup_rendering",
    "skip_steps",
    "abort_rss_gb",
    "metadata",
    "print_env_cfg",
    "no_close",
    "trace_isaaclab_allocators",
    "trace_max_calls",
]:
    if key in cli_raw:
        merged[key] = cli_raw[key]

# Re-apply explicit task overrides only when the user actually supplied them.
for key in ["layout", "task", "robot", "scene_backend", "task_backend"]:
    if cli_raw.get(key) is not None:
        merged[key] = cli_raw[key]

# Device is an AppLauncher argument. Only let it override YAML if explicitly passed.
if cli_raw.get("device_explicit", False):
    merged["device"] = cli_raw["device"]

# Boolean AppLauncher flags should override YAML only when set True on the CLI.
for key in ["headless", "enable_cameras", "xr"]:
    if cli_raw.get(key) is True:
        merged[key] = True

# Non-boolean AppLauncher flags use explicit markers in recent Isaac Lab versions.
for key in ["livestream", "experience", "rendering_mode"]:
    if cli_raw.get(f"{key}_explicit", False):
        merged[key] = cli_raw[key]

args_cli = argparse.Namespace(**merged)

# Force the YAML config to use the requested number of envs.
args_cli.num_envs = int(args_cli.num_envs)

# Ensure common optional config fields exist. These defaults mirror how LW-BenchHub's
# own scripts are usually called, but can be overridden by the YAML or CLI.
for name, default in {
    "device": "cuda:0",
    "disable_fabric": False,
    "first_person_view": False,
    "robot_scale": 1.0,
    "execute_mode": "eval",
    "seed": 42,
    "sources": ["objaverse", "lightwheel", "aigen_objs"],
    "object_projects": [],
    "usd_simplify": False,
    "rl": None,
    "video": False,
    "concatenate_terms": False,
    "replay_cfgs": {},
}.items():
    if not hasattr(args_cli, name):
        setattr(args_cli, name, default)

# Optional camera resolution override for the actual render path used by LW-BenchHub.
if args_cli.camera_resolution:
    m = re.match(r"^(\d+)x(\d+)$", args_cli.camera_resolution.strip().lower())
    if not m:
        raise ValueError("--camera_resolution must look like WIDTHxHEIGHT, e.g. 640x480")
    w, h = int(m.group(1)), int(m.group(2))
    replay_cfgs = getattr(args_cli, "replay_cfgs", {}) or {}
    if not isinstance(replay_cfgs, dict):
        replay_cfgs = dict(replay_cfgs)
    replay_cfgs["render_resolution"] = [w, h]
    replay_cfgs["add_camera_to_observation"] = True
    args_cli.replay_cfgs = replay_cfgs

# If YAML enables cameras, make sure AppLauncher also enables them. If the CLI passed
# --enable_cameras, AppLauncher should have set this already.
if bool(getattr(args_cli, "enable_cameras", False)):
    setattr(args_cli, "enable_cameras", True)

# Set default output dir now, before launching Isaac.
if args_cli.log_dir is None:
    layout = str(getattr(args_cli, "layout", "unknown_layout"))
    args_cli.log_dir = f"oom_logs/{layout}_{args_cli.num_envs}env_{time.strftime('%Y%m%d_%H%M%S')}"
LOG_DIR = pathlib.Path(args_cli.log_dir).resolve()
LOG_DIR.mkdir(parents=True, exist_ok=True)

# Launch Omniverse / Isaac Sim.
app_launcher_args = vars(args_cli).copy()
app_launcher = AppLauncher(app_launcher_args)
simulation_app = app_launcher.app


# --------------------------- Diagnostics -----------------------------------

T0 = time.time()
MEM_CSV = LOG_DIR / "memory_checkpoints.csv"
EVENTS_JSONL = LOG_DIR / "events.jsonl"
SUMMARY_JSON = LOG_DIR / "summary.json"


def now_s() -> float:
    return time.time() - T0


def read_status() -> dict[str, int]:
    out: dict[str, int] = {}
    try:
        with open("/proc/self/status", "r", encoding="utf-8") as f:
            for line in f:
                if line.startswith(("VmRSS:", "VmHWM:", "VmPeak:", "VmSize:", "VmSwap:")):
                    key, rest = line.split(":", 1)
                    parts = rest.strip().split()
                    if parts:
                        out[key] = int(parts[0]) * 1024
    except Exception:
        pass
    return out


def parse_smaps_rollup() -> dict[str, int]:
    out: dict[str, int] = {}
    try:
        with open("/proc/self/smaps_rollup", "r", encoding="utf-8", errors="replace") as f:
            for line in f:
                if ":" not in line:
                    continue
                key, rest = line.split(":", 1)
                parts = rest.strip().split()
                if parts and parts[0].isdigit():
                    out[key] = int(parts[0]) * 1024
    except Exception:
        pass
    return out


def save_smaps_rollup(label: str) -> str | None:
    safe = re.sub(r"[^A-Za-z0-9_.-]+", "_", label).strip("_")[:80]
    path = LOG_DIR / f"smaps_rollup_{int(now_s()):06d}_{safe}.txt"
    try:
        data = pathlib.Path("/proc/self/smaps_rollup").read_text(encoding="utf-8", errors="replace")
        path.write_text(data, encoding="utf-8")
        return str(path)
    except Exception:
        return None


def nvidia_smi_for_pid(pid: int) -> dict[str, Any]:
    result: dict[str, Any] = {"pid_gpu_used_mb": None, "gpu_total_used_mb": None, "raw": None}
    try:
        p = subprocess.run(
            [
                "nvidia-smi",
                "--query-compute-apps=pid,used_memory",
                "--format=csv,noheader,nounits",
            ],
            check=False,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=5,
        )
        result["raw"] = p.stdout.strip()
        total = 0
        matched = False
        for line in p.stdout.splitlines():
            if not line.strip():
                continue
            pieces = [x.strip() for x in line.split(",")]
            if len(pieces) >= 2 and pieces[0].isdigit():
                row_pid = int(pieces[0])
                if row_pid == pid:
                    matched = True
                    total += int(pieces[1])
        if matched:
            result["pid_gpu_used_mb"] = total
    except Exception as exc:
        result["raw"] = f"nvidia-smi failed: {exc!r}"

    try:
        p2 = subprocess.run(
            [
                "nvidia-smi",
                "--query-gpu=memory.used",
                "--format=csv,noheader,nounits",
            ],
            check=False,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=5,
        )
        vals = [int(x.strip()) for x in p2.stdout.splitlines() if x.strip().isdigit()]
        if vals:
            result["gpu_total_used_mb"] = sum(vals)
    except Exception:
        pass
    return result


def gb(nbytes: int | None) -> float | None:
    if nbytes is None:
        return None
    return nbytes / (1024 ** 3)


def append_event(event: dict[str, Any]) -> None:
    with EVENTS_JSONL.open("a", encoding="utf-8") as f:
        f.write(json.dumps(event, sort_keys=True, default=str) + "\n")


def checkpoint(label: str, *, save_smaps: bool = True) -> dict[str, Any]:
    status = read_status()
    smaps = parse_smaps_rollup()
    gpu = nvidia_smi_for_pid(os.getpid())
    smaps_path = save_smaps_rollup(label) if save_smaps else None
    row: dict[str, Any] = {
        "t_s": f"{now_s():.3f}",
        "label": label,
        "pid": os.getpid(),
        "num_envs": args_cli.num_envs,
        "rss_gb": f"{gb(status.get('VmRSS')):.3f}" if status.get("VmRSS") is not None else "",
        "hwm_gb": f"{gb(status.get('VmHWM')):.3f}" if status.get("VmHWM") is not None else "",
        "vmsize_gb": f"{gb(status.get('VmSize')):.3f}" if status.get("VmSize") is not None else "",
        "swap_gb": f"{gb(status.get('VmSwap')):.3f}" if status.get("VmSwap") is not None else "",
        "smaps_rss_gb": f"{gb(smaps.get('Rss')):.3f}" if smaps.get("Rss") is not None else "",
        "smaps_pss_gb": f"{gb(smaps.get('Pss')):.3f}" if smaps.get("Pss") is not None else "",
        "private_dirty_gb": f"{gb(smaps.get('Private_Dirty')):.3f}" if smaps.get("Private_Dirty") is not None else "",
        "private_clean_gb": f"{gb(smaps.get('Private_Clean')):.3f}" if smaps.get("Private_Clean") is not None else "",
        "anonymous_gb": f"{gb(smaps.get('Anonymous')):.3f}" if smaps.get("Anonymous") is not None else "",
        "locked_gb": f"{gb(smaps.get('Locked')):.3f}" if smaps.get("Locked") is not None else "",
        "anon_huge_pages_gb": f"{gb(smaps.get('AnonHugePages')):.3f}" if smaps.get("AnonHugePages") is not None else "",
        "pid_gpu_used_mb": gpu.get("pid_gpu_used_mb"),
        "gpu_total_used_mb": gpu.get("gpu_total_used_mb"),
        "smaps_file": smaps_path or "",
    }

    write_header = not MEM_CSV.exists()
    with MEM_CSV.open("a", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=list(row.keys()))
        if write_header:
            writer.writeheader()
        writer.writerow(row)

    print(
        f"[{row['t_s']}s] {label}: RSS={row['rss_gb']} GB "
        f"HWM={row['hwm_gb']} GB GPU(pid)={row['pid_gpu_used_mb']} MB "
        f"GPU(total)={row['gpu_total_used_mb']} MB",
        flush=True,
    )
    append_event({"type": "checkpoint", **row})

    if args_cli.abort_rss_gb and status.get("VmRSS") is not None:
        if gb(status["VmRSS"]) >= args_cli.abort_rss_gb:
            print(
                f"[ABORT] RSS reached {gb(status['VmRSS']):.2f} GB; "
                f"--abort_rss_gb={args_cli.abort_rss_gb}. Exiting before host OOM.",
                flush=True,
            )
            write_summary(exit_reason="abort_rss_gb", last_checkpoint=row)
            sys.exit(100)
    return row


def write_summary(**extra: Any) -> None:
    meta = {}
    for item in getattr(args_cli, "metadata", []) or []:
        if "=" in item:
            k, v = item.split("=", 1)
            meta[k] = v
    summary = {
        "argv": sys.argv,
        "pid": os.getpid(),
        "cwd": os.getcwd(),
        "log_dir": str(LOG_DIR),
        "task_config": args_cli.task_config,
        "task": getattr(args_cli, "task", None),
        "robot": getattr(args_cli, "robot", None),
        "layout": getattr(args_cli, "layout", None),
        "scene_backend": getattr(args_cli, "scene_backend", None),
        "task_backend": getattr(args_cli, "task_backend", None),
        "num_envs": args_cli.num_envs,
        "enable_cameras": bool(getattr(args_cli, "enable_cameras", False)),
        "replay_cfgs": getattr(args_cli, "replay_cfgs", None),
        "device": getattr(args_cli, "device", None),
        "disable_fabric": getattr(args_cli, "disable_fabric", None),
        "replicate_physics_override": args_cli.replicate_physics,
        "clone_in_fabric_override": args_cli.clone_in_fabric,
        "create_stage_in_memory_override": args_cli.create_stage_in_memory,
        "trace_isaaclab_allocators": bool(getattr(args_cli, "trace_isaaclab_allocators", False)),
        "trace_max_calls": int(getattr(args_cli, "trace_max_calls", 0)),
        "metadata": meta,
        **extra,
    }
    SUMMARY_JSON.write_text(json.dumps(summary, indent=2, sort_keys=True, default=str), encoding="utf-8")


# --------------------------- Env creation ----------------------------------


TRACE_COUNTS: dict[str, int] = {}
TRACE_INSTALLED = False


def install_isaaclab_allocator_tracing() -> None:
    """Checkpoint around allocation-heavy Isaac Lab phases when symbols exist.

    This is intentionally observational: it does not clear reference bits, evict
    memory, remap VMAs, or mutate allocator state. It only wraps a few method
    calls so the CSV can distinguish symptom reproduction from first-pass cause
    localization.
    """
    global TRACE_INSTALLED
    if TRACE_INSTALLED:
        return
    TRACE_INSTALLED = True

    if not bool(getattr(args_cli, "trace_isaaclab_allocators", True)):
        append_event({"type": "allocator_trace_disabled"})
        return

    max_calls = max(0, int(getattr(args_cli, "trace_max_calls", 3) or 0))
    if max_calls <= 0:
        append_event({"type": "allocator_trace_disabled", "reason": "trace_max_calls<=0"})
        return

    targets = [
        ("isaaclab.sim.simulation_context", "SimulationContext", "reset", "SimulationContext.reset"),
        ("isaaclab.scene.interactive_scene", "InteractiveScene", "clone_environments", "InteractiveScene.clone_environments"),
        ("isaaclab.envs.manager_based_rl_env", "ManagerBasedRLEnv", "step", "ManagerBasedRLEnv.step"),
    ]

    for module_name, class_name, method_name, label_base in targets:
        try:
            module = importlib.import_module(module_name)
            cls = getattr(module, class_name)
            original = getattr(cls, method_name)
            if getattr(original, "_kitchen_oom_traced", False):
                append_event({"type": "allocator_trace_already_installed", "target": label_base})
                continue

            @functools.wraps(original)
            def wrapper(self, *args, __original=original, __label_base=label_base, **kwargs):
                call_index = TRACE_COUNTS.get(__label_base, 0) + 1
                TRACE_COUNTS[__label_base] = call_index
                if call_index <= max_calls:
                    append_event({"type": "allocator_trace_enter", "target": __label_base, "call_index": call_index})
                    checkpoint(f"TRACE before {__label_base} #{call_index}")
                    try:
                        result = __original(self, *args, **kwargs)
                    except BaseException as exc:
                        append_event(
                            {
                                "type": "allocator_trace_exception",
                                "target": __label_base,
                                "call_index": call_index,
                                "error": repr(exc),
                            }
                        )
                        try:
                            checkpoint(f"TRACE exception {__label_base} #{call_index}")
                        except Exception:
                            pass
                        raise
                    checkpoint(f"TRACE after {__label_base} #{call_index}")
                    append_event({"type": "allocator_trace_exit", "target": __label_base, "call_index": call_index})
                    return result
                return __original(self, *args, **kwargs)

            setattr(wrapper, "_kitchen_oom_traced", True)
            setattr(cls, method_name, wrapper)
            print(f"[TRACE] installed allocator checkpoint wrapper for {label_base}", flush=True)
            append_event({"type": "allocator_trace_installed", "target": label_base, "module": module_name})
        except Exception as exc:
            print(f"[TRACE] could not install wrapper for {label_base}: {exc!r}", flush=True)
            append_event(
                {
                    "type": "allocator_trace_install_failed",
                    "target": label_base,
                    "module": module_name,
                    "error": repr(exc),
                }
            )


def bool_str(value: str | None) -> bool | None:
    if value is None:
        return None
    return value.lower() == "true"


def filtered_call(fn: Any, kwargs: dict[str, Any]) -> Any:
    sig = inspect.signature(fn)
    if any(p.kind == inspect.Parameter.VAR_KEYWORD for p in sig.parameters.values()):
        return fn(**kwargs)
    return fn(**{k: v for k, v in kwargs.items() if k in sig.parameters})


def resolve_execute_mode() -> Any:
    from lw_benchhub.utils import env as env_utils

    mode_name = str(getattr(args_cli, "execute_mode", "eval"))
    if hasattr(env_utils, "str_to_execute_mode"):
        return env_utils.str_to_execute_mode(mode_name)
    ExecuteMode = getattr(env_utils, "ExecuteMode")
    return getattr(ExecuteMode, mode_name.upper(), ExecuteMode.EVAL)


def make_env_cfg() -> tuple[str, Any]:
    import gymnasium as gym
    from lw_benchhub.utils.env import parse_env_cfg

    execute_mode = resolve_execute_mode()
    parse_kwargs = {
        "scene_backend": args_cli.scene_backend,
        "task_backend": args_cli.task_backend,
        "task_name": args_cli.task,
        "robot_name": args_cli.robot,
        "scene_name": args_cli.layout,
        "rl_name": getattr(args_cli, "rl", None),
        "robot_scale": getattr(args_cli, "robot_scale", 1.0),
        "device": args_cli.device,
        "num_envs": args_cli.num_envs,
        "use_fabric": not bool(getattr(args_cli, "disable_fabric", False)),
        "first_person_view": bool(getattr(args_cli, "first_person_view", False)),
        "enable_cameras": bool(getattr(app_launcher, "_enable_cameras", getattr(args_cli, "enable_cameras", False))),
        "execute_mode": execute_mode,
        "headless_mode": bool(getattr(args_cli, "headless", False)),
        "usd_simplify": bool(getattr(args_cli, "usd_simplify", False)),
        "seed": getattr(args_cli, "seed", 42),
        "sources": getattr(args_cli, "sources", []),
        "object_projects": getattr(args_cli, "object_projects", []),
        "replay_cfgs": getattr(args_cli, "replay_cfgs", {}),
    }
    env_cfg = filtered_call(parse_env_cfg, parse_kwargs)

    # Explicitly force num_envs/device after parse to avoid YAML defaults winning.
    if hasattr(env_cfg, "scene"):
        env_cfg.scene.num_envs = args_cli.num_envs
        if bool_str(args_cli.replicate_physics) is not None and hasattr(env_cfg.scene, "replicate_physics"):
            env_cfg.scene.replicate_physics = bool_str(args_cli.replicate_physics)
        if bool_str(args_cli.clone_in_fabric) is not None and hasattr(env_cfg.scene, "clone_in_fabric"):
            env_cfg.scene.clone_in_fabric = bool_str(args_cli.clone_in_fabric)
    if hasattr(env_cfg, "sim"):
        env_cfg.sim.device = args_cli.device
        if bool_str(args_cli.create_stage_in_memory) is not None and hasattr(env_cfg.sim, "create_stage_in_memory"):
            env_cfg.sim.create_stage_in_memory = bool_str(args_cli.create_stage_in_memory)
    if hasattr(env_cfg, "observations") and hasattr(env_cfg.observations, "policy"):
        if hasattr(env_cfg.observations.policy, "concatenate_terms"):
            env_cfg.observations.policy.concatenate_terms = bool(getattr(args_cli, "concatenate_terms", False))

    task_name = f"LWBenchHubKitchenOOM-{args_cli.task}-{args_cli.robot}-v0"
    try:
        gym.register(
            id=task_name,
            entry_point="isaaclab.envs:ManagerBasedRLEnv",
            kwargs={},
            disable_env_checker=True,
        )
    except Exception as exc:
        # Duplicate registration is harmless in some local iteration cases.
        print(f"[WARN] gymnasium.register failed or duplicate id: {exc!r}", flush=True)
    return task_name, env_cfg


def get_stage_stats() -> dict[str, int] | None:
    try:
        import omni.usd
        from pxr import UsdGeom, UsdShade

        stage = omni.usd.get_context().get_stage()
        if stage is None:
            return None
        stats = {
            "prim_count": 0,
            "mesh_count": 0,
            "camera_count": 0,
            "material_count": 0,
            "xform_count": 0,
        }
        for prim in stage.Traverse():
            stats["prim_count"] += 1
            if prim.IsA(UsdGeom.Mesh):
                stats["mesh_count"] += 1
            if prim.IsA(UsdGeom.Camera):
                stats["camera_count"] += 1
            if prim.IsA(UsdShade.Material):
                stats["material_count"] += 1
            if prim.IsA(UsdGeom.Xform):
                stats["xform_count"] += 1
        return stats
    except Exception as exc:
        append_event({"type": "stage_stats_error", "error": repr(exc)})
        return None


def zero_action(env: Any, env_cfg: Any) -> Any:
    try:
        return env.action_space.sample()
    except Exception:
        pass

    try:
        import torch
        unwrapped = getattr(env, "unwrapped", env)
        num_envs = getattr(unwrapped, "num_envs", args_cli.num_envs)
        device = getattr(getattr(env_cfg, "sim", SimpleNamespace(device=args_cli.device)), "device", args_cli.device)
        action_dim = None
        if hasattr(unwrapped, "action_manager") and hasattr(unwrapped.action_manager, "total_action_dim"):
            action_dim = unwrapped.action_manager.total_action_dim
        elif hasattr(env, "single_action_space"):
            shape = getattr(env.single_action_space, "shape", None)
            if shape:
                action_dim = int(shape[-1])
        elif hasattr(env, "action_space"):
            shape = getattr(env.action_space, "shape", None)
            if shape:
                action_dim = int(shape[-1])
        if action_dim is None:
            raise RuntimeError("Could not infer action dimension")
        return torch.zeros((num_envs, action_dim), device=device)
    except Exception as exc:
        raise RuntimeError(f"Could not create action for env.step: {exc!r}")


def main() -> None:
    checkpoint("after AppLauncher")
    write_summary(exit_reason="started")

    # Imports that should happen after AppLauncher.
    import gymnasium as gym
    import torch

    random.seed(int(getattr(args_cli, "seed", 42)))
    try:
        torch.manual_seed(int(getattr(args_cli, "seed", 42)))
    except Exception:
        pass

    install_isaaclab_allocator_tracing()

    checkpoint("before parse_env_cfg")
    task_name, env_cfg = make_env_cfg()
    checkpoint("after parse_env_cfg")

    if args_cli.print_env_cfg:
        print("========== env_cfg ==========")
        print(env_cfg)
        print("=============================", flush=True)

    render_mode = None
    if args_cli.render_mode == "rgb_array":
        render_mode = "rgb_array"
    elif args_cli.render_mode == "auto":
        render_mode = "rgb_array" if bool(getattr(args_cli, "enable_cameras", False)) else None

    env = None
    try:
        checkpoint("before gymnasium.make")
        env = gym.make(task_name, cfg=env_cfg, render_mode=render_mode)
        checkpoint("after gymnasium.make")

        stage_stats = get_stage_stats()
        if stage_stats:
            print(f"[STAGE] {json.dumps(stage_stats, sort_keys=True)}", flush=True)
            append_event({"type": "stage_stats_after_gymnasium_make", **stage_stats})
            write_summary(stage_stats_after_gymnasium_make=stage_stats)

        unwrapped = getattr(env, "unwrapped", env)

        if not args_cli.disable_warmup_rendering:
            try:
                checkpoint("before warmup_rendering")
                from lw_benchhub.utils.place_utils.env_utils import warmup_rendering

                warmup_rendering(unwrapped)
                checkpoint("after warmup_rendering")
            except Exception as exc:
                print(f"[WARN] warmup_rendering failed: {exc!r}", flush=True)
                append_event({"type": "warmup_rendering_error", "error": repr(exc)})
                checkpoint("after warmup_rendering_error")

        checkpoint("before env.reset")
        reset_out = env.reset()
        checkpoint("after env.reset")
        append_event({"type": "reset_result_type", "repr": repr(type(reset_out))})

        # Force at least one render if the env exposes render(). This is important for
        # distinguishing scene-load memory from first-render/camera memory.
        try:
            checkpoint("before first env.render")
            _ = env.render()
            checkpoint("after first env.render")
        except Exception as exc:
            print(f"[WARN] env.render failed or unsupported: {exc!r}", flush=True)
            append_event({"type": "render_error", "error": repr(exc)})
            checkpoint("after render_error")

        if not args_cli.skip_steps:
            action = zero_action(env, env_cfg)
            checkpoint("before first env.step")
            _ = env.step(action)
            checkpoint("after first env.step")

            for i in range(1, args_cli.steps):
                action = zero_action(env, env_cfg)
                _ = env.step(action)
                if i in {9, 49, 99} or (i + 1) == args_cli.steps:
                    checkpoint(f"after step {i + 1}", save_smaps=(i in {9, 99} or (i + 1) == args_cli.steps))

        checkpoint("completed")
        write_summary(exit_reason="completed")

    except BaseException as exc:
        print("[ERROR] Reproducer failed:", repr(exc), flush=True)
        traceback.print_exc()
        append_event({"type": "exception", "error": repr(exc), "traceback": traceback.format_exc()})
        try:
            checkpoint("exception")
        except Exception:
            pass
        write_summary(exit_reason="exception", exception=repr(exc), traceback=traceback.format_exc())
        raise
    finally:
        if env is not None and not args_cli.no_close:
            try:
                checkpoint("before env.close", save_smaps=False)
                env.close()
                checkpoint("after env.close", save_smaps=False)
            except Exception as exc:
                print(f"[WARN] env.close failed: {exc!r}", flush=True)
        try:
            checkpoint("before simulation_app.close", save_smaps=False)
            simulation_app.close()
        except Exception as exc:
            print(f"[WARN] simulation_app.close failed: {exc!r}", flush=True)


if __name__ == "__main__":
    main()
