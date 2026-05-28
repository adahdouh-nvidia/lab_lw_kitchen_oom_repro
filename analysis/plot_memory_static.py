#!/usr/bin/env python3
"""Generate static PNG plots from kitchen OOM repro logs."""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path
from typing import Any


def require_deps() -> None:
    missing: list[str] = []
    for mod in ("pandas", "matplotlib"):
        try:
            __import__(mod)
        except Exception:
            missing.append(mod)
    if missing:
        raise SystemExit(
            "Missing analysis dependencies: "
            + ", ".join(missing)
            + "\nInstall them with: python -m pip install pandas matplotlib"
        )


def read_json(path: Path) -> dict[str, Any]:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return {}


def load_logs(log_root: Path):
    import pandas as pd

    frames = []
    for csv_path in sorted(log_root.rglob("memory_checkpoints.csv")):
        run_dir = csv_path.parent
        try:
            df = pd.read_csv(csv_path)
        except Exception as exc:
            print(f"[WARN] Could not read {csv_path}: {exc}")
            continue
        summary = read_json(run_dir / "summary.json")
        rel = str(run_dir.relative_to(log_root)) if run_dir.is_relative_to(log_root) else str(run_dir)
        df["run_id"] = rel
        df["scenario"] = (summary.get("metadata") or {}).get("scenario", rel.split("/")[0])
        df["layout"] = summary.get("layout", "")
        for col in ["t_s", "rss_gb", "hwm_gb", "num_envs", "pid_gpu_used_mb", "gpu_total_used_mb"]:
            if col in df.columns:
                df[col] = pd.to_numeric(df[col], errors="coerce")
        frames.append(df)
    if not frames:
        return pd.DataFrame()
    return pd.concat(frames, ignore_index=True)


def summary_by_run(df):
    if df.empty:
        return df
    return (
        df.groupby(["run_id", "scenario", "layout", "num_envs"], dropna=False)
        .agg(
            max_rss_gb=("rss_gb", "max"),
            max_hwm_gb=("hwm_gb", "max"),
            max_pid_gpu_used_mb=("pid_gpu_used_mb", "max"),
            duration_s=("t_s", "max"),
        )
        .reset_index()
    )


def main() -> None:
    require_deps()
    import matplotlib.pyplot as plt

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("log_root", type=Path, help="Root directory containing OOM run logs")
    parser.add_argument("--output-dir", type=Path, default=None, help="Directory for PNG outputs")
    args = parser.parse_args()

    log_root = args.log_root.resolve()
    out_dir = (args.output_dir or (log_root / "analysis")).resolve()
    out_dir.mkdir(parents=True, exist_ok=True)

    df = load_logs(log_root)
    if df.empty:
        raise SystemExit(f"No memory_checkpoints.csv files found under {log_root}")
    summary = summary_by_run(df)
    summary.to_csv(out_dir / "static_summary_by_run.csv", index=False)

    # Plot 1: RSS timeline.
    fig, ax = plt.subplots(figsize=(12, 7))
    for run_id, group in df.dropna(subset=["t_s", "rss_gb"]).groupby("run_id"):
        ax.plot(group["t_s"], group["rss_gb"], marker="o", linewidth=1, label=run_id[:80])
    ax.set_xlabel("seconds")
    ax.set_ylabel("RSS (GB)")
    ax.set_title("RSS over time by run")
    if df["run_id"].nunique() <= 12:
        ax.legend(fontsize=7)
    fig.tight_layout()
    path1 = out_dir / "rss_over_time.png"
    fig.savefig(path1, dpi=160)
    plt.close(fig)

    # Plot 2: peak high-water RSS vs env count.
    fig, ax = plt.subplots(figsize=(10, 6))
    for scenario, group in summary.dropna(subset=["num_envs", "max_hwm_gb"]).groupby("scenario"):
        group = group.sort_values("num_envs")
        ax.plot(group["num_envs"], group["max_hwm_gb"], marker="o", linewidth=1, label=str(scenario)[:50])
    ax.set_xlabel("num_envs")
    ax.set_ylabel("Peak VmHWM (GB)")
    ax.set_title("Peak host memory vs number of environments")
    ax.legend(fontsize=8)
    fig.tight_layout()
    path2 = out_dir / "peak_hwm_vs_num_envs.png"
    fig.savefig(path2, dpi=160)
    plt.close(fig)

    # Plot 3: peak process GPU memory vs env count.
    if "max_pid_gpu_used_mb" in summary.columns and summary["max_pid_gpu_used_mb"].notna().any():
        fig, ax = plt.subplots(figsize=(10, 6))
        for scenario, group in summary.dropna(subset=["num_envs", "max_pid_gpu_used_mb"]).groupby("scenario"):
            group = group.sort_values("num_envs")
            ax.plot(group["num_envs"], group["max_pid_gpu_used_mb"], marker="o", linewidth=1, label=str(scenario)[:50])
        ax.set_xlabel("num_envs")
        ax.set_ylabel("Peak process GPU memory (MB)")
        ax.set_title("Peak process GPU memory vs number of environments")
        ax.legend(fontsize=8)
        fig.tight_layout()
        path3 = out_dir / "peak_gpu_vs_num_envs.png"
        fig.savefig(path3, dpi=160)
        plt.close(fig)

    print(f"Wrote static plots and CSV summary to {out_dir}")


if __name__ == "__main__":
    main()
