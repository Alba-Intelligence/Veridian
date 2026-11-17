#!/bin/sh
# Traceability between the Allium specs and the Quint models (D-055).
#
# Allium side: inside a rule, invariant or @invariant, a comment line
#     -- model: <model>.<element> [<model>.<element> ...]
# names the Quint elements that model it.
# Quint side: comment lines immediately before an action, val or def
#     // spec: <spec>#<Construct> [, <spec>#<Construct> ...]
# name the Allium constructs it models.
# Every pair must be stated on both sides; any difference fails the check.
# Usage: models/trace_check.sh   (from anywhere; paths are relative to the repo)
set -eu
root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

: > "$tmp/allium"
for f in "$root"/specs/*.allium; do
  awk -v spec="$(basename "$f" .allium)" '
    /^[[:space:]]*(@invariant|rule|invariant)[[:space:]]+[A-Za-z0-9_]+/ {
      for (i = 1; i <= NF; i++)
        if ($i == "@invariant" || $i == "rule" || $i == "invariant") {
          cur = $(i + 1); sub(/[^A-Za-z0-9_].*/, "", cur); break
        }
      next
    }
    /^[[:space:]]*-- model:/ {
      line = $0; sub(/^[[:space:]]*-- model:[[:space:]]*/, "", line)
      if (cur == "") { print "ERROR " spec ": model tag before any construct" > "/dev/stderr"; bad = 1 }
      n = split(line, p, /[[:space:],]+/)
      for (i = 1; i <= n; i++) if (p[i] != "") print spec "#" cur " " p[i]
    }
    END { exit bad }
  ' "$f" >> "$tmp/allium"
done
sort -u "$tmp/allium" -o "$tmp/allium"

: > "$tmp/quint"
for f in "$root"/models/*.qnt; do
  awk -v mod="$(basename "$f" .qnt)" '
    /^[[:space:]]*\/\/ spec:/ {
      line = $0; sub(/^[[:space:]]*\/\/ spec:[[:space:]]*/, "", line)
      n = split(line, p, /[[:space:],]+/)
      for (i = 1; i <= n; i++) if (p[i] != "") pend[++np] = p[i]
      next
    }
    /^[[:space:]]*(pure[[:space:]]+)?(action|val|def)[[:space:]]+[A-Za-z0-9_]+/ {
      match($0, /(action|val|def)[[:space:]]+[A-Za-z0-9_]+/)
      split(substr($0, RSTART, RLENGTH), t, /[[:space:]]+/)
      for (i = 1; i <= np; i++) print pend[i] " " mod "." t[2]
      np = 0; next
    }
    /^[[:space:]]*\/\// { next }
    /^[[:space:]]*$/ { next }
    { if (np > 0) { print "ERROR " mod ": spec tag not followed by a definition" > "/dev/stderr"; bad = 1 } np = 0 }
    END { if (np > 0) { print "ERROR " mod ": spec tag at end of file" > "/dev/stderr"; bad = 1 } exit bad }
  ' "$f" >> "$tmp/quint"
done
sort -u "$tmp/quint" -o "$tmp/quint"

status=0
only_allium="$(comm -23 "$tmp/allium" "$tmp/quint")"
only_quint="$(comm -13 "$tmp/allium" "$tmp/quint")"
if [ -n "$only_allium" ]; then
  echo "Stated in the Allium spec only (no matching spec: tag in the model):"
  echo "$only_allium" | sed 's/^/  /'
  status=1
fi
if [ -n "$only_quint" ]; then
  echo "Stated in the Quint model only (no matching model: tag in the spec):"
  echo "$only_quint" | sed 's/^/  /'
  status=1
fi

# Coverage information (does not fail): constructs of a modelled spec that
# carry no model tag are not covered by any model.
for spec in $(cut -d'#' -f1 "$tmp/allium" | sort -u); do
  total="$(grep -cE '^[[:space:]]*(@invariant|rule|invariant)[[:space:]]+[A-Za-z0-9_]+' "$root/specs/$spec.allium")"
  traced="$(grep "^$spec#" "$tmp/allium" | cut -d' ' -f1 | sort -u | wc -l | tr -d ' ')"
  echo "$spec: $traced of $total rules and invariants traced to a model"
done
n="$(wc -l < "$tmp/allium" | tr -d ' ')"
if [ "$status" -eq 0 ]; then echo "traceability: $n pairs, consistent both ways"; fi
exit "$status"
