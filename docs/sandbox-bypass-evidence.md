# Evidence: `permissions.ask` is bypassed by sandbox auto-allow

This document is the empirical and documentary basis for why this repo
uses `permissions.deny` instead of `permissions.ask` as its primary
defense for `Bash(rm:*)`.

Verified on **Claude Code 2.1.119, 2026-04-27**.

## The documentation says it directly

From the official permissions reference at
<https://code.claude.com/docs/en/permissions> ("Tool-specific permission
rules" → "Bash" subsection):

> When sandboxing is enabled with `autoAllowBashIfSandboxed: true`,
> which is the default, sandboxed Bash commands run without prompting
> **even if your permissions include `ask: Bash(*)`**. The sandbox
> boundary substitutes for the per-command prompt. Explicit deny rules
> still apply, and `rm` or `rmdir` commands that target `/`, your home
> directory, or other critical system paths still trigger a prompt.

Two consequences:

1. `Bash(rm:*)` in `permissions.ask` does *not* fire for typical project
   paths. Only system-critical targets (`/`, `$HOME`) still prompt.
2. `permissions.deny` is unaffected by this bypass — it always applies.

## Live reproduction

### Setup

Project `.claude/settings.json` configured as:

```json
{
  "permissions": {
    "ask": ["Bash(rm:*)"]
  }
}
```

No other `Bash(rm:*)` rule anywhere. No `defaultMode` override. No
managed settings. No `--dangerously-skip-permissions` flag. Verified by
inspecting all four settings files in the precedence chain plus the
`gh auth status` and environment.

### Test 1 — non-existent target

```bash
$ rm /tmp/permission-prompt-test-does-not-exist-xyz123.txt
rm: cannot remove '/tmp/permission-prompt-test-does-not-exist-xyz123.txt':
    No such file or directory
```

No prompt. Exit code 1 came from `rm` itself (file missing), not from
the permission system.

### Test 2 — existing target

```bash
$ mkdir -p /mnt/projects/tests/rm-permission-test
$ touch /mnt/projects/tests/rm-permission-test/dummy.txt

$ rm /mnt/projects/tests/rm-permission-test/dummy.txt
$ ls /mnt/projects/tests/rm-permission-test/
# (empty — file deleted, no prompt)
```

The file was deleted with no prompt. The `ask` rule did not engage.

### Test 3 — fix verification

After adding `Bash(rm:*)` to `permissions.deny` (same project file):

```bash
$ rm /mnt/projects/tests/rm-permission-test/dummy2.txt
Permission to use Bash with command rm
/mnt/projects/tests/rm-permission-test/dummy2.txt; ... has been denied.
```

Hard block. No prompt either — but the action did not execute. This
confirms `deny` is unaffected by the bypass that disables `ask`.

## Combined-command coverage (verified)

The bypass affects `ask`, but `deny` plus the documented compound-
command behavior catch every realistic destructive variant:

| Variant | Result |
|---|---|
| `rm <file>` | denied |
| `echo <file> \| xargs rm` | denied (xargs stripped to `rm`) |
| `rm $(echo <file>)` | denied (substitution evaluated as `rm`) |
| `git status && rm <file>` | denied (subcommand split on `&&`) |

## What this means for users

If you currently rely on `permissions.ask` for `Bash(rm:*)` (or any
similar destructive Bash command) and you have not explicitly disabled
sandbox auto-allow, your prompt is not firing. There is no warning;
`rm` runs silently.

The fix — for this repo and any project — is the two-layer setup
described in the [main README](../README.md): `permissions.deny` as the
unconditional floor, plus a PreToolUse hook for the regex variants
(`git rm`, `git restore`, etc.) that arg-pattern-based denies cannot
match reliably.

## Sources

- [Configure permissions](https://code.claude.com/docs/en/permissions) — the quoted passage is in the "Bash" section under "Tool-specific permission rules"
- [Settings precedence](https://code.claude.com/docs/en/settings)
- [Hook behavior](https://code.claude.com/docs/en/hooks)
