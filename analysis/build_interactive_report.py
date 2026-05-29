#!/usr/bin/env python3
"""Build an offline interactive HTML report from kitchen OOM repro logs."""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path
from typing import Any


def require_deps() -> None:
    missing: list[str] = []
    for mod in ("pandas", "plotly"):
        try:
            __import__(mod)
        except Exception:
            missing.append(mod)
    if missing:
        raise SystemExit(
            "Missing analysis dependencies: "
            + ", ".join(missing)
            + "\nInstall them with: python -m pip install pandas plotly matplotlib"
        )


def read_json(path: Path) -> dict[str, Any]:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return {}


def parse_exit_status(run_dir: Path) -> str:
    for name in ("wrapper.log", "stdout_stderr.log"):
        path = run_dir / name
        if not path.exists():
            continue
        try:
            text = path.read_text(encoding="utf-8", errors="replace")
        except Exception:
            continue
        matches = re.findall(r"exit_status=([^\s]+)", text)
        if matches:
            return matches[-1]
    return ""


def scenario_from_path(log_root: Path, run_dir: Path, summary: dict[str, Any]) -> str:
    metadata = summary.get("metadata") or {}
    if isinstance(metadata, dict) and metadata.get("scenario"):
        return str(metadata["scenario"])
    try:
        rel = run_dir.relative_to(log_root)
        if len(rel.parts) > 1:
            return rel.parts[0]
    except Exception:
        pass
    return "unspecified"


def to_numeric_columns(df):
    import pandas as pd

    for col in df.columns:
        if col in {"label", "smaps_file"}:
            continue
        try:
            df[col] = pd.to_numeric(df[col])
        except Exception:
            pass
    return df


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
        if df.empty:
            continue
        df = to_numeric_columns(df)
        summary = read_json(run_dir / "summary.json")
        rel = str(run_dir.relative_to(log_root)) if run_dir.is_relative_to(log_root) else str(run_dir)
        df["run_dir"] = str(run_dir)
        df["run_id"] = rel
        df["run_name"] = run_dir.name
        df["scenario"] = scenario_from_path(log_root, run_dir, summary)
        df["layout"] = summary.get("layout") or df.get("layout", "")
        df["task_config"] = summary.get("task_config", "")
        df["task"] = summary.get("task", "")
        df["robot"] = summary.get("robot", "")
        df["exit_reason"] = summary.get("exit_reason", "")
        df["exit_status"] = parse_exit_status(run_dir)
        df["enable_cameras"] = summary.get("enable_cameras", "")
        df["checkpoint_index"] = range(len(df))
        frames.append(df)
    if not frames:
        return pd.DataFrame()
    return pd.concat(frames, ignore_index=True)


def build_summary(df):
    import pandas as pd

    if df.empty:
        return pd.DataFrame()
    group_cols = ["run_id", "run_dir", "run_name", "scenario", "layout", "num_envs", "enable_cameras", "exit_reason", "exit_status"]
    for col in group_cols:
        if col not in df.columns:
            df[col] = ""
    numeric_cols = [
        "rss_gb",
        "hwm_gb",
        "smaps_rss_gb",
        "smaps_pss_gb",
        "private_dirty_gb",
        "private_clean_gb",
        "anonymous_gb",
        "locked_gb",
        "anon_huge_pages_gb",
        "pid_gpu_used_mb",
        "gpu_total_used_mb",
        "t_s",
    ]
    for col in numeric_cols:
        if col in df.columns:
            df[col] = pd.to_numeric(df[col], errors="coerce")
    summary = (
        df.groupby(group_cols, dropna=False)
        .agg(
            max_rss_gb=("rss_gb", "max"),
            max_hwm_gb=("hwm_gb", "max"),
            max_smaps_pss_gb=("smaps_pss_gb", "max"),
            max_private_dirty_gb=("private_dirty_gb", "max"),
            max_anonymous_gb=("anonymous_gb", "max"),
            max_locked_gb=("locked_gb", "max"),
            max_pid_gpu_used_mb=("pid_gpu_used_mb", "max"),
            max_gpu_total_used_mb=("gpu_total_used_mb", "max"),
            duration_s=("t_s", "max"),
            checkpoints=("label", "count"),
            first_label=("label", "first"),
            last_label=("label", "last"),
        )
        .reset_index()
        .sort_values(["scenario", "layout", "num_envs", "run_name"], na_position="last")
    )
    return summary


