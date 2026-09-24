# split-plan.md template

Fill in every section. The plan has to be enough for someone else, or a fresh agent, to
build the stack without the conversation that produced it.

```markdown
# Split of <PR/branch> into <N> PRs

Decided <date>. Base: `<base>` @ `<merge-base sha>`. Source branch: `<branch>` @ `<head sha>`.
Stack: <base> → <slice 1> → <slice 2> → … (or the sibling layout, if any).
Original PR: <kept as reference, closed once stack is up | rewritten as slice K>.
Commits: <few fresh logical commits per slice | cherry-picked>.

## Slices

### 1. <name>: `<branch-name>` (base `<base>`)
- **Contains:** <capabilities, with key files/dirs>
- **Shared-file hunks:** <file>: <which hunks>  (omit if none)
- **Works without later slices because:** <degrade/hide/unused-but-tested/self-contained>
- **Approx. size:** <changed lines, excl. lockfiles/generated>
- **Verify:** <exact test/lint/typecheck/build commands for this repo>
- **Dry-build result:** <each check → pass / fail at tip too / not run (why)>

### 2. …

## Decisions
- <each boundary accepted, each rejected (and what merged), each user-proposed move, the order and why>

## Forced moves
- <file/class> goes in slice K, not J, because <dependency>.

## Problems in the branch itself
Defects that exist whatever the split: found while reading, or failing at the branch tip.
- `<file>:<line>`: <what's wrong, how it shows up> → suggested fix; lands in slice K.
(Write "None found" if there are none. Don't drop the section.)
```

## split-map.tsv

One line per changed path: `<path><TAB><slice numbers>`. List several comma-separated
slices when the file's hunks are split across them. Lines starting with `#` are
comments. Use the new path for renames and the old path for deletions.

```
# path	slices
package.json	1,3
src/lib/currency/convert.ts	2
src/routes.ts	2,3
```
