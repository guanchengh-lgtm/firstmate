#!/usr/bin/env bash
# Live CLI drive of bin/fm-record-scan.sh. Fixtures are assembled from pieces; output masks them.
set -u
SCAN=$PWD/bin/fm-record-scan.sh
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
git show 8c3d6b06:bin/fm-record-scan.sh > "$T/base-scan.sh"; chmod +x "$T/base-scan.sh"
tail20=$(printf '%s%s' 'abcdefghij' 'ABCDEFGHIJ0123456789')
plain=$(printf '%s%s' 's' "k-$tail20")
proj=$(printf '%s%s' 's' "k-proj-$tail20")
stripe=$(printf '%s%s' 's' "k_live_0123456789abcdefgh")
mask() { sed -e "s/$proj/<PROJ-KEY>/g" -e "s/$plain/<CLASSIC-KEY>/g" -e "s/$stripe/<STRIPE-KEY>/g"; }
run() { # <label> <expected> <scanner> args...
  local label=$1 want=$2; shift 2
  out=$("$@" 2>&1); rc=$?
  printf '%s\n  expected=%s actual=%s %s\n' "## $label" "$want" "$rc" "$([ "$rc" = "$want" ] && echo PASS || echo FAIL)"
  printf '%s\n' "$out" | mask | sed 's/^/  | /'
}
d=$T/neg; mkdir -p $d
slug=$(printf '%s%s' 'nm-pipeline-high-risk-fab' 'le-medium-2026-09-13')
look=$(printf '%s%s%s' 'ta' 'sk' '_live_0123456789abcdefgh')
printf 'cite %s.md and %s\n' "$slug" "$look" > "$d/$slug.md"
printf 'see %s.md\n' "$slug" > "$d/captain.md"
run "BASE scanner, slug tree (reproduces false positive)" 2 "$T/base-scan.sh" tree "$d"
run "slug tree" 0 "$SCAN" tree "$d"
run "slug archive-preflight" 0 "$SCAN" archive-preflight --dir "$d"
run "slug chain" 0 "$SCAN" chain --dir "$d"
d=$T/pos; mkdir -p $d
printf 'key: %s\n' "$proj" > $d/p.md;            run "sk-proj key in content, tree" 2 "$SCAN" tree "$d"; run "sk-proj key in content, chain" 2 "$SCAN" chain --dir "$d"
printf '%s\n' "$plain" > $d/p.md;                run "classic key at line start, tree" 2 "$SCAN" tree "$d"
printf '{"k":"x\\n%s"}\n' "$plain" > $d/p.md;    run "classic key after JSON-escaped newline, tree" 2 "$SCAN" tree "$d"; run "same, chain" 2 "$SCAN" chain --dir "$d"
printf '{"k":"x\\r%s"}\n' "$plain" > $d/p.md;    run "classic key after escaped CR, tree" 2 "$SCAN" tree "$d"
printf 'KEY=%s\n' "$stripe" > $d/p.md;           run "stripe key after KEY=, tree" 2 "$SCAN" tree "$d"
printf '{"k":"x\\t%s"}\n' "$stripe" > $d/p.md;   run "stripe key after escaped tab, tree" 2 "$SCAN" tree "$d"
printf 'a-%s\n' "$plain" > $d/p.md;              run "adversarial: key after hyphen (slug-like lead), tree" 2 "$SCAN" tree "$d"
printf 'x_%s\n' "$stripe" > $d/p.md;             run "adversarial: stripe after underscore, tree" 2 "$SCAN" tree "$d"
d=$T/names; mkdir -p $d
printf 'harmless\n' > "$d/$proj.md";             run "filename starts with sk-proj key, chain" 2 "$SCAN" chain --dir "$d"; run "same name, tree (tree reads content only; base commit gives 0 also)" 0 "$SCAN" tree "$d"; run "same name, BASE tree" 0 "$T/base-scan.sh" tree "$d"
d=$T/glued; mkdir -p $d
printf 'x%s\n' "$plain" > $d/g.txt;              run "x glued to classic key (accepted residual), tree" 0 "$SCAN" tree "$d"; run "same, chain" 0 "$SCAN" chain --dir "$d"
d=$T/other; mkdir -p $d
gh=$(printf '%s%s' 'gh' "p_0123456789abcdefghijABCDEFGHIJ012345")
printf 'x%s\n' "$gh" > $d/o.txt;                 out=$("$SCAN" tree "$d" 2>&1); rc=$?
printf '## unchanged class: glued github token, tree\n  expected=2 actual=%s %s\n' "$rc" "$([ $rc = 2 ] && echo PASS || echo FAIL)"; printf '%s\n' "$out" | sed "s/$gh/<GH>/g;s/^/  | /"
