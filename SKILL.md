---
name: gitdark
description: Version gitignored or untracked files - agent scratch, notes, plan/TODO files, private snapshots, weights sidecars, Windows binaries - in a private Git history without touching the primary repo's commits, tracked bytes, branch SHAs, index or remotes. Use when asked to commit the agent files, back up ignored working-tree files, keep a cloud/upstream repo byte-clean, or when .gitinclude, .gitdark, .archive or gitdarkive come up; covers the Linux exec-bit repair for the launchers and the ignore-vs-allowlist precedence rules.
---

# gitdark: three histories, one working tree

Checkout `~/Documents/Dev/repos/gitdark` (launchers symlinked into `~/.local/bin` by
`pathadder.sh`; keep the checkout in place or the links break). Needs Git and PowerShell 7
(`/usr/bin/pwsh`). Pure script - there is nothing to build.

| command | git dir | snapshot contents |
| --- | --- | --- |
| `git` | `.git` | ordinary history, never modified by the tools |
| `gitdark …` | `.gitdark` | exactly the literal paths listed in `.gitinclude` |
| `gitdarkive …` | `.archive` | every working-tree file, including ignored ones |
| `gitdarkive --no …` | `.archive` | tracked + non-ignored, like plain Git |

Each history has its own index, config, objects and HEAD. Nothing is renamed, no remotes are
inherited (author identity is copied once), and every invocation strips all `GIT_*`
env vars, so a private commit cannot leak into the primary index or object store.

## Daily loop

```sh
gitdark -C /repo include          # regenerate .gitinclude from Git's live ignore verdict
$EDITOR /repo/.gitinclude         # trim: it is the selection, and it is authoritative
gitdark -C /repo commit -m "chore(agent): snapshot scratch"
gitdark -C /repo log --oneline    # status / diff / show / branch / ls-files pass through to Git
```

`.gitinclude` is a JSON array of repository-relative **literal** file paths - no globs, no
implicit directories. `commit` stages the whole selected snapshot and prunes paths you
deleted from the list, so the private tree always equals `.gitinclude` ∩ existing files.

## Semantics that are easy to get wrong (all verified by probe, 2026-11-06)

- **`include` replaces your edits.** It re-lists every ignored+untracked file, so a big
  artifact you trimmed out silently comes back. Regenerate, then trim, then commit - in one
  breath. Real trap size: one 23.7 GB `.ninfer` weight file re-entered a 568-file list.
- **Live `.gitignore`, never the committed one.** Deleting a rule in the worktree (uncommitted,
  `HEAD:.gitignore` unchanged) drops those files from the allowlist immediately; restoring it
  puts them back. `HEAD:.gitignore` is never consulted.
- **`.git/info/exclude` is the weakest repo-local source, not an override.** Precedence is
  command-line excludes → per-directory `.gitignore` (deepest first) → `.git/info/exclude` →
  global `core.excludesFile`. A tracked root `.gitignore: *.ninfer` or a deeper
  `sub/.gitignore: p.log` beats any local exclude line, negation included. To defeat a tracked
  rule, edit the allowlist instead.
- **The allowlist outranks ignore state at commit time, in both directions.** A file the
  primary repo *tracks* is never auto-offered (`git ls-files --others`), yet listing it by hand
  puts it in the private tree; a directory hidden behind a committed `*` rule is still
  captured, because staging uses `add --force --all --pathspec-from-file`.
- **No `skip-worktree` / `--assume-unchanged` / `git rm --cached` games.** A tracked file that
  upstream later ignores stays tracked and clean in the primary while being versioned
  privately.
- **Refusals are deliberate:** nested repositories/submodules in the selection throw
  (run gitdark separately inside them); `.git .gitdark .archive .gittemp .gitinclude` are
  reserved and never snapshotted, so there is no recursion.
- A separate history is **not** encryption, and credentials love ignored files. Grep the text
  entries before the first commit; there is no remote, so nothing leaks until you add one.

## Keeping the cloud repo pristine

gitdark edits nothing versioned; the README leaves the residue to you (`?? .gitdark/`,
`?? .gitinclude`). Prefer the unversioned route so upstream updates cannot clobber your edit
and `git status` stays empty:

```sh
printf '/.gitdark/\n/.gitinclude\n/.archive/\n' >> /repo/.git/info/exclude
```

Confirm the deciding source is local, and that the primary is untouched:

```sh
git -C /repo check-ignore -v .gitdark .gitinclude        # -> .git/info/exclude:<line>
git -C /repo rev-parse HEAD; git -C /repo status --porcelain | grep -vc '^??'   # unchanged, 0
```

Untracked-but-*not*-ignored files (e.g. a sidecar manifest) never appear in `include` output;
add them to `.gitinclude` by hand - the validator only rejects absolute, `..`, empty-segment
and reserved paths.

## Linux install and the exec-bit trap

Fresh clones are fine (`git ls-tree` records `100755`), but a checkout copied from Windows
loses the bits while the clone's auto-set `core.filemode=false` hides the divergence, so
`~/.local/bin/gitdark` answers `Permission denied`. Repair from the recorded mode - no
commit, no history change:

```sh
git -c core.filemode=true checkout -- gitdark gitdarkive pathadder.sh   # in the gitdark repo
bash pathadder.sh                                                       # relinks if needed
```

## Verify

`pwsh -NoProfile -File tests/smoke.ps1` in the checkout must print
`PASS: 41 checks` (disposable repos, never pushes). Then prove isolation on the target repo:
the private commit's SHA must be unresolvable in the primary object store
(`git cat-file -e <darksha>` fails) and `git -C /repo status --porcelain` must list no
modifications. Retrieval is byte-exact: `gitdark -C /repo show HEAD:<path> | cmp - <path>`.
