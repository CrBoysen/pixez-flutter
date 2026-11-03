#!/usr/bin/env node
/*
 * 幂等注入器：把 fork/lib/custom 下的定制代码"贴"进上游源码树。
 *
 * 与「打补丁」的区别：
 *   补丁靠上下文精确匹配，上游一动就整段失效；
 *   这里每个注入点只做「在某一行之后插入一段固定代码」，且用独立标记去重，
 *   重复执行不会重复插入，上游小改也不会失配。
 *
 * 任何一个锚点找不到 -> 立刻失败并说清哪个文件哪一行，绝不静默跳过。
 */

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = process.cwd();
const HERE = path.dirname(fileURLToPath(import.meta.url));

const steps = [];
const problems = [];

function read(p) {
  const full = path.join(ROOT, p);
  if (!fs.existsSync(full)) {
    problems.push(`文件不存在: ${p}`);
    return null;
  }
  return fs.readFileSync(full, 'utf8');
}

function write(p, content) {
  fs.writeFileSync(path.join(ROOT, p), content);
}

/** 在 anchor 之后插入 code；该处标记已存在则跳过 */
function injectAfter(file, anchor, code, label, mark) {
  const src = read(file);
  if (src === null) return;
  if (src.includes(mark)) {
    steps.push(`已就位: ${label}`);
    return;
  }
  const idx = src.indexOf(anchor);
  if (idx === -1) {
    problems.push(`锚点丢失: ${file} 找不到 «${anchor.trim()}»（${label}）`);
    return;
  }
  const end = idx + anchor.length;
  write(file, src.slice(0, end) + code + src.slice(end));
  steps.push(`注入: ${label}`);
}

// 1. 落地定制源码
const customSrc = path.join(HERE, 'lib', 'custom', 'r18_only_feed.dart');
const customDst = path.join(ROOT, 'lib', 'custom', 'r18_only_feed.dart');
if (!fs.existsSync(customSrc)) {
  problems.push('配方缺失: fork/lib/custom/r18_only_feed.dart');
} else {
  fs.mkdirSync(path.dirname(customDst), { recursive: true });
  fs.copyFileSync(customSrc, customDst);
  steps.push('复制 lib/custom/r18_only_feed.dart');
}

// 2. LightingStore 两个接管点
injectAfter(
  'lib/lighting/lighting_store.dart',
  "import 'package:pixez/network/api_client.dart';",
  "\nimport 'package:pixez/custom/r18_only_feed.dart'; // MARK:R18ONLY-IMPORT-LS",
  'lighting_store: 引入定制模块',
  'MARK:R18ONLY-IMPORT-LS',
);

injectAfter(
  'lib/lighting/lighting_store.dart',
  'Future<bool> fetch({String? url, bool force = false}) async {',
  '\n    // MARK:R18ONLY-FETCH\n    if (await R18OnlyFeed.interceptFetch(this)) return true;',
  'lighting_store: fetch 接管点',
  'MARK:R18ONLY-FETCH',
);

injectAfter(
  'lib/lighting/lighting_store.dart',
  'Future<bool> fetchNext() async {',
  '\n    // MARK:R18ONLY-NEXT\n    if (await R18OnlyFeed.interceptNext(this)) return true;',
  'lighting_store: fetchNext 接管点',
  'MARK:R18ONLY-NEXT',
);

// 3. 首页开关入口
injectAfter(
  'lib/page/hello/recom/recom_spotlight_page.dart',
  "import 'package:pixez/lighting/lighting_store.dart';",
  "\nimport 'package:pixez/custom/r18_only_feed.dart'; // MARK:R18ONLY-IMPORT-HOME",
  '首页: 引入定制模块',
  'MARK:R18ONLY-IMPORT-HOME',
);

injectAfter(
  'lib/page/hello/recom/recom_spotlight_page.dart',
  '              automaticallyImplyLeading: false,',
  '\n              actions: const [R18OnlyToggle()], // MARK:R18ONLY-ACTION',
  '首页: 右上角开关按钮',
  'MARK:R18ONLY-ACTION',
);

// ------------------------------------------------------------------ 结果
for (const s of steps) console.log('  ' + s);

if (problems.length) {
  console.error('\n注入失败，共 ' + problems.length + ' 处：');
  for (const p of problems) console.error('  ✗ ' + p);
  console.error('\n这通常意味着上游改了相关代码，请核对 fork/apply.mjs 里的锚点。');
  process.exit(1);
}

const lighting = fs.readFileSync(path.join(ROOT, 'lib/lighting/lighting_store.dart'), 'utf8');
const home = fs.readFileSync(path.join(ROOT, 'lib/page/hello/recom/recom_spotlight_page.dart'), 'utf8');
const checks = [
  ['定制源码存在', fs.existsSync(customDst)],
  ['fetch 接管点就位', lighting.includes('interceptFetch(this)')],
  ['fetchNext 接管点就位', lighting.includes('interceptNext(this)')],
  ['首页开关就位', home.includes('R18OnlyToggle()')],
];
let bad = 0;
for (const [name, ok] of checks) {
  console.log(`  ${ok ? '✓' : '✗'} ${name}`);
  if (!ok) bad++;
}
if (bad) process.exit(1);
console.log('\n注入完成，全部校验通过。');
