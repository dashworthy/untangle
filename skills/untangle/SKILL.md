---
name: untangle
description: Untangle an oversized pull request or feature branch, usually one generated from a big spec or plan, into a stack of smaller PRs that each ship on their own without breaking existing functionality. It maps what depends on what in the diff, proposes cut lines as a multi-select question the user accepts or rejects, settles the order, writes a split plan with a file map, and then offers to build the stacked branches. Use when a PR or branch is too big to review, or when someone asks to split, break up, carve up, chunk, slice or stack a PR, or says a ticket "exploded" in size. Use it even if they only ask where the natural seams are.
---

# Untangle

Turn one mega diff into an ordered stack of PRs. Each PR must leave the base branch
working when it merges: it builds, its tests pass, nothing it adds points at code that
only arrives in a later PR, and no user can reach a half-finished feature.

The user decides where the cuts go. You find and justify candidate cuts, and they accept
or reject each one.

## Workflow

Copy this checklist and tick it off as you go:

```
- [ ] 1. Pin the change and its base
- [ ] 2. Inventory the diff and map dependencies
- [ ] 3. Draft slices and the boundaries between them
- [ ] 4. Ask: accept/reject each boundary (multi-select)
- [ ] 5. Reconcile rejections and user-proposed cuts; re-ask only what changed
- [ ] 6. Settle order and re-derive what the order forces to move
- [ ] 7. Dry-build each slice in scratch and run its checks; fix the plan until green
- [ ] 8. Ask the execution questions
- [ ] 9. Write split-plan.md + split-map.tsv, run check_coverage.py until clean
- [ ] 10. Offer to build the stack
```

### 1. Pin the change and its base

Find the branch or PR under review. **Find out what the base is. Don't assume `main`.** Check the
PR's target (`gh pr view <n> --json baseRefName`), then look for `develop`, `dev` or `staging`
next to `main`. If it's still unclear, ask. Every slice is cut from this base, so a wrong base
invalidates the whole plan. Record the merge-base SHA.

If the branch has uncommitted work, say so. Ask before committing it, because the slices are
built from the branch's final state.

### 2. Inventory and dependency map

List every changed file with its status and size:

```bash
MB=$(git merge-base origin/<base> <branch>)
git diff --name-status $MB <branch>
git diff --numstat $MB <branch>
```

For each new or changed unit, record what it needs from the rest of the diff:
imports, parent classes and interfaces, foreign keys and migration order, routes,
config keys, permissions, translations, new packages, and test tooling. **Read the
code for this, not just the file names.** The splits that break are the ones where a
file's name puts it in one group while its dependencies put it in another. Imports
don't show every dependency. Also grep for each new module's name as a *string*, to
catch config-driven registries and dynamic imports. For every changed signature, grep
for all of its callers, including ones in files that look unrelated. For the traps to
check, see [references/boundary-heuristics.md](references/boundary-heuristics.md).

Reading this closely will turn up defects in the branch itself, such as a wrong
formula, a migration that can fail on real data, or an unhandled null. Note each one
with its file and line for the plan's "Problems in the branch itself" section. Keep
them separate from the split: they're true whatever the cut lines are.

### 3. Draft slices

Group by **capability**, not by layer. "Migrations PR, then models PR, then UI PR" produces
PRs that can't be tested or reviewed on their own. The default shape, earliest first:

1. **Tooling the later slices need:** a test runner, a build config, a new dependency.
   It ships alone only if it's large. Otherwise it's the first commit of the first slice
   that needs it.
2. **Generic capabilities the feature uses but that don't know about the feature:** a
   library, a search index, a shared UI component.
3. **The MVP:** the smallest end-to-end path of the feature that works.
4. **Follow-ups:** history and detail views, secondary actions, extra formats.
5. **Entry points:** navigation links and menu items. They ship with the functionality
   they expose, never before it.

Changes to *existing* behavior carry the most review risk. Keep them in their own slice
when their dependencies allow it.

For each slice, note its approximate changed lines, excluding lockfiles and generated
files. Aim for slices a reviewer can read in one sitting, roughly 300–1,500 lines. That's
a guide, not a rule: cohesion matters more than size. If the whole diff is small and
cohesive, say that one PR is fine and stop. Don't manufacture cuts.

