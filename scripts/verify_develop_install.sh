#!/usr/bin/env bash
set -euo pipefail

# Sanity checks that the active environment is targeting Isaac Sim develop and Isaac Lab develop.
# Run after sourcing activate_lw_kitchen_oom.sh.

failures=0

check_git_checkout() {
  local label="$1"
  local dir="$2"
  local expected_ref="$3"
  local expected_remote_fragment="$4"

  echo ""
  echo "==== $label ===="
  if [[ -z "$dir" ]]; then
    echo "ERROR: $label directory variable is empty" >&2
    failures=$((failures + 1))
    return 0
  fi
  if [[ ! -d "$dir/.git" ]]; then
    echo "ERROR: $label is not a git checkout: $dir" >&2
    failures=$((failures + 1))
    return 0
  fi

  local branch commit remote
  branch="$(git -C "$dir" rev-parse --abbrev-ref HEAD || true)"
  commit="$(git -C "$dir" rev-parse HEAD || true)"
  remote="$(git -C "$dir" remote get-url origin || true)"

  printf '%s dir: %s\n' "$label" "$dir"
  printf '%s branch/ref: %s\n' "$label" "$branch"
  printf '%s commit: %s\n' "$label" "$commit"
  printf '%s remote: %s\n' "$label" "$remote"

  if [[ -n "$expected_ref" && "$expected_ref" == "develop" && "$branch" != "develop" ]]; then
    echo "WARN: $label branch is '$branch', not 'develop'. This is OK only if an exact commit/tag was intentionally checked out."
  fi
  if [[ -n "$expected_remote_fragment" && "$remote" != *"$expected_remote_fragment"* ]]; then
    echo "WARN: $label remote does not look like $expected_remote_fragment"
  fi
}

if [[ -z "${ISAACLAB_DIR:-}" ]]; then
  echo "ERROR: ISAACLAB_DIR is not set. Source activate_lw_kitchen_oom.sh first." >&2
  exit 2
fi

check_git_checkout "Isaac Sim" "${ISAACSIM_DIR:-}" "${ISAACSIM_REPO_REF:-develop}" "isaac-sim/IsaacSim"
check_git_checkout "Isaac Lab" "${ISAACLAB_DIR:-}" "${ISAACLAB_REPO_REF:-develop}" "isaac-sim/IsaacLab"

echo ""
echo "==== Isaac Sim path/link ===="
printf 'ISAACSIM_INSTALL_MODE=%s\n' "${ISAACSIM_INSTALL_MODE:-}"
printf 'ISAACSIM_PATH=%s\n' "${ISAACSIM_PATH:-}"
printf 'ISAACSIM_PYTHON_EXE=%s\n' "${ISAACSIM_PYTHON_EXE:-}"
if [[ -e "$ISAACLAB_DIR/_isaac_sim" || -L "$ISAACLAB_DIR/_isaac_sim" ]]; then
  printf 'Isaac Lab _isaac_sim link target: %s\n' "$(readlink -f "$ISAACLAB_DIR/_isaac_sim" 2>/dev/null || true)"
else
  echo "WARN: $ISAACLAB_DIR/_isaac_sim does not exist. This is expected only for pip/skip Isaac Sim modes."
fi
if [[ "${ISAACSIM_INSTALL_MODE:-}" == "source" ]]; then
  if [[ "${ISAACSIM_REPO_REF:-}" != "develop" ]]; then
    echo "WARN: ISAACSIM_INSTALL_MODE=source but ISAACSIM_REPO_REF is not develop: ${ISAACSIM_REPO_REF:-}"
  fi
  if [[ -z "${ISAACSIM_PATH:-}" || ! -d "${ISAACSIM_PATH:-}" ]]; then
    echo "ERROR: ISAACSIM_PATH does not point to a built Isaac Sim directory." >&2
    failures=$((failures + 1))
  fi
fi

echo ""
echo "==== Python imports ===="
python - <<'PY'
import importlib
import importlib.metadata as md
import os
import sys

print("python", sys.version)
for key in ["ISAACSIM_INSTALL_MODE", "ISAACSIM_DIR", "ISAACSIM_PATH", "ISAACLAB_DIR", "LW_BENCHHUB_REPO_DIR"]:
    print(f"{key}={os.environ.get(key)}")
for name in ["isaaclab", "gymnasium", "lw_benchhub"]:
    mod = importlib.import_module(name)
    try:
        version = md.version(name.replace("_", "-"))
    except Exception:
        version = getattr(mod, "__version__", "unknown")
    print(f"{name}: version={version} file={getattr(mod, '__file__', None)}")
try:
    import isaacsim  # noqa: F401
    print("isaacsim: import ok")
except Exception as exc:
    print(f"isaacsim: import warning {exc!r}")
PY

echo ""
echo "The repro imports gymnasium as 'gym'. The checkpoint label is 'before/after gymnasium.make' so it is not confused with the old OpenAI Gym package."

if [[ "$failures" -gt 0 ]]; then
  echo ""
  echo "Verification finished with $failures hard failure(s)." >&2
  exit 1
fi

echo ""
echo "Verification finished. Review WARN lines if any exact commits/tags were intentional."
