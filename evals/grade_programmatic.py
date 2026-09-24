#!/usr/bin/env python3
"""Grade the mechanical expectations of one skill-creator run of an untangle eval.

Usage: grade_programmatic.py <run-dir> <base> <head>

<run-dir> holds repo/ (the fixture the agent worked in) and branches-before.txt
(captured right after scaffolding). Prints a JSON list of {text, passed, evidence}.
The judgment-based expectations (trap placement, base choice, one-PR recommendation)
are graded by reading the plan, not here.
"""
import json
import pathlib
import subprocess
import sys

CHECKER = pathlib.Path(__file__).resolve().parent.parent / "skills/untangle/scripts/check_coverage.py"


def git(repo, *args):
    return subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True).stdout


def main():
    run, base, head = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3]
    repo = run / "repo"
    results = []

    plan = repo / "split-plan.md"
    results.append({"text": "split-plan.md exists in the repo root", "passed": plan.exists(),
                    "evidence": f"{plan} {'found' if plan.exists() else 'missing'}"})

    q = repo / "questions.jsonl"
    multi = False
    if q.exists():
        for line in q.read_text().splitlines():
            try:
                payload = json.loads(line)
            except json.JSONDecodeError:
                continue
            if any(x.get("multiSelect") for x in payload.get("questions", [])):
                multi = True
    results.append({"text": "questions.jsonl contains a question with multiSelect true whose options are split boundaries",
                    "passed": multi,
                    "evidence": "multi-select question found" if multi else ("no multi-select question" if q.exists() else "questions.jsonl missing")})

    tsv = repo / "split-map.tsv"
    if tsv.exists():
        cov = subprocess.run([sys.executable, str(CHECKER), str(tsv), "--base", git(repo, "merge-base", base, head).strip(),
                              "--head", head, "--repo", str(repo)], capture_output=True, text=True)
        results.append({"text": "split-map.tsv passes check_coverage.py (every changed file mapped)",
                        "passed": cov.returncode == 0, "evidence": (cov.stdout + cov.stderr).strip()[-600:]})
    else:
        results.append({"text": "split-map.tsv passes check_coverage.py (every changed file mapped)",
                        "passed": False, "evidence": "split-map.tsv missing"})

    before = set((run / "branches-before.txt").read_text().split())
    after = set(git(repo, "for-each-ref", "--format=%(refname:short)", "refs/heads").split())
    worktrees = [l for l in git(repo, "worktree", "list").splitlines() if l.strip()]
    ok = after == before and len(worktrees) == 1
    results.append({"text": "No branches, worktrees or pushes were created", "passed": ok,
                    "evidence": f"new branches: {sorted(after - before) or 'none'}; worktrees: {len(worktrees)}"})

    print(json.dumps(results, indent=2))


if __name__ == "__main__":
    main()