def classify_transition(transition: str) -> str:
    text = str(transition)
    if "InteractiveScene.clone_environments" in text:
        return "clone_environments"
    if "SimulationContext.reset" in text:
        return "SimulationContext.reset"
    if "ManagerBasedRLEnv.step" in text:
        return "ManagerBasedRLEnv.step / warm step"
    if "gymnasium.make" in text:
        return "gymnasium.make env construction"
    if "warmup_rendering" in text:
        return "camera/render warmup"
    if "first env.render" in text:
        return "first render / camera path"
    if "env.reset" in text:
        return "env.reset / physics init"
    if "first env.step" in text:
        return "first env.step / runtime buffers"
    if "parse_env_cfg" in text:
        return "config parsing"
    return "other"


def compute_deltas(df):
    import pandas as pd

    if df.empty:
        return pd.DataFrame()
    required = {"run_id", "checkpoint_index", "label"}
    if not required.issubset(df.columns):
        return pd.DataFrame()

    numeric_candidates = [
        "rss_gb",
        "hwm_gb",
        "smaps_rss_gb",
        "smaps_pss_gb",
        "private_dirty_gb",
        "private_clean_gb",
        "anonymous_gb",
        "locked_gb",
        "anon_huge_pages_gb",
        "pid_gpu_used_mb",
        "gpu_total_used_mb",
        "t_s",
    ]
    work = df.sort_values(["run_id", "checkpoint_index"]).copy()
    for col in numeric_candidates:
        if col in work.columns:
            work[col] = pd.to_numeric(work[col], errors="coerce")

    rows = []
    for run_id, group in work.groupby("run_id", dropna=False):
        group = group.sort_values("checkpoint_index").reset_index(drop=True)
        for i in range(1, len(group)):
            prev = group.iloc[i - 1]
            cur = group.iloc[i]
            transition = f"{prev.get('label', '')} -> {cur.get('label', '')}"
            row = {
                "run_id": run_id,
                "run_dir": cur.get("run_dir", ""),
                "scenario": cur.get("scenario", ""),
                "layout": cur.get("layout", ""),
                "num_envs": cur.get("num_envs", ""),
                "from_label": prev.get("label", ""),
                "to_label": cur.get("label", ""),
                "transition": transition,
                "phase_hint": classify_transition(transition),
                "checkpoint_index": cur.get("checkpoint_index", i),
            }
            for col in numeric_candidates:
                if col in work.columns:
                    try:
                        row[f"delta_{col}"] = cur[col] - prev[col]
                    except Exception:
                        row[f"delta_{col}"] = None
            rows.append(row)
    return pd.DataFrame(rows)


def make_delta_table_html(deltas) -> str:
    if deltas.empty or "delta_rss_gb" not in deltas.columns:
        return "<p>No checkpoint delta table available.</p>"
    view = deltas.copy()
    view = view.sort_values("delta_rss_gb", ascending=False, na_position="last").head(30)
    cols = [
        "scenario",
        "layout",
        "num_envs",
        "phase_hint",
        "transition",
        "delta_rss_gb",
        "delta_private_dirty_gb",
        "delta_anonymous_gb",
        "delta_locked_gb",
        "delta_pid_gpu_used_mb",
        "run_id",
    ]
    available = [c for c in cols if c in view.columns]
    view = view[available].copy()
    for col in view.select_dtypes(include="number").columns:
        view[col] = view[col].round(3)
    return view.to_html(index=False, classes="summary-table", escape=True)


def make_table_html(summary) -> str:
    cols = [
        "scenario",
        "layout",
        "num_envs",
        "enable_cameras",
        "exit_reason",
        "exit_status",
        "max_hwm_gb",
        "max_rss_gb",
        "max_private_dirty_gb",
        "max_anonymous_gb",
        "max_locked_gb",
        "max_pid_gpu_used_mb",
        "duration_s",
        "last_label",
        "run_id",
    ]
    available = [c for c in cols if c in summary.columns]
    if not available:
        return "<p>No summary table available.</p>"
    view = summary[available].copy()
    for col in view.select_dtypes(include="number").columns:
        view[col] = view[col].round(3)
    return view.to_html(index=False, classes="summary-table", escape=True)


