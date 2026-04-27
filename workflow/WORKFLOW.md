# How to add a Claude Code guardrail — methodology

This document captures the methodology used to develop the destructive-
command protection in this repo. Use it as a template when adding your
own guardrails for other tool classes.

## Core principle

**Don't trust documentation alone — verify empirically in a throwaway
directory.** Configuration that looks correct on paper can fail silently
because of permission-mode interactions, sandbox-bypass behavior, or hook
load-order bugs. The docs describe the *intended* behavior; the live
session is the source of truth.

## Seven-step pattern

### 1. Reproduce the gap

Trigger the destructive command in a safe location with a real,
existing target. Example for `rm`:

```bash
mkdir -p /tmp/guardrail-test
touch /tmp/guardrail-test/dummy.txt
rm /tmp/guardrail-test/dummy.txt
ls -la /tmp/guardrail-test/   # is the file gone?
```

If the command runs without a permission prompt, the gap is real and
needs closing. Don't assume a prompt is "supposed to" appear — observe.

### 2. Inspect actual configuration

Find every settings file in the precedence chain and check whether
your supposed protection is actually present:

```bash
find ~/.claude /path/to/project/.claude -maxdepth 3 -name 'settings*.json'
grep -nE '"Bash\(<command>[: ]' <each file>
grep -nE '"defaultMode"|"permissionMode"|"bypass"' <each file>
env | grep -i claude
```

Note the precedence (highest to lowest):
1. Managed settings (enterprise/MDM)
2. Command-line arguments
3. Local project settings (`.claude/settings.local.json`)
4. Shared project settings (`.claude/settings.json`)
5. User settings (`~/.claude/settings.json`)

Array fields (`permissions.allow`, `ask`, `deny`) **merge** across scopes,
not replace. A user-level allow plus a project-level ask both apply.

### 3. Read the official docs for the relevant subsystem

For permissions:
- <https://code.claude.com/docs/en/permissions>
- <https://code.claude.com/docs/en/settings>
- <https://code.claude.com/docs/en/hooks>

Look specifically for:
- **Pattern matching syntax** — is `Bash(cmd:*)` equivalent to `Bash(cmd *)`?
  (Yes — `:*` is the documented trailing-wildcard form.)
- **Rule precedence** — `deny → ask → allow`, first match wins.
- **Mode-specific bypasses** — `bypassPermissions`, `acceptEdits`, `auto`,
  `dontAsk`, and sandbox `autoAllowBashIfSandboxed: true` (default!) all
  affect when `ask` fires.
- **Hook decision semantics** — `exit 0` does *not* implicitly approve;
  `exit 2` blocks unconditionally; JSON `permissionDecision: "allow"` does
  not bypass `deny` or `ask` rules.

### 4. Identify the root cause

Eliminate possibilities one at a time:

- ✗ Pattern syntax wrong? Check against docs.
- ✗ Hook returning the wrong exit code? Read the hook script.
- ✗ Conflicting allow rule somewhere? Grep all settings files.
- ✗ Wrong permission mode active? Run `/status` or `/permissions` in
  Claude Code.
- ✓ **Sandbox auto-allow for Bash** — the documented default skips `ask`
  for non-critical paths. This is the most common cause when configuration
  looks correct but `ask` doesn't fire.

### 5. Pick a robust mechanism

| Goal | Best mechanism |
|---|---|
| Block a simple command unconditionally | `permissions.deny` (works in every mode) |
| Block argument-dependent variations | PreToolUse hook with regex |
| Force a prompt before execution | `permissions.ask` (only in default mode) |
| Block writes to specific paths | `permissions.deny` for Edit/Write + hook for Bash |

For most destructive operations: **layer both `deny` and a hook.** The
deny rule is the unconditional floor; the hook adds context-aware
matching (heredoc stripping, compound-command detection, negative
conditions like "block `git restore` *unless* `--staged`").

### 6. Verify the fix live

Use the same throwaway directory pattern from step 1 to verify each
new pattern. Repeat for:

- The intended-to-block case (must be blocked)
- The intended-to-pass case (must pass — protect against false positives)
- The combined case (pipe, subshell, chain) — each subcommand is
  evaluated independently against the rules

Example for `git restore`:

```bash
cd /tmp/guardrail-test
git init -q
echo "v1" > file.txt
git add file.txt && git commit -q -m "init"
echo "v2" >> file.txt

# must block:
git restore file.txt

# must pass (not destructive — only unstages):
git add file.txt
git restore --staged file.txt
```

### 7. Package for reuse

Once the fix works, lift the project-specific bits out (like
`PROTECTED_PATHS` lists, repo paths, custom block messages) and document
them as customization points. Put the result in a shared location so
other projects and Claude Code installations can adopt it without
re-investigating.

## Pitfalls observed during this development

- **Memory notes can lie.** A previous session's memory said "settings
  changes only take effect next session." Live testing showed they
  hot-reload immediately. Don't trust stale notes — verify.

- **`exit 0` from a hook does not approve.** It just hands back to the
  permission system. To approve, the hook must emit JSON with
  `permissionDecision: "allow"`. To block, exit 2. Plain `exit 0` for
  non-matching commands is the right behavior.

- **Hook regex can false-positive on inline strings.** A command like
  `echo "git rm test"` triggers the `git rm` block because the substring
  matches. Heredoc bodies are stripped before matching; inline strings
  are not. Acceptable trade-off vs. complexity of full shell parsing.

- **Mass-read patterns aren't only about destruction.** Repo-wide
  `find .`, `ls -R`, `rg <pattern>` without path argument all suggest
  the task is too broadly scoped. Hard-blocking these forces you to
  state an explicit scope, which produces better work and protects
  the context window.

- **Public-repo hygiene.** Project-specific paths in a hook
  (`contao-scrape/`, internal product names, customer slugs) leak when
  the hook is shared. Replace with generic placeholders and document the
  customization step before publishing.

## Template for a new guardrail

1. Reproduce: trigger the unwanted action in a throwaway location, observe.
2. Inspect: dump the config chain that *should* prevent it.
3. Read: the relevant docs section.
4. Diagnose: which layer is failing, and why.
5. Fix: prefer `deny` + hook layered, not either alone.
6. Verify: positive + negative + combined cases.
7. Generalize: extract project-specifics, document, share.
