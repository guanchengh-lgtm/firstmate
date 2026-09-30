#!/bin/bash
# Round-trip hostile shell values through the js_string helper into a real node ESM script.
js_string() { node -e 'process.stdout.write(JSON.stringify(process.argv[1]))' "$1"; }
fail=0
check() { # <label> <value>
  local label=$1 value=$2 out
  out=$(node --input-type=module <<JS
const v = $(js_string "$value");
process.stdout.write(Buffer.from(v, "utf8").toString("hex"));
JS
) 
  local want; want=$(printf '%s' "$value" | od -An -tx1 | tr -d ' \n')
  if [ "$out" = "$want" ]; then echo "ok   $label"; else echo "FAIL $label got=$out want=$want"; fail=1; fi
}
check "plain path" "/tmp/a/b"
check "space" "/tmp/with space/x"
check "double quote" '/tmp/q"uote'
check "single quote" "/tmp/it's"
check "backslash" '/tmp/back\slash\n'
check "dollar and backtick" '/tmp/$HOME/`id`'
check "template-literal marker" '/tmp/${x}/`t`'
check "embedded newline" $'line1\nline2'
check "trailing newlines kept" $'a\n\n'
check "leading dash" "-foo"
check "leading double dash" "--version"
check "leading -e" "-e"
check "empty" ""
check "unicode" "/tmp/日本語/é"
check "u2028" $'a\xe2\x80\xa8b'
exit $fail