def plot_html_parts(df, summary, deltas):
    import pandas as pd
    import plotly.express as px
    import plotly.io as pio

    parts: list[str] = []
    include_js: bool | str = True

    def add_fig(title: str, fig) -> None:
        nonlocal include_js
        fig.update_layout(title=title, template="plotly_white", hovermode="closest")
        parts.append(pio.to_html(fig, include_plotlyjs=include_js, full_html=False))
        include_js = False

    if not df.empty and {"t_s", "rss_gb", "run_id"}.issubset(df.columns):
        fig = px.line(
            df,
            x="t_s",
            y="rss_gb",
            color="run_id",
            line_group="run_id",
            hover_data=[c for c in ["label", "scenario", "layout", "num_envs", "hwm_gb", "pid_gpu_used_mb"] if c in df.columns],
            labels={"t_s": "seconds", "rss_gb": "RSS (GB)"},
        )
        add_fig("RSS over time by run", fig)

    if not summary.empty and {"num_envs", "max_hwm_gb"}.issubset(summary.columns):
        fig = px.scatter(
            summary,
            x="num_envs",
            y="max_hwm_gb",
            color="scenario",
            symbol="layout" if "layout" in summary.columns else None,
            hover_data=[c for c in ["run_id", "max_rss_gb", "max_private_dirty_gb", "max_anonymous_gb", "exit_reason", "exit_status"] if c in summary.columns],
            labels={"num_envs": "num_envs", "max_hwm_gb": "Peak VmHWM (GB)"},
        )
        add_fig("Peak host memory vs number of environments", fig)

    if not summary.empty and {"num_envs", "max_pid_gpu_used_mb"}.issubset(summary.columns):
        gpu_summary = summary.dropna(subset=["max_pid_gpu_used_mb"])
        if not gpu_summary.empty:
            fig = px.scatter(
                gpu_summary,
                x="num_envs",
                y="max_pid_gpu_used_mb",
                color="scenario",
                symbol="layout" if "layout" in gpu_summary.columns else None,
                hover_data=[c for c in ["run_id", "max_gpu_total_used_mb", "max_hwm_gb", "exit_reason"] if c in gpu_summary.columns],
                labels={"num_envs": "num_envs", "max_pid_gpu_used_mb": "Peak process VRAM (MB)"},
            )
            add_fig("Peak process GPU memory vs number of environments", fig)

    component_cols = [c for c in ["rss_gb", "smaps_pss_gb", "private_dirty_gb", "anonymous_gb", "locked_gb"] if c in df.columns]
    if component_cols:
        comp = df[["run_id", "checkpoint_index", "label"] + component_cols].copy()
        comp = comp.melt(id_vars=["run_id", "checkpoint_index", "label"], value_vars=component_cols, var_name="component", value_name="gb")
        comp["gb"] = pd.to_numeric(comp["gb"], errors="coerce")
        comp = comp.dropna(subset=["gb"])
        if not comp.empty:
            fig = px.line(
                comp,
                x="checkpoint_index",
                y="gb",
                color="component",
                line_dash="run_id",
                hover_data=["run_id", "label"],
                labels={"checkpoint_index": "checkpoint index", "gb": "GB"},
            )
            add_fig("Memory components across checkpoints", fig)

    if not deltas.empty and {"delta_rss_gb", "transition", "run_id"}.issubset(deltas.columns):
        delta_view = deltas.dropna(subset=["delta_rss_gb"]).copy()
        delta_view = delta_view.sort_values("delta_rss_gb", ascending=False).head(40)
        if not delta_view.empty:
            delta_view["transition_short"] = delta_view["transition"].astype(str).str.slice(0, 90)
            fig = px.bar(
                delta_view,
                x="delta_rss_gb",
                y="transition_short",
                color="phase_hint" if "phase_hint" in delta_view.columns else None,
                hover_data=[c for c in ["run_id", "scenario", "layout", "num_envs", "delta_private_dirty_gb", "delta_anonymous_gb", "delta_locked_gb", "delta_pid_gpu_used_mb"] if c in delta_view.columns],
                labels={"delta_rss_gb": "RSS delta (GB)", "transition_short": "checkpoint transition"},
                orientation="h",
            )
            fig.update_layout(yaxis={"categoryorder": "total ascending"})
            add_fig("Largest positive RSS jumps by checkpoint transition", fig)

    if not deltas.empty and {"num_envs", "delta_rss_gb", "phase_hint"}.issubset(deltas.columns):
        focus = deltas[deltas["phase_hint"].isin(["clone_environments", "SimulationContext.reset", "ManagerBasedRLEnv.step / warm step", "gymnasium.make env construction", "env.reset / physics init", "first env.step / runtime buffers"])]
        focus = focus.dropna(subset=["delta_rss_gb", "num_envs"])
        if not focus.empty:
            fig = px.scatter(
                focus,
                x="num_envs",
                y="delta_rss_gb",
                color="phase_hint",
                symbol="scenario" if "scenario" in focus.columns else None,
                hover_data=[c for c in ["run_id", "transition", "layout", "delta_private_dirty_gb", "delta_anonymous_gb", "delta_locked_gb"] if c in focus.columns],
                labels={"num_envs": "num_envs", "delta_rss_gb": "RSS delta for phase (GB)"},
            )
            add_fig("Allocator-phase RSS deltas vs number of environments", fig)

    if not df.empty and {"label", "rss_gb"}.issubset(df.columns):
        # The last row per label/run keeps the chart compact while preserving checkpoint names.
        label_df = df.dropna(subset=["rss_gb"]).copy()
        label_df["label_short"] = label_df["label"].astype(str).str.slice(0, 45)
        fig = px.box(
            label_df,
            x="label_short",
            y="rss_gb",
            points="all",
            color="scenario" if "scenario" in label_df.columns else None,
            hover_data=[c for c in ["run_id", "layout", "num_envs"] if c in label_df.columns],
            labels={"label_short": "checkpoint", "rss_gb": "RSS (GB)"},
        )
        fig.update_layout(xaxis_tickangle=-45)
        add_fig("RSS distribution by checkpoint", fig)

    return parts


