#!/usr/bin/env bash
# PreToolUse Hook: Blockiert destruktive Bash-Kommandos und Schreibzugriffe
# auf geschützte Design-/Quellen-Pfade. Wird VOR der normalen Permission-Logik
# aufgerufen — Sprint-Specs autorisieren Analyse und Plan, NICHT Destruktion.
#
# Aktiviert via ~/.claude/settings.json -> hooks.PreToolUse mit matcher "Bash".
# Exit 2 = block (stderr wird dem Modell angezeigt).

set -euo pipefail

INPUT=$(cat)
RAW_COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // ""')

# Heredoc-Bodies aus dem Match-String entfernen — verhindert False Positives
# bei Commit-Messages, Doku-Texten etc., die destruktive Patterns beschreiben.
# Erkennt: <<EOF ... EOF, <<'EOF' ... EOF, <<-EOF ... EOF (beliebige Tag-Namen).
COMMAND=$(printf '%s' "$RAW_COMMAND" | awk '
  BEGIN { in_heredoc = 0; tag = "" }
  {
    line = $0
    if (in_heredoc == 0) {
      # Heredoc-Start: <<[-]?["\047]?TAG["\047]?  (\042=", \047=apostroph)
      if (match(line, /<<-?[[:space:]]*[\042\047]?[A-Za-z_][A-Za-z0-9_]*[\042\047]?/)) {
        m = substr(line, RSTART, RLENGTH)
        gsub(/^<<-?[[:space:]]*[\042\047]?/, "", m)
        gsub(/[\042\047]?$/, "", m)
        tag = m
        in_heredoc = 1
        print substr(line, 1, RSTART - 1)
        next
      }
      print line
    } else {
      if (line == tag || line ~ ("^[[:space:]]+" tag "$")) {
        in_heredoc = 0
        tag = ""
      }
      # Body wird ausgelassen
    }
  }
')

# ---------------------------------------------------------------------------
# 0) Mass-Read-Detection — Repo-weite Scans ohne Pfad-Argument bzw. mit `.`
#    sind ein Zeichen, dass der Task zu grob geschnitten ist. Hard-Stop mit
#    Erklär-Hinweis; Claude muss nachfragen statt blind das Repo zu scannen.
# ---------------------------------------------------------------------------
MASS_READ_PATTERNS=(
  '(^|[[:space:]&;|])ls[[:space:]]+(-[a-zA-Z]*R[a-zA-Z]*[[:space:]]|--recursive)'
  '(^|[[:space:]&;|])find[[:space:]]+\.([[:space:]]|$)'
  '(^|[[:space:]&;|])find[[:space:]]+/[[:space:]]'
  '(^|[[:space:]&;|])grep[[:space:]]+-[a-zA-Z]*[rR][a-zA-Z]*[[:space:]]+[^[:space:]]+[[:space:]]+\.([[:space:]]|$)'
  '(^|[[:space:]&;|])grep[[:space:]]+-[a-zA-Z]*[rR][a-zA-Z]*[[:space:]]+[^[:space:]]+[[:space:]]*$'
  '(^|[[:space:]&;|])rg[[:space:]]+[^|]+[[:space:]]+\.([[:space:]]|$)'
  '(^|[[:space:]&;|])rg[[:space:]]+[^[:space:]|/-][^[:space:]|]*[[:space:]]*$'
  '(^|[[:space:]&;|])cat[[:space:]]+[^|;&]*\*\.[a-zA-Z]+([[:space:]]|$)'
  '(^|[[:space:]&;|])tree([[:space:]]|$)'
  '(^|[[:space:]&;|])du[[:space:]]+-[a-zA-Z]*[[:space:]]*$'
  '(^|[[:space:]&;|])wc[[:space:]]+-[a-zA-Z]*[[:space:]]+\*'
)

for pattern in "${MASS_READ_PATTERNS[@]}"; do
  if printf '%s' "$COMMAND" | grep -qE "$pattern"; then
    cat <<EOF >&2
🛑 BLOCKED — Mass-Read erkannt (Repo-weiter Scan ohne klaren Scope).

  Pattern : $pattern
  Command : $COMMAND

Wenn du "das ganze Repo verstehen" musst, ist der Task zu grob
geschnitten. Bevor du erneut versuchst:

  1. Nenne den ENGEN Scope, den du brauchst (z. B. backend-admin/api-backend/app/api/,
     frontend-webseite/astro-frontend/src/pages/).
  2. Lies gezielt mit Read/grep MIT Pfad-Argument, nicht mit . oder ohne.
  3. Bei echtem Repo-weitem Bedarf: User explizit fragen, was er erlaubt.

Dieser Block ist eine bewusste Designentscheidung, kein Tool-Fehler.
EOF
    exit 2
  fi
done

# ---------------------------------------------------------------------------
# 1) Destruktive Kommando-Pattern (Reihenfolge bewusst: spezifisch -> generisch)
# ---------------------------------------------------------------------------
DESTRUCTIVE_PATTERNS=(
  '(^|[[:space:]&;|])rm[[:space:]]+(-[a-zA-Z]*[rRf][a-zA-Z]*[[:space:]]|-[a-zA-Z]*[fF][a-zA-Z]*r[a-zA-Z]*[[:space:]])'
  '(^|[[:space:]&;|])rm[[:space:]]+--recursive'
  '(^|[[:space:]&;|])rm[[:space:]]+--force'
  '(^|[[:space:]&;|])git[[:space:]]+rm([[:space:]]|$)'
  '(^|[[:space:]&;|])git[[:space:]]+clean[[:space:]]+-[a-zA-Z]*[fxd]'
  '(^|[[:space:]&;|])git[[:space:]]+reset[[:space:]]+--hard'
  '(^|[[:space:]&;|])git[[:space:]]+checkout[[:space:]]+\.[[:space:]]*$'
  '(^|[[:space:]&;|])git[[:space:]]+restore[[:space:]]+\.[[:space:]]*$'
  '(^|[[:space:]&;|])git[[:space:]]+push[[:space:]]+.*--force'
  '(^|[[:space:]&;|])git[[:space:]]+branch[[:space:]]+-D'
  '(^|[[:space:]&;|])find[[:space:]].+-delete([[:space:]]|$)'
  '(^|[[:space:]&;|])find[[:space:]].+-exec[[:space:]]+rm[[:space:]]'
  '(^|[[:space:]&;|])trash([[:space:]]|$)'
  '(^|[[:space:]&;|])shred([[:space:]]|$)'
  '(^|[[:space:]&;|])mkfs(\.[a-z0-9]+)?[[:space:]]'
  '(^|[[:space:]&;|])dd[[:space:]].+of=/dev/'
  '>[[:space:]]*/dev/sd[a-z]'
  '(^|[[:space:]&;|])Remove-Item[[:space:]]+.*-Recurse'
  '(^|[[:space:]&;|])rsync[[:space:]].+--delete([[:space:]]|$)'
  '(^|[[:space:]&;|])rsync[[:space:]].+--delete-after'
  '(^|[[:space:]&;|])rsync[[:space:]].+--delete-before'
  '(^|[[:space:]&;|])DROP[[:space:]]+(TABLE|DATABASE|SCHEMA)'
  '(^|[[:space:]&;|])TRUNCATE[[:space:]]+TABLE'
  '(^|[[:space:]&;|])docker[[:space:]]+(system|volume|image|container|network)[[:space:]]+prune.*--force'
  '(^|[[:space:]&;|])docker[[:space:]]+rm[[:space:]]+-f'
  '(^|[[:space:]&;|])docker[[:space:]]+volume[[:space:]]+rm'
)

for pattern in "${DESTRUCTIVE_PATTERNS[@]}"; do
  if printf '%s' "$COMMAND" | grep -qE "$pattern"; then
    cat <<EOF >&2
🛑 BLOCKED — destruktives Kommando erkannt.

  Pattern : $pattern
  Command : $COMMAND

Sprint-Specs und NOW-Tasks autorisieren Analyse und Plan, NICHT
Destruktion. Bevor du das Kommando erneut versuchst:

  1. Liste exakt auf, WAS gelöscht/verändert/überschrieben wird
     (Pfade, Größen, letzte Änderung, Inhalt-Stichprobe).
  2. Frage den User in DIESEM Turn explizit nach Bestätigung.
  3. Bei Konflikt zwischen Spec und Repo-Realität: stoppen, nicht
     "korrigierend aufräumen".

Override nur durch User: Permissions/Hooks bewusst und temporär
ausschalten — niemals durch erneuten Tool-Call mit anderer Syntax.
EOF
    exit 2
  fi
done

# ---------------------------------------------------------------------------
# 1b) git restore / git checkout mit Pfad-Argument
#     -> verwirft uncommitted changes im working tree, KEIN Reflog-Recovery.
#     git restore --staged <file> ist NICHT destruktiv und wird ausgenommen.
# ---------------------------------------------------------------------------
if printf '%s' "$COMMAND" | grep -qE '(^|[[:space:]&;|])git[[:space:]]+restore([[:space:]]|$)' \
   && ! printf '%s' "$COMMAND" | grep -qE 'git[[:space:]]+restore[[:space:]]+([^[:space:]]+[[:space:]]+)*--staged'; then
  cat <<EOF >&2
🛑 BLOCKED — git restore verwirft uncommitted changes im working tree.

  Command : $COMMAND

git restore <file> (ohne --staged) ueberschreibt working-tree-Aenderungen
mit dem Index- bzw. HEAD-Stand. Uncommitted changes haben KEINEN Reflog-
Eintrag — sie sind nach dem restore unrettbar weg, auch wenn nie gepusht
wurde.

Sicherer Workflow:
  1. git status               (was wuerde verworfen?)
  2. git stash push -m "before restore"
  3. Pfad-spezifisches restore mit User-Bestaetigung in DIESEM Turn
EOF
  exit 2
fi

if printf '%s' "$COMMAND" | grep -qE '(^|[[:space:]&;|])git[[:space:]]+checkout[[:space:]]+.*--([[:space:]]|$)'; then
  cat <<EOF >&2
🛑 BLOCKED — git checkout mit Pfad-Argument verwirft uncommitted changes.

  Command : $COMMAND

git checkout -- <file> oder git checkout <ref> -- <file> ueberschreibt
working-tree-Aenderungen ohne Reflog-Recovery. Genauso endgueltig wie
ein rm.

Sicherer Workflow:
  1. git stash push -m "before checkout"
  2. Pfad-spezifischer checkout mit User-Bestaetigung
  3. git stash pop falls noetig
EOF
  exit 2
fi

# ---------------------------------------------------------------------------
# 2) Schreibzugriff auf geschützte Pfade (Designquellen, Scrapes, Test-Snapshots)
# ---------------------------------------------------------------------------
# NOTE: Adjust this list per project. Add paths that should be read-only
# after creation (design sources, vendored code, snapshot fixtures, etc.).
# Format: relative path with trailing slash, no leading slash.
PROTECTED_PATHS=(
  'design-source/'
  'snapshots/'
  '_archive/'
  'archive/'
  'vendor/'
)

WRITE_OPS_PATTERN='(^|[[:space:]&;|])(rm|mv|cp|git[[:space:]]+rm|sed[[:space:]]+-i|tee|truncate|chmod|chown|find[[:space:]].+-(delete|exec))'

for path in "${PROTECTED_PATHS[@]}"; do
  escaped=$(printf '%s' "$path" | sed 's/[][\.*^$()+?{}|]/\\&/g; s_/_\\/_g')
  if printf '%s' "$COMMAND" | grep -qE "$WRITE_OPS_PATTERN" \
     && printf '%s' "$COMMAND" | grep -qE "(^|[[:space:]/\"'])${escaped}"; then
    cat <<EOF >&2
🛑 BLOCKED — Schreibzugriff auf geschützten Pfad.

  Pfad    : $path
  Command : $COMMAND

Dieser Pfad ist in CLAUDE.md als Design-/Original-Quelle markiert
(read-only nach Erstellung). Schreibzugriff erfordert:

  1. Inventur-Schritt: was ist primary, was archivierbar?
     Output als markdown-Doku unter docs/.
  2. Explizite User-Freigabe in DIESEM Turn (nicht über Sprint-Spec).
  3. Bei mehreren Lovable-/Scrape-Quellen: Klärung welche führend
     ist, BEVOR irgendetwas verschoben oder gelöscht wird.

Lesen (Read, ls, grep, cat, find ohne -delete) ist erlaubt.
EOF
    exit 2
  fi
done

# Alles klar -> Tool darf laufen
exit 0
