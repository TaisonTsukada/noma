#!/bin/sh
# 契約 lint — 公開シグネチャ (.mli) が II 段 3 の規約を守っているか検査する。
#
#   規則 1: すべての `val` に doc コメント `(** ... *)` がある。
#   規則 2: ラベル引数 (~) か optional 引数 (?) を取る `val` には、
#           doc コメント内に契約語彙 `要求:` / `保証:` / `不変:` のいずれかがある。
#
# 単純なアクセサ (`val status : t -> Http.Status.t`) に契約を書かせると
# 中身のない契約が量産されるため、規則 2 は引数を取るものだけに課す。
#
# usage: tools/lint_contracts.sh [mli ...]     (省略時は lib/**/*.mli)
set -eu

if [ "$#" -eq 0 ]; then
  set -- $(find lib -name '*.mli' | sort)
fi

out=$(
  for f in "$@"; do
    awk -v file="$f" '
      function flush(   sig, needs, hasdoc, hascontract) {
        if (name == "") return
        hasdoc = (index(buf, "(**") > 0)
        sig = buf
        sub(/\(\*\*.*/, "", sig)                             # doc 以降を落とす
        sub(/^[[:space:]]*val[[:space:]]+[^:]*:/, "", sig)     # `val <name> :` を落とす
        # 残った型の中に `?label:` か `label:` があれば引数を取る val とみなす
        needs = (sig ~ /\?[a-zA-Z_]/ || sig ~ /[a-zA-Z_][a-zA-Z_0-9'\'']*[[:space:]]*:/)
        hascontract = (buf ~ /要求:/ || buf ~ /保証:/ || buf ~ /不変:/)
        if (!hasdoc)
          printf "%s:%d: val %s — doc コメントがありません\n", file, line, name
        else if (needs && !hascontract)
          printf "%s:%d: val %s — 契約 (要求:/保証:/不変:) がありません\n", file, line, name
        name = ""
      }
      /^[[:space:]]*val[[:space:]]/ {
        flush()
        name = $0
        sub(/^[[:space:]]*val[[:space:]]+/, "", name)
        sub(/[[:space:]:].*$/, "", name)
        line = NR
        buf = $0
        next
      }
      /^[[:space:]]*(module|end|type|exception|external)[[:space:]]/ { flush() }
      { if (name != "") buf = buf "\n" $0 }
      END { flush() }
    ' "$f"
  done
)

if [ -n "$out" ]; then
  printf '%s\n' "$out"
  printf '\n契約 lint: %s 件の違反\n' "$(printf '%s\n' "$out" | wc -l | tr -d ' ')"
  exit 1
fi

echo "契約 lint: ok"
