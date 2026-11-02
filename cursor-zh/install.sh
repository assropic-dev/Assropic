#!/bin/bash
# Cursor 完整汉化：语言包 + 补充译文 + 补充脚本。
# 用法（先 Cmd+Q 完全退出 Cursor）：
#   ./install.sh            安装或重装（Cursor 更新后也跑这个）
#   ./install.sh restore    恢复 Cursor 原样
set -euo pipefail
cd "$(dirname "$0")"
CONTENTS="${CURSOR_CONTENTS:-/Applications/Cursor.app/Contents}"
NODE="$CONTENTS/MacOS/Cursor"
PACK_VERSION=1.1.3
PACK_INTEGRITY="sha512-8fymZ7MyQ8rJNMcpmmZa5nPykhrMSwbFSx/7eeiSs8KVdZEf7PIVOydBg7bg4SpJDv27W9FAQopticZozxgWPA=="

if pgrep -f "$CONTENTS/MacOS/Cursor" >/dev/null; then
  echo "请先按 Cmd+Q 完全退出 Cursor。" >&2; exit 1
fi

# 语言包放在本机临时目录运行；U 盘只存下载好的原包。
mkdir -p vendor
TGZ="vendor/cursor-language-pack-$PACK_VERSION.tgz"
if [ ! -f "$TGZ" ]; then
  curl -fsSL "https://registry.npmjs.org/@polang233/cursor-language-pack/-/cursor-language-pack-$PACK_VERSION.tgz" -o "$TGZ"
fi
[ "sha512-$(openssl dgst -sha512 -binary "$TGZ" | base64)" = "$PACK_INTEGRITY" ] || { echo "语言包校验失败" >&2; exit 1; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
tar xzf "$TGZ" -C "$WORK"
PACK="$WORK/package"

# 先撤掉 extra.mjs 的改动，语言包才认得自己写过的文件。
ELECTRON_RUN_AS_NODE=1 "$NODE" extra.mjs --undo --dir="$CONTENTS"

if [ "${1:-}" = "restore" ]; then
  ELECTRON_RUN_AS_NODE=1 "$NODE" "$PACK/bin/cli.mjs" restore --dir="$CONTENTS"
  exit 0
fi

# 把补充译文并进语言包的译文表（语言包已有的条目优先）。
DICT="$PACK/src/i18n/zh-cn/hardcoded.json"
ELECTRON_RUN_AS_NODE=1 "$NODE" -e '
const fs=require("fs"),path=require("path");
const [dict,dir]=process.argv.slice(1);
const base=JSON.parse(fs.readFileSync(dict,"utf8"));
let added=0;
for (const f of fs.readdirSync(dir).filter(n=>n.endsWith(".json")&&!n.startsWith(".")).sort()) {
  for (const [k,v] of Object.entries(JSON.parse(fs.readFileSync(path.join(dir,f),"utf8")))) {
    if (!(k in base) && v) { base[k]=v; added++; }
  }
}
fs.writeFileSync(dict,JSON.stringify(base,null,1));
console.log("+ 补充译文 "+added+" 条");
' "$DICT" supplement

ELECTRON_RUN_AS_NODE=1 "$NODE" "$PACK/bin/cli.mjs" install --locale=zh-cn --dir="$CONTENTS" \
  || echo "! 语言包有步骤没完成，见上面的提示；程序文字的汉化已经写入。"
ELECTRON_RUN_AS_NODE=1 "$NODE" extra.mjs --dir="$CONTENTS"
echo "完成。重新打开 Cursor 即可。"
