# Claude Code Guardrails

Defense-in-depth protection against destructive `rm` and `git` operations
when working with [Claude Code](https://docs.claude.com/en/docs/claude-code).

> **Why this exists:** Claude Code's `permissions.ask` rule for `Bash(rm:*)`
> does *not* fire when the session runs with sandbox auto-allow or in any
> non-default permission mode. Real, irrecoverable losses can occur. This
> repo provides a two-layer fix that blocks regardless of mode.

[Deutsche Version](./README.de.md)

---

## TL;DR

Two layers:

1. **`permissions.deny` rule** in your project's `.claude/settings.json`
   — `deny` always wins, in every mode, including sandbox bypass.
2. **PreToolUse hook** at `~/.claude/hooks/block-destructive.sh` — regex-
   based, robust against argument-ordering edge cases that fragile glob
   patterns miss.

Plus a **methodology doc** ([`workflow/WORKFLOW.md`](./workflow/WORKFLOW.md))
showing how the protection was developed empirically — adapt the same
pattern to add your own guardrails.

---

## What gets blocked

| Class | Mechanism | Notes |
|---|---|---|
| `rm` (any form) | `permissions.deny` | Works in every permission mode, including sandbox auto-allow |
| `rm -r` / `-rf` / `--force` (also via pipes, `xargs`, subshells, chains) | Hook + deny | Defense in depth |
| `git rm` (any form, with or without flags) | Hook | Closes the `git rm <file>` gap |
| `git restore <file>` (without `--staged`) | Hook | Discards uncommitted changes — no reflog recovery |
| `git checkout … -- <file>` | Hook | Same destructive class as above |
| `git clean -f/-x/-d` | Hook | |
| `git reset --hard` | Hook | |
| `git push … --force` | Hook | Long form only — `-f` short form NOT caught |
| `git branch -D` | Hook | |
| `find … -delete` / `find … -exec rm` | Hook | |
| `rsync --delete` / `--delete-after` / `--delete-before` | Hook | |
| `DROP TABLE/DATABASE/SCHEMA`, `TRUNCATE TABLE` | Hook | |
| `docker {system,volume,image,container,network} prune --force`, `docker rm -f`, `docker volume rm` | Hook | |
| `mkfs.*`, `dd … of=/dev/sd…`, `> /dev/sd…`, `shred`, `trash` | Hook | |
| Writes to protected paths (`design-source/`, `vendor/`, `_archive/` etc.) | Hook | Per-project list, customize |
| Mass reads (`ls -R`, `find .` without filter, `rg/grep` without path, `tree`, `cat *.md`) | Hook | Forces explicit scope |

## What is NOT blocked (accepted trade-offs)

- `git restore --staged <file>` — not destructive, only unstages
- `git checkout <branch>` (branch switch without `--`) — git aborts on dirty tree by itself
- `git checkout HEAD <file>` (old syntax without `--`) — rarely used
- `git stash drop` / `git stash clear`
- `git push -f` (short form — only `--force` is caught)
- `git filter-branch`, `git update-ref -d`, `git reflog expire`
- `git commit --amend` after push
- `mv`/`cp` overwriting an existing target

---

## Installation

### 1. Install the hook (user-level, applies to all projects)

```bash
mkdir -p ~/.claude/hooks
curl -fsSL https://raw.githubusercontent.com/web-werkstatt/claude-code-guardrails/main/hooks/block-destructive.sh \
  -o ~/.claude/hooks/block-destructive.sh
chmod +x ~/.claude/hooks/block-destructive.sh
```

Or clone and copy:

```bash
git clone https://github.com/web-werkstatt/claude-code-guardrails.git
cp claude-code-guardrails/hooks/block-destructive.sh ~/.claude/hooks/
chmod +x ~/.claude/hooks/block-destructive.sh
```

### 2. Register the hook in user settings

Merge [`settings/settings-user.example.json`](./settings/settings-user.example.json)
into your `~/.claude/settings.json` (preserve existing fields):

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "$HOME/.claude/hooks/block-destructive.sh"
          }
        ]
      }
    ]
  }
}
```

### 3. Add the deny rule per project

Merge [`settings/settings-project.example.json`](./settings/settings-project.example.json)
into your `<project>/.claude/settings.json`:

```json
{
  "permissions": {
    "ask": ["Bash(rm:*)"],
    "deny": ["Bash(rm:*)"]
  }
}
```

The `ask` entry is a backup — if `deny` is ever removed, `ask` still fires
in default permission mode. When both are present, `deny` wins.

### 4. Customize protected paths

Edit `PROTECTED_PATHS` in `block-destructive.sh` (around line 186) for
your project. Default examples (`design-source/`, `vendor/`, `_archive/`,
etc.) are placeholders — replace with paths relevant to your codebase.

### 5. Verify (in a throwaway directory)

```bash
mkdir -p /tmp/guardrails-test && cd /tmp/guardrails-test
git init -q
echo "test" > file.txt
git add file.txt && git commit -q -m "init"

# Test 1: rm must block
rm file.txt
# expected: "Permission to use Bash with command rm ... has been denied."

# Test 2: git rm must block
git rm file.txt
# expected: hook output "BLOCKED — destructive command detected"

# Test 3: git restore (destructive) must block
echo "modified" >> file.txt
git restore file.txt
# expected: hook output "BLOCKED — git restore discards uncommitted changes"

# Test 4: git restore --staged (NOT destructive) must pass
git add file.txt
git restore --staged file.txt
# expected: passes through, stage cleared, modification preserved
```

---

## Why two layers?

| Layer | Strengths | Weaknesses |
|---|---|---|
| `permissions.deny` | Works in *every* mode incl. sandbox bypass; simple to maintain | Only glob patterns; fragile against argument-order variations |
| PreToolUse hook | Full regex; can inspect context (heredoc stripping, mass-read detection) | Disabled if `allowManagedHooksOnly` is set in enterprise-managed settings |

`deny` alone is not enough for `git rm`, because the docs explicitly warn
that argument-constraining patterns like `Bash(git push --force *)` break
on `git push origin --force main` (different argument order). Hook regex
is more robust.

Hook alone is not enough for `rm`, because a config change or hook bug
could disable it. The `deny` rule is an independent second line.

---

## Empirically verified (2026-04-27, Claude Code 2.1.119)

- `Bash(rm:*)` in `permissions.ask` does **not** fire when sandbox
  auto-allow for Bash is active. `permissions.deny` fires regardless —
  hence the two-layer setup.
- Settings changes are hot-reloaded; no session restart required.
- Compound commands (`&&`, `;`, `|`) are split into subcommands and each
  is evaluated against permission rules independently.
- `xargs <cmd>` is stripped to `<cmd>` before matching, so `Bash(rm:*)`
  deny also catches `xargs rm` from pipes.
- `permissions.deny` takes precedence over `permissions.allow` at any
  scope — managed > local project > project > user.

See [`workflow/WORKFLOW.md`](./workflow/WORKFLOW.md) for the full
investigative path that produced these findings — adapt the same
methodology to verify other guardrails.

---

## Known false positives

- Bash inline strings like `echo "git rm test"` trigger the hook
  (substring match). Heredocs are correctly stripped, inline strings are
  not. Acceptable trade-off.
- `mv`/`cp` overwriting an existing target is not blocked. If relevant,
  alias `mv='mv -i'` in your shell config or extend the hook.

---

## License

MIT — see [LICENSE](./LICENSE).

## Sources

- [Configure permissions](https://code.claude.com/docs/en/permissions)
- [Settings precedence](https://code.claude.com/docs/en/settings)
- [Hook behavior](https://code.claude.com/docs/en/hooks)
