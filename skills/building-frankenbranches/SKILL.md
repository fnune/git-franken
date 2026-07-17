---
name: building-frankenbranches
description: Build and maintain frankenbranches (disposable integration or combo branches) that merge several in-flight branches into one testable ref, using git-franken. Use when the user says "build a frankenbranch", wants branches combined into one ref for a test environment or CI, wants a frankenbranch or integration branch rebuilt after a branch moved, needs conflicts in one resolved, or mentions a franken/* branch or a franken manifest.
---

# Building frankenbranches

Combine several in-flight branches into one ref for a test environment, using
`git-franken`. The tool does the mechanical rebuild; you compose the manifest
and resolve conflicts it cannot.

## Mental model

**The manifest is durable. The branch is disposable output.**

`franken/<name>` holds nothing the manifest cannot regenerate. So never move,
preserve, or repair one. Delete it and rebuild.

Every build resets to trunk and re-merges from scratch. `git rerere` replays
previously resolved conflicts automatically, so rebuilds are usually silent.

## Commands

```sh
git franken new <name> [branch...]   # create a manifest
git franken list                     # manifests, and whether each is built
git franken show <name>              # contents + whether it is stale
git franken add <name> <branch>...   # add branches
git franken rm <name> <branch>...    # remove branches
git franken build <name>             # rebuild franken/<name> from scratch
git franken continue <name>          # resume after resolving a conflict
git franken drop <name>              # delete branch, keep manifest
git franken delete <name>            # delete both
git franken purge [--dry-run]        # remove every franken/* branch + manifests
git franken push <name> [remote]     # force-push the tip for CI
```

Manifests live in `$(git rev-parse --git-common-dir)/git-franken/<name>` and are
shared across worktrees. Never committed.

## Workflow

### Creating one

Identify the branches the user wants combined. If they describe them vaguely
("my auth work", "Bob's fix"), resolve to real branch names with
`git branch --list` or `gh pr view <n> --json headRefName` first, and confirm
the list before writing it.

```sh
git franken new staging feat/auth feat/billing
git franken build staging
```

### Rebuilding

Just rebuild. It is cheap and idempotent:

```sh
git franken build staging
```

Use `git franken show <name>` first to check whether a rebuild is even needed.
`STALE` means a tip moved; `MISSING` means a branch was deleted, so fix the
manifest with `git franken rm`.

### Resolving a conflict

`build` stops and names the unresolved files. This is where you add value:
read both sides, understand what each branch is doing, and resolve with that
context rather than mechanically picking a side.

```sh
# resolve the files, then:
git add <resolved files>
git franken continue staging
```

The resolution is cached by rerere. Future rebuilds replay it, so a resolution
is worth doing carefully once.

If a conflict looks wrong (e.g. two branches genuinely implement the same thing
two ways), say so rather than inventing a merge. That is a signal the user needs
to fix a real branch, not the frankenbranch.

### Branch checked out in another worktree

The tool refuses and says where. Do not fight it. Either:

```sh
git franken drop staging    # from the other worktree, then rebuild here
```

or build under a different name. Never `git worktree remove` someone's worktree
to free a branch.

### Cleaning up

`git franken purge` removes every `franken/*` branch and all manifests. Run
`git franken purge --dry-run` first and show the user the output before running
the real thing: it deletes branches, and they may have forgotten one exists.

Do not delete remote `franken/*` branches to "finish the cleanup". Something may
be deployed from one. That needs the user to ask for it explicitly.

Conflict resolutions cached during a build live in git's shared `rr-cache` and
are replayed in the user's ordinary rebases too. So resolve conflicts properly,
not with "make it compile" hacks.

## Rules

- **Never merge `franken/*` into trunk, and never open a PR from one.** It is a
  build artifact. The real branches get merged individually. If the user asks to
  merge one to main, stop and check what they actually want.
- **Never hand-edit a `franken/*` branch.** Any commit made directly on it is
  destroyed by the next rebuild. Fix the source branch instead.
- **`build` requires a clean worktree** and will refuse otherwise. Do not stash
  the user's work to get around this without asking.
- `push` force-pushes, which is correct here: rebuilt history is never
  fast-forward. Only push branches in the `franken/` namespace.

## Requirements

`git-franken` must be on `$PATH`. Check with `git franken help`, not
`git franken --help`: git intercepts `--help` on a subcommand and looks for a
man page instead of running it, so `--help` fails even when installed.
