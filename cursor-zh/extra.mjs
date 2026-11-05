// 在 polang233/cursor-language-pack 装好之后运行，补上它没覆盖的文字。
// 用 Cursor 自带的 Node 运行：
//   ELECTRON_RUN_AS_NODE=1 /Applications/Cursor.app/Contents/MacOS/Cursor extra.mjs [--dir=<Cursor.app/Contents>]
// 只做两件事：
//   1. 精确替换写死在程序里、语言包没碰的字符串（含 extra.zh-cn.json 的 exact 列表）；
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
const supplementDir = path.join(here, 'supplement');
const supplement = {};
for (const f of fs.readdirSync(supplementDir).filter((n) => n.endsWith('.json') && !n.startsWith('.')).sort()) {
  Object.assign(supplement, JSON.parse(fs.readFileSync(path.join(supplementDir, f), 'utf8')));
}

// [文件, 原文正则, 替换, 至少命中次数]
const literalRules = [
  // 语言包新版本已经翻译这句；旧版本没翻时这里补上。
  ['workbench.glass.main.js', /"Plan, Build, \/ for skills, @ for context"/g, JSON.stringify(extra.literals['Plan, Build, / for skills, @ for context']), 0],
  // No Repo 的两个常量都只用作显示名；仓库判断用的是 kind/id，不比较这段文字。
  ['workbench.glass.main.js', /([,{;\s(][A-Za-z_$][\w$]*)="No Repo"(?=[,;}])/g, `$1=${JSON.stringify(extra.literals['No Repo'])}`, 1],
  ['workbench.glass.main.js', /([,{;\s(][A-Za-z_$][\w$]*)="No-repo Automations"(?=[,;}])/g, `$1=${JSON.stringify(extra.literals['No-repo Automations'])}`, 0],
];

// 工具步骤标题、追问输入框等写死的界面文字：[原文, 译文, 命中次数(默认 1)]，次数不对就不换。
// 原文要带上下文，只换显示文字；Cursor 拿来比较的几个 error 标签保持英文。
const exactRules = (extra.exact ?? []).map(([from, to, count = 1]) => ({ from, to, count }));

function checksum(buf) {
  return crypto.createHash('sha256').update(buf).digest('base64').replace(/=+$/, '');
}

// 编辑器、终端、对话内容和输入框里是用户自己的文字，运行时翻译器不进去。
const SKIP = '.monaco-editor,.xterm,[contenteditable],textarea,input,pre,code,.ui-markdown,.markdown-section,.markdown-root,.composer-human-message,.rendered-markdown';

function runtimeSnippet(dict) {
  const body = `(()=>{const M=new Map(Object.entries(${JSON.stringify(dict)}));const A=["placeholder","title","aria-label"];const S=${JSON.stringify(SKIP)};` +
    `const t=n=>{const v=n.nodeValue;if(!v)return;const k=v.trim();const z=M.get(k);if(z&&!n.parentElement?.closest(S))n.nodeValue=v.replace(k,z)};` +
    `const e=el=>{if(el.closest&&el.closest(S)&&!el.matches("input,textarea"))return;for(const a of A){const v=el.getAttribute&&el.getAttribute(a);if(v){const z=M.get(v.trim());if(z)el.setAttribute(a,z)}}};` +
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
const FILES = ['workbench.glass.main.js'];
// 改之前的文件存在这里。语言包只认它自己写出的版本，重装或恢复前要先还原成那个版本。
const backupDir = path.join(process.env.HOME, 'Library', 'Application Support', 'BridgeDock', 'cursor-zh-backup');

if (process.argv.includes('--undo')) {
  for (const name of FILES) {
    const file = path.join(appRoot, 'out', 'vs', 'workbench', name);
    const text = fs.readFileSync(file, 'utf8');
    if (!text.includes(MARK)) continue;
    const backup = path.join(backupDir, name);
    let before;
    if (fs.existsSync(backup)) before = fs.readFileSync(backup, 'utf8');
    else {
      // 没有备份时按改动规则反推：去掉末尾的翻译器，还原两个常量。
      before = exactRules.reduce((s, r) => s.split(r.to).join(r.from), text.slice(0, text.indexOf(`\n;${MARK}`)))
        .replace(new RegExp(`([,{;\\s(][A-Za-z_$][\\w$]*)=${JSON.stringify(extra.literals['No-repo Automations'])}(?=[,;}])`, 'g'), '$1="No-repo Automations"')
        .replace(new RegExp(`([,{;\\s(][A-Za-z_$][\\w$]*)=${JSON.stringify(extra.literals['No Repo'])}(?=[,;}])`, 'g'), '$1="No Repo"');
    }
    fs.writeFileSync(file, before);
    fs.rmSync(backup, { force: true });
    touched.add(`vs/workbench/${name}`);
    console.log(`- ${name} 已去掉补充改动`);
  }
}

for (const name of process.argv.includes('--undo') ? [] : FILES) {
  const file = path.join(appRoot, 'out', 'vs', 'workbench', name);
  let text = fs.readFileSync(file, 'utf8');
  if (text.includes(MARK)) { console.log(`= ${name} 已补过，跳过`); continue; }
  fs.mkdirSync(backupDir, { recursive: true });
  fs.writeFileSync(path.join(backupDir, name), text);
  for (const [target, re, replacement, min] of literalRules) {
    if (target !== name) continue;
    const hits = (text.match(re) || []).length;
    if (hits < min) { console.log(`! ${name} 没找到 ${re}，Cursor 版本可能变了`); failed = true; continue; }
    if (!hits) continue;
    text = text.replace(re, replacement);
    console.log(`+ ${name} 替换 ${hits} 处：${re.source.slice(0, 40)}`);
  }
  if (name === 'workbench.glass.main.js') {
    let done = 0;
    for (const { from, to, count } of exactRules) {
      const hits = text.split(from).length - 1;
      if (hits !== count || text.includes(to)) { console.log(`! ${name} 中 ${from.slice(0, 50)} 出现 ${hits} 次（应为 ${count}），跳过`); failed = true; continue; }
      text = text.split(from).join(to);
      done++;
    }
    console.log(`+ ${name} 精确替换界面文字 ${done}/${exactRules.length} 条`);
  }
  // 语言包只换固定字段里的文字。补充译文里仍以英文留在程序里的整句，交给运行时
  // 按整段文字精确匹配翻译；只包含至少两个词的句子，避免误换按钮 ID 一类的短词。
  const leftovers = {};
  for (const [k, v] of Object.entries(supplement)) {
    if (v && v !== k && /\s/.test(k.trim()) && text.includes(JSON.stringify(k))) leftovers[k] = v;
  }
  text += runtimeSnippet({ ...leftovers, ...extra.runtime });
  fs.writeFileSync(file, text);
  touched.add(`vs/workbench/${name}`);
  console.log(`+ ${name} 加入运行时翻译（首页卡片 ${Object.keys(extra.runtime).length} 条，补充译文 ${Object.keys(leftovers).length} 条）`);
}

for (const key of touched) {
  const file = path.join(appRoot, 'out', key);
  const re = new RegExp(`("${key.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}"\\s*:\\s*")([^"]*)(")`);
  if (!re.test(productText)) continue;
  productText = productText.replace(re, (_, a, __, c) => `${a}${checksum(fs.readFileSync(file))}${c}`);
}
if (touched.size) { fs.writeFileSync(product, productText); console.log('= 安装校验已更新'); }
process.exitCode = failed ? 1 : 0;