def main() -> None:
    require_deps()
    import pandas as pd

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("log_root", type=Path, help="Root directory containing OOM run logs")
    parser.add_argument("--output", type=Path, default=None, help="Output HTML file")
    args = parser.parse_args()

    log_root = args.log_root.resolve()
    output = args.output or (log_root / "analysis" / "oom_report.html")
    output.parent.mkdir(parents=True, exist_ok=True)

    df = load_logs(log_root)
    if df.empty:
        raise SystemExit(f"No memory_checkpoints.csv files found under {log_root}")
    summary = build_summary(df)
    deltas = compute_deltas(df)

    combined_csv = output.parent / "combined_checkpoints.csv"
    summary_csv = output.parent / "summary_by_run.csv"
    deltas_csv = output.parent / "checkpoint_deltas.csv"
    df.to_csv(combined_csv, index=False)
    summary.to_csv(summary_csv, index=False)
    deltas.to_csv(deltas_csv, index=False)

    table_html = make_table_html(summary)
    delta_table_html = make_delta_table_html(deltas)
    plot_parts = plot_html_parts(df, summary, deltas)

    style = """
    <style>
      body { font-family: system-ui, -apple-system, Segoe UI, sans-serif; margin: 2rem; line-height: 1.4; }
      h1, h2 { margin-top: 1.5rem; }
      .summary-table { border-collapse: collapse; width: 100%; font-size: 0.88rem; }
      .summary-table th, .summary-table td { border: 1px solid #ddd; padding: 0.35rem 0.45rem; vertical-align: top; }
      .summary-table th { background: #f5f5f5; position: sticky; top: 0; }
      .note { background: #f7f7ff; border-left: 4px solid #7777cc; padding: 0.75rem 1rem; }
      code { background: #f5f5f5; padding: 0.1rem 0.25rem; }
    </style>
    """

    html = f"""<!doctype html>
<html>
<head>
<meta charset="utf-8">
<title>LW-BenchHub Kitchen OOM Report</title>
{style}
</head>
<body>
<h1>LW-BenchHub Kitchen OOM Report</h1>
<p>Log root: <code>{log_root}</code></p>
<p>Generated from <code>memory_checkpoints.csv</code>, <code>summary.json</code>, and wrapper logs.</p>
<div class="note">
  <strong>Reading guide:</strong> Reproducing high RSS is only the first step. Cause localization starts with the largest positive checkpoint deltas.
  Focus first on traced allocator phases such as <code>TRACE after InteractiveScene.clone_environments</code>,
  <code>TRACE after SimulationContext.reset</code>, and <code>TRACE after ManagerBasedRLEnv.step</code>.
  Without trace labels, a large jump at <code>after gymnasium.make</code> usually points to scene construction, USD loading, cloning, or asset duplication;
  <code>after warmup_rendering</code> / <code>after first env.render</code> points to cameras/render products;
  <code>after env.reset</code> / <code>after first env.step</code> points to physics initialization, contact structures, or runtime buffers.
</div>
<h2>Run summary</h2>
<p>CSV outputs: <code>{combined_csv.name}</code>, <code>{summary_csv.name}</code>, and <code>{deltas_csv.name}</code>.</p>
{table_html}
<h2>Largest checkpoint RSS deltas</h2>
<p>This table helps avoid conflating the reproduced symptom with the cause. It lists the biggest positive RSS jumps between adjacent checkpoints.</p>
{delta_table_html}
<h2>Interactive plots</h2>
{''.join(plot_parts)}
</body>
</html>
"""
    output.write_text(html, encoding="utf-8")
    print(f"Wrote interactive report: {output}")
    print(f"Wrote combined checkpoints: {combined_csv}")
    print(f"Wrote run summary: {summary_csv}")
    print(f"Wrote checkpoint deltas: {deltas_csv}")


if __name__ == "__main__":
    main()