### 4. Ask about the boundaries

First show the proposed stack as a short numbered list, one line per slice. Then ask
with `AskUserQuestion`:

- **One multi-select question listing the boundaries.** Each option is one cut between
  two adjacent slices, labelled with both sides, e.g. `Audit log | Reservations`. Its
  description says what lands on each side, the rough size of each side, and why the
  cut is safe, meaning what keeps the earlier side working without the later one.
- A checked option means the cut is accepted. An unchecked option is rejected, and the
  slices on either side of it merge.
- Each question takes 2–4 options. For more than four boundaries, continue in
  additional questions ("Boundaries 5–8"). For exactly one boundary, ask a single-select
  question instead: accept the cut, or keep it as one PR.
- In the question text, tell the user they can type new cuts or moves under "Other".

### 5. Reconcile

Merge the slices around each rejected cut. Treat any cut or move the user types in as a
new proposal. Check its dependencies the way you checked your own, and state what it
forces. For example: "a separate chart slice means the MVP has to work without charts,
so it exports tables only until that slice lands." Put only the new or changed
boundaries to the user again. Repeat until every boundary is accepted.

### 6. Order

Propose the order that the dependency map implies. If the user wants a different order,
re-derive which files move because of it and name each one. For example: "with the
library before the MVP, `FooExporter` has to move into the MVP slice, because it extends
`BaseExporter`, which the MVP introduces." Also choose a linear stack or sibling
branches: two slices that don't depend on each other can both sit on a shared parent
and land in either order.

### 7. Dry-build every slice

Reading the code gets most dependencies. Running it gets the rest. Before you write
the plan, prove each slice stands on its own:

1. Find the repo's checks in its CI config, `package.json` scripts, `Makefile`,
   `composer.json` or `pyproject.toml`: typecheck, lint, tests, build.
2. Run them once on the branch tip. Anything that already fails there is a
   problem in the branch itself, not something the split caused. Record it and don't
   count it against a slice.
3. For each slice in stack order, build a cumulative snapshot, meaning base plus slices
   1..N, in a scratch directory outside the repo. Don't use branches or worktrees, and
   leave the repo's index and HEAD alone:
   ```bash
   mkdir -p "$SCRATCH/slice-N" && git archive <merge-base> | tar -x -C "$SCRATCH/slice-N"
   git diff <merge-base> <branch> -- <paths in slices 1..N> | (cd "$SCRATCH/slice-N" && git apply)
   ```
   Then trim each hunk-split file down to the hunks that belong to slices 1..N.
4. Run the checks in the snapshot. A failure that doesn't happen at the tip means the
   plan is wrong. Move the file or hunk it names, update the dependency map, and
   rebuild from the first slice that changed. If a boundary the user accepted no longer
   holds, put that boundary to them again with the evidence.

If a check can't run because a toolchain or dependency is missing, say which check and
why, then fall back to the closest thing that does run, such as a syntax or compile
check. Don't install toolchains or change anything outside the scratch directory, including
`~/.local/bin`, shell profiles and global package caches, unless the user says yes first.
Never report a slice as verified when it wasn't.

### 8. Execution questions

Ask these together, recommended option first:

- **The original PR:** keep it untouched as the reference and close it once the stack
  is up (recommended), or rewrite it into one of the slices, which needs a force-push
  and leaves its review threads pointing at code that has moved.
- **Commit history:** a few fresh logical commits per slice, taken from the branch's
  final code (recommended), or cherry-picking the original commits. Cherry-picking
  breaks down when commits touch files that end up in different slices.

### 9. Write the plan, then validate it

Write `split-plan.md` using [references/split-plan-template.md](references/split-plan-template.md),
and write `split-map.tsv` next to it. Put both in the project's working-notes directory if
it has one, otherwise in the repo root, and don't commit them. Then run:

```bash
python3 <skill-dir>/scripts/check_coverage.py split-map.tsv --base <merge-base> --head <branch>
```

It fails on any changed file that isn't mapped to a slice, and on any mapping to a file
that isn't in the diff. Fix the map and run it again until it passes. A file the plan
misses is code that silently never ships.

### 10. Offer the build

End by offering to build the stack. If the user accepts, follow
[references/building-slices.md](references/building-slices.md). Never push, open PRs or
force-push without an explicit yes.
