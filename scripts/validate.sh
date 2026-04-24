#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

log() { echo "[validate] $*"; }
die() { echo "[validate] ERROR: $*" >&2; exit 1; }

cd "${REPO_DIR}"

log "Checking shell script syntax"
mapfile -t shell_scripts < <(find scripts -maxdepth 1 -type f -name '*.sh' | sort)
[[ ${#shell_scripts[@]} -gt 0 ]] || die "no shell scripts found in scripts/"
bash -n "${shell_scripts[@]}"

log "Checking JSON files"
python3 - <<'PY'
import json
from pathlib import Path

repo = Path(".")
for path in [
    repo / "openclaw.json",
    repo / "config" / "cron" / "jobs.json",
    repo / "config" / "periods.json",
]:
    with path.open() as fh:
        json.load(fh)
    print(f"ok {path}")
PY

log "Checking config linkage"
python3 - <<'PY'
import json
import sys
from pathlib import Path

repo = Path(".")
openclaw = json.loads((repo / "openclaw.json").read_text())
cron = json.loads((repo / "config" / "cron" / "jobs.json").read_text())

image = openclaw["agents"]["defaults"]["sandbox"]["image"]
if image != "fingent-sandbox:latest":
    raise SystemExit(f"unexpected sandbox image: {image}")

for skill_path in openclaw["skills"]:
    resolved = (repo / skill_path).resolve()
    if not resolved.exists():
        raise SystemExit(f"missing skill file: {skill_path}")

job_skill_ids = {job["skill"] for job in cron["jobs"]}
registered_skill_ids = {
    Path(path).parent.name
    for path in openclaw["skills"]
}
missing = sorted(job_skill_ids - registered_skill_ids)
if missing:
    raise SystemExit(f"cron jobs reference missing skills: {', '.join(missing)}")

for required_dir in [
    repo / "archive" / "posted",
    repo / "archive" / "duplicates",
    repo / "archive" / "errors",
    repo / "processing",
    repo / "reports",
]:
    if not required_dir.exists():
        raise SystemExit(f"missing directory: {required_dir}")

print("config linkage ok")
PY

log "Checking Docker sandbox references"
grep -q 'COPY requirements-sandbox.txt' docker/Dockerfile || die "Dockerfile must copy requirements-sandbox.txt"
grep -q 'ENTRYPOINT \["/bin/bash"\]' docker/Dockerfile || die "Dockerfile entrypoint missing"

log "All checks passed"
