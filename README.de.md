# Claude Code Guardrails

Defense-in-depth-Schutz gegen destruktive `rm`- und `git`-Operationen
beim Arbeiten mit [Claude Code](https://docs.claude.com/en/docs/claude-code).

> **Warum das existiert:** Claude Codes `permissions.ask`-Regel für
> `Bash(rm:*)` greift *nicht*, wenn die Session mit Sandbox-Auto-Allow
> oder in einem Permission-Modus außer `default` läuft. Reale, nicht
> wiederherstellbare Datenverluste sind möglich. Dieses Repo bietet
> einen Zwei-Schichten-Schutz, der unabhängig vom Modus blockt.

[English version](./README.md)

---

## TL;DR

Zwei Schichten:

1. **`permissions.deny`-Regel** in `<projekt>/.claude/settings.json` —
   `deny` gewinnt in jedem Modus, auch bei Sandbox-Bypass.
2. **PreToolUse-Hook** unter `~/.claude/hooks/block-destructive.sh` —
   regex-basiert, robuster als fragile Glob-Patterns mit Argument-
   Reihenfolge-Edge-Cases.

Plus eine **Methodik-Doku** ([`workflow/WORKFLOW.md`](./workflow/WORKFLOW.md)),
die zeigt, wie der Schutz empirisch entwickelt wurde — dasselbe Pattern
ist für eigene Guardrails adaptierbar.

---

## Was geblockt wird

| Klasse | Mechanismus | Anmerkung |
|---|---|---|
| `rm` (jegliche Form) | `permissions.deny` | wirkt in jedem Permission-Modus, auch bei aktivem Sandbox-Auto-Allow |
| `rm -r` / `-rf` / `--force` (auch in Pipes, `xargs`, Subshells, Chains) | Hook + deny | Defense in Depth |
| `git rm` (jegliche Form, mit/ohne Flag) | Hook | schließt die Lücke `git rm <file>` |
| `git restore <file>` (ohne `--staged`) | Hook | verwirft uncommitted Änderungen — kein Reflog-Recovery |
| `git checkout … -- <file>` | Hook | gleiche destruktive Klasse |
| `git clean -f/-x/-d` | Hook | |
| `git reset --hard` | Hook | |
| `git push … --force` | Hook | nur Langform — `-f` Kurzform NICHT gefangen |
| `git branch -D` | Hook | |
| `find … -delete` / `find … -exec rm` | Hook | |
| `rsync --delete` / `--delete-after` / `--delete-before` | Hook | |
| `DROP TABLE/DATABASE/SCHEMA`, `TRUNCATE TABLE` | Hook | |
| `docker {system,volume,image,container,network} prune --force`, `docker rm -f`, `docker volume rm` | Hook | |
| `mkfs.*`, `dd … of=/dev/sd…`, `> /dev/sd…`, `shred`, `trash` | Hook | |
| Schreibzugriff auf geschützte Pfade (`design-source/`, `vendor/`, `_archive/` etc.) | Hook | projekt-spezifische Liste, anpassen |
| Mass-Reads (`ls -R`, `find .` ohne Filter, `rg/grep` ohne Pfad, `tree`, `cat *.md`) | Hook | erzwingt expliziten Scope |

## Was NICHT geblockt wird (akzeptierte Trade-offs)

- `git restore --staged <file>` — nicht destruktiv, entfernt nur aus Stage
- `git checkout <branch>` (Branch-Switch ohne `--`) — git aborted bei dirty working tree von selbst
- `git checkout HEAD <file>` (alte Syntax ohne `--`) — selten genutzt
- `git stash drop` / `git stash clear`
- `git push -f` (Kurzform — nur `--force` gefangen)
- `git filter-branch`, `git update-ref -d`, `git reflog expire`
- `git commit --amend` nach push
- `mv`/`cp` mit überschreibendem Ziel

---

## Installation

### 1. Hook installieren (User-Level, gilt für alle Projekte)

```bash
mkdir -p ~/.claude/hooks
curl -fsSL https://raw.githubusercontent.com/web-werkstatt/claude-code-guardrails/main/hooks/block-destructive.sh \
  -o ~/.claude/hooks/block-destructive.sh
chmod +x ~/.claude/hooks/block-destructive.sh
```

Oder klonen und kopieren:

```bash
git clone https://github.com/web-werkstatt/claude-code-guardrails.git
cp claude-code-guardrails/hooks/block-destructive.sh ~/.claude/hooks/
chmod +x ~/.claude/hooks/block-destructive.sh
```

### 2. Hook in User-Settings registrieren

[`settings/settings-user.example.json`](./settings/settings-user.example.json)
in `~/.claude/settings.json` mergen (bestehende Felder erhalten):

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

### 3. Deny-Regel pro Projekt eintragen

[`settings/settings-project.example.json`](./settings/settings-project.example.json)
in `<projekt>/.claude/settings.json` mergen:

```json
{
  "permissions": {
    "ask": ["Bash(rm:*)"],
    "deny": ["Bash(rm:*)"]
  }
}
```

Der `ask`-Eintrag dient als Backup — falls `deny` mal entfernt wird,
greift `ask` im Default-Modus weiter. Wenn beide da sind, gewinnt `deny`.

### 4. Geschützte Pfade anpassen

`PROTECTED_PATHS` in `block-destructive.sh` (ca. Zeile 186) auf dein
Projekt anpassen. Default-Beispiele (`design-source/`, `vendor/`,
`_archive/` etc.) sind Platzhalter — durch projekt-relevante Pfade
ersetzen.

### 5. Verifizieren (in einem Wegwerf-Verzeichnis)

```bash
mkdir -p /tmp/guardrails-test && cd /tmp/guardrails-test
git init -q
echo "test" > file.txt
git add file.txt && git commit -q -m "init"

# Test 1: rm muss blocken
rm file.txt
# erwartet: "Permission to use Bash with command rm ... has been denied."

# Test 2: git rm muss blocken
git rm file.txt
# erwartet: Hook-Ausgabe "BLOCKED — destruktives Kommando erkannt"

# Test 3: git restore (destruktiv) muss blocken
echo "modified" >> file.txt
git restore file.txt
# erwartet: Hook-Ausgabe "BLOCKED — git restore verwirft uncommitted changes"

# Test 4: git restore --staged (NICHT destruktiv) muss durchlaufen
git add file.txt
git restore --staged file.txt
# erwartet: durchgelassen, Stage geleert, Modifikation bleibt
```

---

## Warum zwei Schichten?

| Schicht | Stärken | Schwächen |
|---|---|---|
| `permissions.deny` | wirkt in *jedem* Modus inkl. Sandbox-Bypass; einfach zu pflegen | nur Glob-Patterns; fragil bei Argument-Reihenfolge |
| PreToolUse-Hook | volle Regex; kann Kontext prüfen (Heredoc-Stripping, Mass-Read-Detection) | wird nicht ausgeführt wenn `allowManagedHooksOnly` enterprise-managed ist |

`deny` allein reicht nicht für `git rm`, weil die Doku explizit warnt,
dass arg-beschränkende Patterns wie `Bash(git push --force *)` durch
`git push origin --force main` (andere Argument-Reihenfolge) brechen.
Hook-Regex ist robuster.

Hook allein reicht nicht für `rm`, weil eine Konfig-Änderung oder ein
Hook-Bug ihn deaktivieren könnte. Die `deny`-Regel ist eine unabhängige
zweite Linie.

---

## Empirisch verifiziert (2026-04-27, Claude Code 2.1.119)

- `Bash(rm:*)` in `permissions.ask` greift **nicht**, wenn Sandbox-Auto-
  Allow für Bash aktiv ist. `permissions.deny` greift dagegen immer —
  daher die Zwei-Schichten-Lösung.
- Settings-Änderungen werden hot-reloaded, kein Session-Restart nötig.
- Compound-Commands (`&&`, `;`, `|`) werden in Subcommands zerlegt und
  jedes einzeln gegen die Permission-Rules geprüft.
- `xargs <cmd>` wird vor dem Match zu `<cmd>` gestripped → `Bash(rm:*)`
  deny fängt auch `xargs rm` aus Pipes.
- `permissions.deny` schlägt `permissions.allow` auf jedem Scope —
  managed > local project > project > user.

Siehe [`workflow/WORKFLOW.md`](./workflow/WORKFLOW.md) für den vollen
Untersuchungspfad, der zu diesen Erkenntnissen führte — die gleiche
Methodik ist auf andere Guardrails übertragbar.

---

## Bekannte False Positives

- Bash-Inline-Strings wie `echo "git rm test"` triggern den Hook
  (Substring-Match). Heredocs werden korrekt gestripped, Inline-Strings
  nicht. Akzeptabler Trade-off.
- `mv`/`cp` mit überschreibendem Ziel ist NICHT geblockt. Wenn relevant:
  `alias mv='mv -i'` in der Shell-Config oder Pattern in den Hook ergänzen.

---

## Lizenz

MIT — siehe [LICENSE](./LICENSE).

## Quellen

- [Configure permissions](https://code.claude.com/docs/en/permissions)
- [Settings precedence](https://code.claude.com/docs/en/settings)
- [Hook behavior](https://code.claude.com/docs/en/hooks)
