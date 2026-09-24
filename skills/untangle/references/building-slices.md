# Building the slices

Only follow this after the user has accepted the plan and said yes to building. Never
modify the original branch. It's the reference every slice is checked against.

## Per slice, in stack order

1. Create a worktree and branch from the slice's base, which is the base branch or the
   previous slice's branch:
   `git worktree add ../<repo>-<slice> -b <slice-branch> <slice-base>`
2. Bring whole files over from the source branch:
   `git checkout <source-branch> -- <paths mapped only to this slice>`
3. For hunk-split files, edit by hand until the file holds only this slice's hunks.
   `git diff <slice-base> <source-branch> -- <file>` shows what's available.
4. Regenerate lockfiles and generated artifacts from this slice's own inputs. Don't
   copy the final versions.
5. Run the slice's **Verify** commands. Fix anything that fails *within the slice's scope*.
   If a fix needs code from a later slice, the plan is wrong. Stop and bring it back
   to the user rather than pulling that code forward quietly.
6. Commit in a few logical commits, as the plan says.

Slices that don't depend on each other can be built in parallel, one agent per
worktree, from the shared base, and rebased into stack order afterwards. Each agent
writes only in its own worktree.

## Final check: nothing lost, nothing invented

After the last slice is built:

```bash
git diff --stat <last-slice-branch> <source-branch>
```

This must be empty, apart from changes the user approved during the split, such as
fixes a slice needed. List each remaining difference for the user and explain it. For
sibling layouts, run the check on a scratch merge of all the leaves.

## Then

Report each slice: its branch, what it contains, its size, and its verify output. Ask
before pushing and before opening PRs. PRs are opened in stack order, each targeting
its base.
