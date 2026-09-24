#!/usr/bin/env python3
"""Check that split-map.tsv assigns every changed file in a diff to at least one slice.

Usage: check_coverage.py split-map.tsv --base <merge-base-or-ref> --head <branch> [--repo DIR]

Exit 0 when every changed path is mapped exactly once and every mapped path is in the
diff; exit 1 otherwise, listing each problem.
"""
import argparse
import subprocess
import sys


def changed_paths(repo, base, head):
    out = subprocess.run(
        ["git", "-C", repo, "diff", "--name-status", "-M", base, head],
        check=True, capture_output=True, text=True,
    ).stdout
    paths = set()
    for line in out.splitlines():
        parts = line.split("\t")
        status = parts[0]
        # Renames/copies list old and new; the new path is the one that ships.
        paths.add(parts[2] if status[0] in "RC" else parts[1])
    return paths


def read_map(path):
    mapping, problems = {}, []
    with open(path) as fh:
        for n, raw in enumerate(fh, 1):
            line = raw.rstrip("\n")
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            parts = line.split("\t")
            if len(parts) != 2 or not parts[1].strip():
                problems.append(f"line {n}: expected '<path>\\t<slices>', got {line!r}")
                continue
            file_path, slices = parts[0].strip(), parts[1].strip()
            if not all(s.strip().isdigit() for s in slices.split(",")):
                problems.append(f"line {n}: slices must be numbers like '2' or '1,3', got {slices!r}")
                continue
            if file_path in mapping:
                problems.append(f"line {n}: {file_path} mapped twice")
            mapping[file_path] = sorted({int(s) for s in slices.split(",")})
    return mapping, problems


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("map")
    ap.add_argument("--base", required=True)
    ap.add_argument("--head", required=True)
    ap.add_argument("--repo", default=".")
    args = ap.parse_args()

    diff = changed_paths(args.repo, args.base, args.head)
    mapping, problems = read_map(args.map)

    for p in sorted(diff - mapping.keys()):
        problems.append(f"unmapped (would never ship): {p}")
    for p in sorted(mapping.keys() - diff):
        problems.append(f"mapped but not in diff: {p}")

    if problems:
        print("\n".join(problems))
        print(f"\nFAIL: {len(problems)} problem(s); {len(diff)} changed paths, {len(mapping)} mapped.")
        return 1

    by_slice = {}
    for p, slices in mapping.items():
        for s in slices:
            by_slice.setdefault(s, []).append(p)
    split = [p for p, s in mapping.items() if len(s) > 1]
    print(f"OK: all {len(diff)} changed paths mapped.")
    for s in sorted(by_slice):
        print(f"  slice {s}: {len(by_slice[s])} files")
    if split:
        print(f"  hunk-split across slices: {', '.join(sorted(split))}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
