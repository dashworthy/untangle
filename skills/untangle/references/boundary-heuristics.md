# Boundary heuristics

Check each candidate cut against these before proposing it. Every trap below is a way a
slice looks independent by file name but isn't by code.

## Contents
- Traps that break a slice
- Shared files that need hunk-level splitting
- Keeping an earlier slice working without a later one
- Signs a cut is good
- When not to split

## Traps that break a slice

- **Inheritance and interfaces.** A subclass ships with or after its parent. A class
  "about" the library can still extend a base class the feature introduces. If so, it
  belongs with the feature, not the library.
- **Tooling that arrives with the branch.** Check whether the base has the test runner,
  config, fixtures and helpers that the slice's tests use (for example `vitest.config.*`,
  a `jest` or `phpunit` config, a new test helper, factories). If not, that setup goes
  into the first slice whose tests need it, usually as its own first commit.
- **Dependencies.** A new package in the manifest goes with the first slice that
  imports it. Don't hand-split lockfiles. Regenerate them in each slice from that
  slice's manifest.
- **Schema order.** Migrations that add foreign keys need the referenced table in the
  same slice or an earlier one. Each slice's migrations must run forward and roll back
  on their own.
- **Registration points.** Service providers, DI containers, route files, event
  listener maps, scheduler or cron entries, permission seeders and feature registries
  must not register a class the slice doesn't contain.
- **String references.** Config lists, dynamic imports, `importlib`, container keys and
  event names refer to a class by string, so no import shows the link. A config entry
  ships with the code it names. When one config edit mixes entries for several slices,
  the file needs a hunk split.
- **Shared test setup.** Test setup shared across the suite (`conftest.py`, `setup.ts`,
  base test cases, factories) is loaded by *every* test. One top-level import of
  later-slice code breaks the whole suite for the earlier slice, so split its hunks.
- **Generated artifacts.** Generated API clients, type files, SDKs and snapshots have
  to match the slice's code. Regenerate them per slice. Don't copy them from the
  final branch.
- **Scheduled and background entry points.** A cron entry or queue listener that ships
  before its handler is complete runs half-built code in production.
- **Changed signatures.** If the branch changes an existing function's signature or a
  shared type, every caller the change touches ships in the same slice.

## Shared files that need hunk-level splitting

Route files, translation files, permission lists, navigation config, type barrels
(`index.ts`), `CHANGELOG`s and config files often collect edits for several slices.
Mark them in `split-map.tsv` with every slice that gets hunks (for example `2,4`), and in
the plan say which hunks go where.

## Keeping an earlier slice working without a later one

When a user-proposed cut takes something the MVP used, say what the earlier slice does
in the meantime, and get agreement:

- **Degrade:** the feature handles only the supported case. For example, it exports
  tables, and chart widgets are skipped until the chart slice lands.
- **Hide:** the route, UI or command exists but isn't linked, or sits behind a feature
  flag that already exists in the codebase. Don't invent a flag system.
- **Unused but tested:** a library with no callers yet is fine if its own tests cover it.

Never stub with fake behavior that a user could reach.

## Signs a cut is good

- The earlier side has a demo or a test that passes without the later side.
- The reviewer of the later side doesn't need to re-read the earlier side's internals,
  only its public surface.
- Few shared files need hunk splits across the cut.
- It matches a capability someone would name out loud, like "the search index"
  or "the history page". A name like "the models" doesn't count.

## When not to split

- The diff is small, or reviewable in one sitting and cohesive.
- Every candidate cut needs heavy degrade or hide scaffolding, so the split would cost
  more review than it saves.
- Most of the diff is one tightly coupled change, such as a rename across the codebase
  or a signature change with all its callers.

Say so plainly, and offer the one or two cuts that are still clean, if any.
