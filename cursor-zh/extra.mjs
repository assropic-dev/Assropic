// 在 polang233/cursor-language-pack 装好之后运行，补上它没覆盖的文字。
// 用 Cursor 自带的 Node 运行：
//   ELECTRON_RUN_AS_NODE=1 /Applications/Cursor.app/Contents/MacOS/Cursor extra.mjs [--dir=<Cursor.app/Contents>]
// 只做两件事：
//   1. 精确替换几处写死在程序里、语言包没碰的字符串；
//   2. 在 Agents 窗口里加一个只认固定原文的小翻译器，翻译 Cursor 服务器发来的首页建议卡片。
// 改完后更新 product.json 里的校验值，否则 Cursor 会提示安装已损坏。
// 撤销：运行语言包的 restore，它会从原始备份恢复整个文件（本脚本的改动一起撤销）。
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const dirArg = process.argv.find((a) => a.startsWith('--dir='));
const contents = dirArg ? dirArg.slice(6) : '/Applications/Cursor.app/Contents';
const appRoot = path.join(contents, 'Resources', 'app');
const MARK = '/*BRIDGEDOCK-ZH-EXTRA*/';
const extra = JSON.parse(fs.readFileSync(path.join(here, 'extra.zh-cn.json'), 'utf8'));

// [文件, 原文正则, 替换, 至少命中次数]
const literalRules = [
  // 语言包新版本已经翻译这句；旧版本没翻时这里补上。
  ['workbench.glass.main.js', /"Plan, Build, \/ for skills, @ for context"/g, JSON.stringify(extra.literals['Plan, Build, / for skills, @ for context']), 0],
  // No Repo 的两个常量都只用作显示名；仓库判断用的是 kind/id，不比较这段文字。
  ['workbench.glass.main.js', /([,{;\s(][A-Za-z_$][\w$]*)="No Repo"(?=[,;}])/g, `$1=${JSON.stringify(extra.literals['No Repo'])}`, 1],
  ['workbench.glass.main.js', /([,{;\s(][A-Za-z_$][\w$]*)="No-repo Automations"(?=[,;}])/g, `$1=${JSON.stringify(extra.literals['No-repo Automations'])}`, 0],
];

function checksum(buf) {
  return crypto.createHash('sha256').update(buf).digest('base64').replace(/=+$/, '');
}

function runtimeSnippet(dict) {
  const body = `(()=>{const M=new Map(Object.entries(${JSON.stringify(dict)}));const A=["placeholder","title","aria-label"];` +
    `const t=n=>{const v=n.nodeValue;if(!v)return;const k=v.trim();const z=M.get(k);if(z)n.nodeValue=v.replace(k,z)};` +
    `const e=el=>{for(const a of A){const v=el.getAttribute&&el.getAttribute(a);if(v){const z=M.get(v.trim());if(z)el.setAttribute(a,z)}}};` +
    `const w=r=>{if(r.nodeType===3)return t(r);if(r.nodeType!==1)return;e(r);for(const el of r.querySelectorAll("[placeholder],[title],[aria-label]"))e(el);` +
    `const tw=document.createTreeWalker(r,NodeFilter.SHOW_TEXT);let n;while(n=tw.nextNode())t(n)};` +
    `const s=()=>{w(document.body);new MutationObserver(ms=>{for(const m of ms){if(m.type==="characterData")t(m.target);` +
    `else if(m.type==="attributes")e(m.target);else for(const a of m.addedNodes)w(a)}}).observe(document.body,` +
    `{subtree:!0,childList:!0,characterData:!0,attributes:!0,attributeFilter:A})};` +
    `typeof document!=="undefined"&&(document.body?s():addEventListener("DOMContentLoaded",s))})();`;
  return `\n;${MARK}${body}\n`;
}

const product = path.join(appRoot, 'product.json');
let productText = fs.readFileSync(product, 'utf8');
const touched = new Set();
let failed = false;

for (const name of ['workbench.glass.main.js']) {
  const file = path.join(appRoot, 'out', 'vs', 'workbench', name);
  let text = fs.readFileSync(file, 'utf8');
  if (text.includes(MARK)) { console.log(`= ${name} 已补过，跳过`); continue; }
  for (const [target, re, replacement, min] of literalRules) {
    if (target !== name) continue;
    const hits = (text.match(re) || []).length;
    if (hits < min) { console.log(`! ${name} 没找到 ${re}，Cursor 版本可能变了`); failed = true; continue; }
    if (!hits) continue;
    text = text.replace(re, replacement);
    console.log(`+ ${name} 替换 ${hits} 处：${re.source.slice(0, 40)}`);
  }
  text += runtimeSnippet(extra.runtime);
  fs.writeFileSync(file, text);
  touched.add(`vs/workbench/${name}`);
  console.log(`+ ${name} 加入首页卡片翻译（${Object.keys(extra.runtime).length} 条）`);
}

for (const key of touched) {
  const file = path.join(appRoot, 'out', key);
  const re = new RegExp(`("${key.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}"\\s*:\\s*")([^"]*)(")`);
  if (!re.test(productText)) continue;
  productText = productText.replace(re, (_, a, __, c) => `${a}${checksum(fs.readFileSync(file))}${c}`);
}
if (touched.size) { fs.writeFileSync(product, productText); console.log('+ 安装校验已更新'); }
process.exitCode = failed ? 1 : 0;
