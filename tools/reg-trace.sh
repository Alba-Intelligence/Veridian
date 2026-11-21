#!/bin/sh
# Regulation -> spec -> model -> tests, derived from tags in the sources (D-084).
#   tools/reg-trace.sh <id>      follow one regulation id, e.g. BCBS239.P3, MAR21.20
#   tools/reg-trace.sh --list    every id that some spec construct cites
#   tools/reg-trace.sh --check   fail if a tag names something that does not exist
# Tags (see docs/design/spec-and-model-policy.md, section 3, for the model ones):
#   -- reg: <id> [<id> ...]     inside a rule, invariant or @invariant of a spec
#   -- model: <model>.<element> (D-055, already checked by models/trace_check.sh)
#   -- test: <path> [<path> ...] for constructs no model covers
# An id is PREFIX.rest (BCBS239.P3, MAR21.8, MAR21.19-24, CRR.Art325(2)); PREFIX
# must be listed in docs/trace/reg-sources.tsv, which holds the official link.
# The chain is a join of tags and names. It does not prove that a spec says what
# the regulation says, or that a test checks the property; see the guide.
set -eu
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
tab="$(printf '\t')"

# One line per tag: spec<TAB>construct<TAB>line<TAB>kind<TAB>value
for f in specs/*.allium; do
  awk -v spec="$(basename "$f" .allium)" -v OFS='\t' '
    /^[[:space:]]*(@invariant|rule|invariant)[[:space:]]+[A-Za-z0-9_]+/ {
      for (i = 1; i <= NF; i++)
        if ($i == "@invariant" || $i == "rule" || $i == "invariant") {
          cur = $(i + 1); sub(/[^A-Za-z0-9_].*/, "", cur); at = NR; break
        }
      next
    }
    /^[[:space:]]*-- (reg|model|test):/ {
      kind = $2; sub(/:$/, "", kind)
      line = $0; sub(/^[[:space:]]*-- (reg|model|test):[[:space:]]*/, "", line)
      n = split(line, p, /[[:space:],]+/)
      for (i = 1; i <= n; i++) if (p[i] != "") print spec, cur, at, kind, p[i]
    }
  ' "$f"
done > "$tmp/tags"

# covers(cited, want): equal, or cited is a range a-b that contains want.
covers='
  function covers(cited, want,   m, a, pc, pw, nw) {
    if (cited == want) return 1
    if (cited !~ /-[0-9]+$/) return 0
    pc = cited; sub(/[0-9]+-[0-9]+$/, "", pc)
    pw = want;  sub(/[0-9]+$/, "", pw)
    if (pc != pw) return 0
    a = cited; sub(/^.*\./, "", a); split(a, m, "-")
    nw = want; sub(/^.*\./, "", nw)
    return (nw + 0 >= m[1] + 0 && nw + 0 <= m[2] + 0)
  }'

source_of() {  # prefix -> "title<TAB>url"
  awk -F'\t' -v p="$1" 'NR > 1 && $1 == p { print $2 "\t" $3 }' docs/trace/reg-sources.tsv
}

case "${1:-}" in
--list)
  awk -F'\t' '$4 == "reg" { print $5 "\t" $1 "#" $2 }' "$tmp/tags" | sort -u
  ;;
--check)
  bad=0
  while IFS="$tab" read -r spec cons line kind val; do
    case "$kind" in
    reg)
      pre="${val%%.*}"
      if [ "$pre" = "$val" ] || [ -z "$(source_of "$pre")" ]; then
        echo "ERROR $spec#$cons: reg id '$val' has no source in docs/trace/reg-sources.tsv" >&2; bad=1
      fi ;;
    test)
      [ -f "$val" ] || { echo "ERROR $spec#$cons: test file '$val' does not exist" >&2; bad=1; } ;;
    model)
      m="${val%%.*}"; e="${val#*.}"
      if ! grep -qE "^[[:space:]]*(pure )?(action|val|def) +$e\\b" "models/$m.qnt" 2>/dev/null; then
        echo "ERROR $spec#$cons: model element '$val' not found" >&2; bad=1
      fi ;;
    esac
  done < "$tmp/tags"
  [ "$bad" = 0 ] || exit 1
  echo "reg-trace: $(awk -F'\t' '$4 == "reg"' "$tmp/tags" | wc -l | tr -d ' ') reg tags resolve"
  ;;
"" | -*)
  echo "usage: tools/reg-trace.sh <id> | --list | --check" >&2; exit 2 ;;
*)
  id="$1"; pre="${id%%.*}"
  src="$(source_of "$pre")"
  [ -n "$src" ] || { echo "unknown prefix '$pre'; see docs/trace/reg-sources.tsv" >&2; exit 1; }
  printf 'REGULATION  %s\n  %s\n  %s\n  (the link is to the whole text; the id names the part)\n' \
    "$id" "$(printf '%s' "$src" | cut -f1)" "$(printf '%s' "$src" | cut -f2)"
  awk -F'\t' -v id="$id" "$covers"' $4 == "reg" && covers($5, id) { print $1 "\t" $2 "\t" $3 }' "$tmp/tags" | sort -u > "$tmp/hits"
  if [ ! -s "$tmp/hits" ]; then
    echo "SPEC        none: no spec construct cites $id"; exit 0
  fi
  while IFS="$tab" read -r spec cons line; do
    printf 'SPEC        specs/%s.allium:%s  %s   [stated in Allium; reviewed by people]\n' "$spec" "$line" "$cons"
    models="$(awk -F'\t' -v s="$spec" -v c="$cons" '$1 == s && $2 == c && $4 == "model" { print $5 }' "$tmp/tags")"
    tests="$(awk -F'\t' -v s="$spec" -v c="$cons" '$1 == s && $2 == c && $4 == "test" { print $5 }' "$tmp/tags")"
    for e in $models; do
      m="${e%%.*}"
      printf 'MODEL       models/%s.qnt  %s   [random simulation, small instance; not a proof]\n' "$m" "${e#*.}"
      for t in $(grep -rlE "$m([^_A-Za-z]|\$)" control_plane/test julia/VeridianCanonical/test 2>/dev/null | grep -E '_test\.exs$|runtests\.jl$' | sort); do
        mods="$(grep -oE 'Veridian\.[A-Z][A-Za-z]+' "$t" | grep -vE 'Test$' | sort -u | tr '\n' ' ')"
        if grep -q "\"${e#*.}\"" "$t"; then
          printf 'TEST        %s   [ties code to this model element by name; modules named: %s]\n' "$t" "${mods:-none}"
        elif grep -q 'Replay\.' "$t"; then
          printf 'TEST        %s   [replays model traces; modules named: %s; shows the code can follow the sampled traces]\n' "$t" "${mods:-none}"
        else
          printf 'TEST        %s   [names the model %s; see the test for what it checks]\n' "$t" "$m"
        fi
      done
    done
    for t in $tests; do
      printf 'TEST        %s   [direct test, no model]\n' "$t"
    done
    if [ -z "$models" ] && [ -z "$tests" ]; then
      echo "            gap: no model and no test tag on this construct"
    fi
  done < "$tmp/hits"
  ;;
esac
