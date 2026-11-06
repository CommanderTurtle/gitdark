# gitdark

Three Git histories, one working tree. A small PowerShell wrapper around your
installed Git, not a modified Git build. Requires Git and PowerShell 7 (`pwsh`).

```sh
gitdark include                 # Generate .gitinclude from currently ignored files
# Review/edit .gitinclude before the first private commit.
gitdark commit -m "private files"
gitdark log --oneline

gitdarkive commit -m "complete snapshot"
gitdarkive --no commit -m "without ignored files"
```

| Command | History | Commit contents |
| --- | --- | --- |
| `git` | `.git` | Unchanged; ordinary Git |
| `gitdark` | `.gitdark` | Literal file paths in `.gitinclude` |
| `gitdarkive` | `.archive` | All working-tree files |
| `gitdarkive --no` | `.archive` | Tracked + nonignored files, like normal Git |

`gitdark gitdarkive …` is another spelling of `gitdarkive …`. Use `-C /repo/path`
before the command to select another repository. Run inside an existing Git repo.

`.gitinclude` is an editable JSON array of repository-relative file paths. No globs
or implicit directory includes. Generation uses Git's actual ignore rules,
including nested/global ignores and `.git/info/exclude`. It is generated on the
first dark add/commit if absent. Run `gitdark include` again to regenerate it;
that explicitly replaces your edits. New files are not silently added to the list.

`commit` stages the selected snapshot, including removals, then runs real Git.
`add [literal paths…]` is optional; it stages a selected subset, but a subsequent
`commit` still takes the full selected snapshot. Other subcommands/arguments go
to Git: `status`, `diff`, `log`, `branch`, `restore`, `remote`, `push`, etc.
Subdirectory-relative Git arguments work normally. Interactive staging is not
provided. A snapshot refuses nested
repository/submodule entries rather than creating incomplete backups; run
separately inside them.

The histories have separate indexes/configs/objects. Native `--git-dir` and
`--work-tree` select them; **nothing is renamed**. Your primary HEAD, index,
configuration and ignore files are untouched. Alternate histories inherit the
initial author identity, not remotes. Untracked-file noise is hidden in their
status; use `.gitinclude` or `add` to inspect/stage the selection. All Git metadata
and `.gitinclude` are excluded from alternate snapshots to prevent recursion.

Add these yourself to the ordinary `.gitignore` if wanted:

```gitignore
/.gitdark/
/.gitinclude
/.archive/
```

Ignored files often contain credentials. **A separate history is not encryption**;
review the allowlist and configure alternate remotes deliberately before pushing.
Git commands that restore/checkout files still change the shared working tree.
`--no` applies to that archive command; it does not create a fourth history.

## PATH

```powershell
pwsh -File ./pathadder.ps1
```

On Windows this adds this checkout to your user PATH (no admin). Reopen other
terminals. `.cmd` launchers also work from Command Prompt.
On Linux/macOS the PowerShell helper creates the same links as the shell helper.

```sh
bash pathadder.sh
```

On Linux/macOS this creates non-overwriting links in `~/.local/bin` (or
`XDG_BIN_HOME`). Keep the checkout in place and put that directory on PATH.

Tests: `pwsh -NoProfile -File tests/smoke.ps1`. They use disposable repositories,
not your working repositories, and never push.

Git interfaces used: [separate Git directory/worktree](https://git-scm.com/docs/git),
[ignore-aware listing](https://git-scm.com/docs/git-ls-files),
[literal NUL-delimited staging](https://git-scm.com/docs/git-add).

## Skill, for Agents

To refresh the installed copy after you edit the repo's version:

```bash
cp gitdark/SKILL.md ~/.omp/agent/skills/gitdark/SKILL.md. 
```

(Oh-My-Pi Example)
