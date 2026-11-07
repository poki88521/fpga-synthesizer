/* ===========================================================================
   test_logic.js —— MIDI 串口调试器核心逻辑自测（Node，无需浏览器）

   做法：把 index.html 里的 <script> 抽出来，在带假 DOM 的沙箱里求值，
   然后对纯逻辑部分断言 —— 消息字节、音高换算、日志解析、timbre_slot 映射。

   需要一个极简的假 DOM，因为脚本在顶层就会取元素；这里用一张宽松的桩表糊过去，
   被测的都是不依赖 DOM 的纯函数。

   运行：
     node test_logic.js
   =========================================================================== */
'use strict';
const fs = require('fs');
const vm = require('vm');
const path = require('path');

const HTML = path.join(__dirname, 'index.html');

/* ---------------- 极简假 DOM ----------------
   ⚠ 会记录 addEventListener 与 querySelectorAll，用来检查"按钮到底有没有接上线"。
     曾经出现过 connect()/disconnect() 函数写好了但没绑到按钮上，
     点「连接串口」毫无反应 —— 页面看起来正常，纯靠肉眼看代码很难发现。 */
let fakeSeq = 0;
function mkEl(id) {
  return {
    id: id || ('anon' + (++fakeSeq)),
    _listeners: {},                       // { click: [fn], input: [fn], ... }
    _children: [],                        // 记下来，测试里可以读"日志内容"
    style: {}, dataset: {}, classList: { add(){}, remove(){} },
    value: '', textContent: '', innerHTML: '', className: '', title: '',
    disabled: false, checked: true, scrollTop: 0, scrollHeight: 0, clientHeight: 0,
    files: [],
    addEventListener(type, fn){ (this._listeners[type] = this._listeners[type] || []).push(fn); },
    removeEventListener(){},
    appendChild(c){ this._children.push(c); return c; },
    dispatchEvent(){},
    click(){ this._clicked = (this._clicked || 0) + 1; },
    remove(){},
    onclick: null, oninput: null
  };
}

/* 把假 DOM 里一个容器的内容拼成纯文本（用来读日志区实际写了什么） */
function textOf(elm) {
  if (!elm) return '';
  return (elm._children || []).map(c => textOf(c) || c.textContent || '').join('');
}

const HTML_SRC = fs.readFileSync(HTML, 'utf8');
const SCRIPT = (() => {
  const m = HTML_SRC.match(/<script>([\s\S]*?)<\/script>/);
  if (!m) { console.error('FAIL: index.html 里找不到 <script> 块'); process.exit(1); }
  return m[1];
})();

const EXPORTS = ['msgNoteOn','msgNoteOff','msgCC','msgPC',
                 'noteName','noteToHz','hzToNote','describe','splitMessages',
                 'clampInt','connBlocker','baudInfo','parseSequence','parseNoteToken','NAMES',
                 /* 面板 10「指令检查」：切分（含运行状态）+ 校验器 + 自检用例表 */
                 'parseStream','midiCheck','SELFTEST_CASES','runSelfTest','CC_SUPPORTED',
                 /* 面板 4 / 5 / 6：弯音、CC 滑杆表、和弦齐发 */
                 'msgBend','BEND_CENTER','BEND_MAX','BEND_RANGE_SEMI','bendSemiText',
                 'CC_ROWS_EXPR','mxCtl','MX_MIX_ONLY','setMxMixEnabled','chordNotes','chordBytes',
                 /* 面板 11 / 12：一键演示、打点统计 */
                 'DEMO_STAGES',
                 /* 面板 13 / 14：ADSR 包络、预设 */
                 'envSegments','TIMBRE_TABLE','ENV_FS',
                 'collectPreset','applyPreset','validatePreset','PRESET_APP',
                 /* 面板 3：8 个音色槽的名字 */
                 'TIMBRE_NAMES',
                 /* 面板 15：杂项（CC120 / 两种 SysEx） */
                 'sysexFxBytes','sysexMasterBytes','SYSEX_FX_GRP_NAMES',
                 /* 布局：日志区高度夹取 */
                 'clampLogHeight'];
const PROBE = `\n;globalThis.__X = {${EXPORTS.join(',')}};`;

/* 在指定环境下把脚本跑起来。
   返回 { X, byId, selectors, query }：
     X         —— 脚本导出的纯函数
     byId      —— 每个 element id 对应的假元素（含 _listeners）
     selectors —— querySelectorAll 被调用过的选择器
     query     —— 按选择器拿「页面里那批元素」（与脚本自己拿到的是同一批对象），
                  这样测试才能"点" [data-preset] / [data-chord] 这些没 id 的按钮
   opts.requestPort 可传入假的 requestPort，用来驱动「连接 → 发消息」的完整链路。 */
function loadDebugger(opts) {
  const o = Object.assign({ protocol: 'http:', secure: true, serial: true }, opts || {});
  const byId = {};
  const selectors = [];
  const selCache = {};

  /* 从 index.html 文本里还原那几组"没有 id、靠属性选择"的按钮 */
  function buildSel(sel) {
    const grab = (attr) => [...HTML_SRC.matchAll(new RegExp(attr + '="([^"]+)"', 'g'))].map(m => {
      const e = mkEl();
      // data-preset → dataset.preset（DOM 的 dataset 用的是去掉 data- 前缀的驼峰名）
      const key = attr.replace(/^data-/, '').replace(/-([a-z])/g, (_, c) => c.toUpperCase());
      e.dataset = {};
      e.dataset[key] = m[1];
      return e;
    });
    if (sel === '[data-preset]') return grab('data-preset');
    if (sel === '[data-chord]')  return grab('data-chord');
    if (sel === '[data-note]')   return grab('data-note');
    if (sel === '[data-fold] > h2'){
      // 给可折叠面板还原「标题 → 所属 section」的关系（折叠时要改 section 的 class）
      return [...HTML_SRC.matchAll(/<section class="([^"]*)"[^>]*\bdata-fold\b[^>]*>\s*<h2>([^<]*)<\/h2>/g)].map(m => {
        const sec = mkEl();
        sec.className = m[1];
        const h = mkEl();
        h.textContent = m[2];
        h.parentNode = sec;
        return h;
      });
    }
    if (sel === '#panelFlow > section[data-cat]'){
      return [...HTML_SRC.matchAll(/<section class="panel[^"]*"[^>]*\bdata-cat="([^"]+)"[^>]*>/g)]
        .map(m => { const e = mkEl(); e.dataset = { cat: m[1] }; return e; });
    }
    if (sel === '[data-catbtn]'){
      return [...HTML_SRC.matchAll(/data-catbtn="([^"]+)"/g)]
        .map(m => { const e = mkEl(); e.dataset = { catbtn: m[1] }; return e; });
    }
    if (sel === '[data-seq]'){
      return [...HTML_SRC.matchAll(/data-seq="([^"]+)"/g)]
        .map(m => { const e = mkEl(); e.dataset = { seq: m[1] }; return e; });
    }
    if (sel === 'input[name=pmode]')
      return ['instrument', 'mixer'].map(v => { const e = mkEl(); e.value = v; e.checked = (v === 'instrument'); return e; });
    return [];
  }
  const query = sel => selCache[sel] || (selCache[sel] = buildSel(sel));
  // 端口模式：真实页面读的是 :checked 那个 radio，这里用一个可变的共享对象模拟
  const pmodeState = { value: 'instrument', checked: true };

  const sb = {
    console,
    Event: class { constructor(t){ this.type = t; } },
    setTimeout, clearTimeout,                       // sleepMs / waitUntil 要用
    performance: o.performance || ((typeof performance !== 'undefined') ? performance : { now: () => Date.now() }),
    document: {
      getElementById(id){ return byId[id] || (byId[id] = mkEl(id)); },
      querySelector(sel){
        if (String(sel).indexOf('pmode') >= 0) return pmodeState;
        const e = mkEl(); e.value = 'instrument'; return e;
      },
      querySelectorAll(sel){ selectors.push(sel); return query(sel); },
      createElement(){ return mkEl(); },
      body: { appendChild(){}, removeChild(){}, style: {} },
      addEventListener(type, fn){ (this._l = this._l || {})[type] = fn; },
      createRange(){ return { selectNodeContents(){} }; },
      getSelection(){ return { removeAllRanges(){}, addRange(){} }; }
    },
    location: { protocol: o.protocol },
    navigator: o.serial
      ? { serial: { requestPort: o.requestPort || (async () => { throw new Error('test: 未提供 requestPort'); }) } }
      : {}
  };
  sb.globalThis = sb;
  sb.window = sb;
  sb.isSecureContext = o.secure;
  // 页面里用的是裸的 getSelection()（window 上的那个），不是 document.getSelection()
  sb.getSelection = () => ({ removeAllRanges(){}, addRange(){} });

  vm.createContext(sb);
  try {
    vm.runInContext(SCRIPT + PROBE, sb, { filename: 'index.html<script>' });
  } catch (e) {
    console.error('FAIL: 脚本求值抛异常 →', e.message);
    console.error('      （这通常意味着 index.html 里的 JS 有语法错误或初始化就崩了）');
    console.error(`      环境：protocol=${o.protocol} secure=${o.secure} serial=${o.serial}`);
    process.exit(1);
  }
  return { X: sb.__X, byId, selectors, query, pmode: pmodeState };
}

const app = loadDebugger();
const X = app.X;
const Xof = opts => loadDebugger(opts).X;      // 换环境重跑一遍，只要导出对象

/* ---------------- 断言框架 ---------------- */
let pass = 0, fail = 0;
const eq = (got, want, label) => {
  const g = JSON.stringify(got), w = JSON.stringify(want);
  if (g === w) { pass++; }
  else { fail++; console.error(`FAIL ${label}\n     期望 ${w}\n     实为 ${g}`); }
};
const ok = (cond, label) => {
  if (cond) { pass++; } else { fail++; console.error(`FAIL ${label}`); }
};
const near = (got, want, tol, label) => {
  if (Math.abs(got - want) <= tol) { pass++; }
  else { fail++; console.error(`FAIL ${label}\n     期望 ${want} ±${tol}\n     实为 ${got}`); }
};

/* =================== 1. MIDI 消息构造 =================== */
// 状态字节 = 基址 | 通道号(0-15)
eq(X.msgNoteOn(0, 60, 100), [0x90, 60, 100], 'Note On 通道1 中央C 力度100');
eq(X.msgNoteOn(15, 127, 0), [0x9F, 127, 0], 'Note On 通道16 最高音 力度0');
eq(X.msgNoteOff(0, 60, 64), [0x80, 60, 64], 'Note Off 通道1');
eq(X.msgNoteOff(15, 0, 64), [0x8F, 0, 64], 'Note Off 通道16 最低音');
eq(X.msgCC(0, 0, 0),       [0xB0, 0, 0],    'CC0 (Bank MSB)');
eq(X.msgCC(3, 32, 127),    [0xB3, 32, 127], 'CC32 (Bank LSB) 通道4');
eq(X.msgPC(0, 5),          [0xC0, 5],       'Program Change（只有 2 字节）');
eq(X.msgPC(9, 127),        [0xC9, 127],     'Program Change 通道10');

// 越界值必须被夹到 7 位，否则会污染状态字节
eq(X.msgNoteOn(0, 200, 300), [0x90, 200 & 0x7F, 300 & 0x7F], 'Note On 越界值按 7 位截断');
ok(X.msgCC(0, 7, 200)[2] <= 127, 'CC 值不会超过 127（状态字节不被污染）');

// 音色三连发：顺序固定 CC0 → CC32 → Program，共 8 字节
const timbre = [...X.msgCC(0, 0, 0), ...X.msgCC(0, 32, 0), ...X.msgPC(0, 0)];
eq(timbre, [0xB0,0,0, 0xB0,32,0, 0xC0,0], '选音色 = CC0→CC32→Program 连续 8 字节');
eq(timbre.length, 8, '选音色消息总长度 8 字节');
// 逐条核对三块，顺序不能反（规范要求 CC0 → CC32 → Program）
eq(timbre.slice(0, 3), [0xB0, 0, 0],  '第 1 条 = CC0 (Bank MSB)');
eq(timbre.slice(3, 6), [0xB0, 32, 0], '第 2 条 = CC32 (Bank LSB)，顺序不能反');
eq(timbre.slice(6, 8), [0xC0, 0],     '第 3 条 = Program Change');
eq(timbre[6] & 0xF0, 0xC0, '最后一条必须是 Program Change（否则库号不会生效）');

/* =================== 2. 音高换算 =================== */
eq(X.noteName(0),   'C-1', '音符号 0 → C-1');
eq(X.noteName(60),  'C4',  '音符号 60 → C4');
eq(X.noteName(69),  'A4',  '音符号 69 → A4');
eq(X.noteName(127), 'G9',  '音符号 127 → G9');
eq(X.noteName(61),  'C#4', '升号写法');
near(X.noteToHz(69), 440, 1e-9, 'A4 = 440 Hz');
near(X.noteToHz(60), 261.6255653, 1e-6, 'C4 = 261.626 Hz');
near(X.noteToHz(0),  8.1757989,  1e-6, '音符号 0 = 8.176 Hz');
near(X.hzToNote(440), 69, 1e-9, '440 Hz → 音符号 69');
near(X.hzToNote(261.6255653), 60, 1e-6, '261.626 Hz → 音符号 60');

// 全 128 个音：note → Hz → note 必须原样回来（双向换算自洽）
let rt = 0;
for (let n = 0; n < 128; n++) {
  if (Math.round(X.hzToNote(X.noteToHz(n))) !== n) rt++;
}
eq(rt, 0, '128 个音符号的 Hz 往返换算全部自洽');

// 音名无越界
let badName = 0;
for (let n = 0; n < 128; n++) if (!/^[A-G]#?-?\d+$/.test(X.noteName(n))) badName++;
eq(badName, 0, '128 个音名格式全部合法');

/* =================== 3. 日志解析 =================== */
ok(X.describe([0x90,60,100]).includes('Note On'),   'describe: Note On');
ok(X.describe([0x90,60,100]).includes('C4'),        'describe: 含音名');
ok(X.describe([0x90,60,100]).includes('100'),       'describe: 含力度');
ok(X.describe([0x90,60,0]).includes('Note Off'),    'describe: 力度0 的 Note On 应提示等价 Note Off');
ok(X.describe([0x80,60,64]).includes('Note Off'),   'describe: Note Off');
ok(X.describe([0xB0,0,5]).includes('Bank Select MSB'), 'describe: CC0 名称');
ok(X.describe([0xB0,32,5]).includes('Bank Select LSB'),'describe: CC32 名称');
ok(X.describe([0xB0,7,100]).includes('CC7'),        'describe: CC7 名称');
ok(X.describe([0xC0,16]).includes('Program Change'),'describe: Program Change');
ok(X.describe([0xC0,16]).includes('16'),            'describe: 音色号');
ok(X.describe([0xE0,0,64]).includes('8192'),        'describe: Pitch Bend 中心值');
ok(X.describe([0xF0]).includes('SysEx'),            'describe: SysEx 开始');

/* =================== 4. 消息切分 =================== */
eq(X.splitMessages([]), [], 'splitMessages: 空数组');
eq(X.splitMessages([0x90,60,100]), [[0x90,60,100]], 'splitMessages: 单条 Note On');
eq(X.splitMessages([0xC0,5]), [[0xC0,5]], 'splitMessages: Program Change 是 2 字节');

// ⚠ 关键：PC 只有 1 个数据字节。若误按 3 字节切，会把下一条的状态字节吃掉。
eq(X.splitMessages([0xC0,5,0x90,60,100]), [[0xC0,5],[0x90,60,100]],
   'splitMessages: PC 后面紧跟 Note On 不能被吞掉状态字节');
eq(X.splitMessages([0xD0,40,0xB0,7,100]), [[0xD0,40],[0xB0,7,100]],
   'splitMessages: 通道压力(0xDn) 也是 2 字节');

// 三连发必须切成 3 条
const parts = X.splitMessages(timbre);
eq(parts.length, 3, 'splitMessages: 选音色切出 3 条消息');
eq(parts.map(p => p.length), [3,3,2], 'splitMessages: 三条长度 3/3/2');
eq(parts[2], [0xC0,0], 'splitMessages: 第 3 条是 Program Change');

// SysEx 切到 F7 为止
eq(X.splitMessages([0xF0,0x7E,0x7F,0x09,0x01,0xF7]),
   [[0xF0,0x7E,0x7F,0x09,0x01,0xF7]], 'splitMessages: SysEx 按 F7 收尾');
eq(X.splitMessages([0xF0,0x7F,0x7F,0x04,0x01,0x00,0x40,0xF7,0x90,60,100]).length, 2,
   'splitMessages: SysEx 之后还能切出后续消息');

// 实时字节（0xF8）单字节成组
eq(X.splitMessages([0xF8,0x90,60,100]), [[0xF8],[0x90,60,100]],
   'splitMessages: 实时字节单字节成组');

/* =================== 5. 输入夹取 =================== */
eq(X.clampInt('60', 0, 127, 0), 60,  'clampInt 正常值');
eq(X.clampInt('999', 0, 127, 0), 127, 'clampInt 上限');
eq(X.clampInt('-5', 0, 127, 0), 0,   'clampInt 下限');
eq(X.clampInt('abc', 0, 127, 9), 9,  'clampInt 非数字回落默认值');
eq(X.clampInt('', 0, 127, 9), 9,     'clampInt 空串回落默认值');

/* =================== 5. timbre_slot 映射（恒定等式） =================== */
// 本期是恒等映射 timbre_slot = program & 7
const slotOf = p => p & 7;
eq(slotOf(0), 0, 'prog 0 → 槽 0（钢琴）');
eq(slotOf(1), 1, 'prog 1 → 槽 1（吉他）');
eq(slotOf(7), 7, 'prog 7 → 槽 7');
eq(slotOf(8), 0, 'prog 8 → 槽 0（回绕）');
eq(slotOf(127), 7, 'prog 127 → 槽 7');

/* =================== 6. 连接环境诊断（connBlocker） =================== */
// 这段逻辑决定界面顶部给什么提示，每种拦路原因的修法都不同，所以要逐种验。
const okEnv = X.connBlocker();
eq(okEnv, null, '环境正常（http + 安全上下文 + 有 Web Serial）→ 不报错');

const fileEnv = Xof({ protocol: 'file:' }).connBlocker();
ok(fileEnv && fileEnv.level === 'err', 'file:// 打开 → 判为不可连接');
ok(fileEnv && fileEnv.html.includes('file://'), 'file:// 提示里点明 file://');
ok(fileEnv && fileEnv.html.includes('start.cmd'), 'file:// 提示里给出正确改法（start.cmd）');

const insecureEnv = Xof({ secure: false }).connBlocker();
ok(insecureEnv && insecureEnv.level === 'err', '非安全上下文 → 判为不可连接');
ok(insecureEnv && insecureEnv.html.includes('安全上下文'), '非安全上下文提示里点明原因');
ok(insecureEnv && insecureEnv.html.includes('127.0.0.1'), '非安全上下文提示里给出 127.0.0.1');

const noSerialEnv = Xof({ serial: false }).connBlocker();
ok(noSerialEnv && noSerialEnv.level === 'err', '浏览器没有 Web Serial → 判为不可连接');
ok(noSerialEnv && noSerialEnv.html.includes('Chrome'), '不支持 Web Serial 时提示换 Chrome/Edge');

// 优先级：file:// 要排在"没有 Web Serial"之前 —— 因为 file:// 下 navigator.serial 本来就没有，
// 若顺序反了，用户双击 index.html 时只会看到"换浏览器"，永远修不好。
const fileAndNoSerial = Xof({ protocol: 'file:', serial: false, secure: false }).connBlocker();
ok(fileAndNoSerial && fileAndNoSerial.html.includes('file://'),
   'file:// 且无 Web Serial 时，优先报 file:// 而不是"换浏览器"（否则永远修不好）');

// 三种环境下脚本都必须能正常初始化（不能崩）
ok(!!loadDebugger({ protocol: 'file:' }).X, 'file:// 环境下初始化不崩');
ok(!!loadDebugger({ serial: false }).X, '无 Web Serial 环境下初始化不崩');
ok(!!loadDebugger({ secure: false }).X, '非安全上下文下初始化不崩');

/* =================== 7. 界面接线（按钮必须真的绑上事件） =================== */
// 这一节是为了拦住一类"页面看着正常、点下去毫无反应"的 bug：
// 处理函数写好了，但忘了 addEventListener。
{
  // HTML 里所有带 id 的 <button>
  const buttonIds = [...HTML_SRC.matchAll(/<button\b[^>]*\bid="([^"]+)"/g)].map(m => m[1]);
  ok(buttonIds.length >= 8, `HTML 里找到 ${buttonIds.length} 个带 id 的按钮（数量是否合理）`);

  const noHandler = buttonIds.filter(id => {
    const e = app.byId[id];
    return !e || !e._listeners || !e._listeners.click || e._listeners.click.length === 0;
  });
  eq(noHandler, [], `每个带 id 的按钮都必须绑了 click（漏绑的：${noHandler.join(', ') || '无'}）`);

  // 用属性选择的按钮组（没有 id），确认脚本确实去查过这些选择器
  ok(app.selectors.includes('[data-preset]'), '音色预设按钮组被查询过（[data-preset]）');
  ok(app.selectors.includes('[data-note]'),   '音准快捷键按钮组被查询过（[data-note]）');
  ok(app.selectors.some(s => s.includes('pmode')), '端口模式单选框被查询过');

  // 关键输入控件也要有监听，否则"改了没反应"
  const needInput = { note:'input', freq:'input', vel:'input', velNum:'input', prog:'input',
                      baud:'change', baudCustom:'input', hold:'change', rawHex:'keydown',
                      seqInput:'input', seqDur:'input', seqGap:'input' };
  for (const [id, ev] of Object.entries(needInput)) {
    const e = app.byId[id];
    ok(!!(e && e._listeners[ev] && e._listeners[ev].length),
       `#${id} 必须绑了 ${ev} 监听`);
  }

  // 通道已合并：原来的两个独立通道输入框必须消失，只留一个全局的
  ok(!HTML_SRC.includes('id="chTimbre"') && !HTML_SRC.includes('id="chNote"'),
     '音色/音符各自的通道输入框已移除（合并为全局通道）');
  ok(HTML_SRC.includes('id="midiCh"'), '存在全局通道输入框 #midiCh');
}

/* =================== 8. 结构完整性审计（静态检查） ===================
   这一节不测功能，专门找「代码写好了但没接上」这类肉眼难发现的错。 */
{
  // HTML 里所有 id
  const htmlIds = [...HTML_SRC.matchAll(/\bid="([^"]+)"/g)].map(m => m[1]);

  // (1) 重复 id —— 重复会让 getElementById 只拿到第一个，另一个永远失效
  const dup = [...new Set(htmlIds.filter((v, i) => htmlIds.indexOf(v) !== i))];
  eq(dup, [], `HTML 里不能有重复 id（重复：${dup.join(', ') || '无'}）`);

  // (2) JS 里 $('...') 引用的 id 必须都真实存在，否则 el.xxx 是 null，一用就崩
  const refIds = [...new Set([...SCRIPT.matchAll(/\$\('([^']+)'\)/g)].map(m => m[1]))];
  const missingIds = refIds.filter(id => !htmlIds.includes(id));
  eq(missingIds, [], `JS 引用的 id 必须都存在于 HTML（缺失：${missingIds.join(', ') || '无'}）`);

  // (3) el.xxx 用到的键必须在 el 对象的定义里 —— 拼错一个字母就是运行时 TypeError
  const elBlock = SCRIPT.match(/const el = \{([\s\S]*?)\n\};/);
  const elKeys = elBlock ? [...elBlock[1].matchAll(/(?:^|,)\s*(\w+)\s*:/g)].map(m => m[1]) : [];
  ok(elKeys.length >= 20, `el 对象里定义了 ${elKeys.length} 个键`);
  const elUsed = [...new Set([...SCRIPT.matchAll(/\bel\.(\w+)/g)].map(m => m[1]))];
  const elUndef = elUsed.filter(k => !elKeys.includes(k));
  eq(elUndef, [], `el.xxx 用到的键必须都定义过（未定义：${elUndef.join(', ') || '无'}）`);

  // (4) 顶层函数不能是死代码 —— 这正是「函数写好了却忘了绑到按钮上」的特征：
  //     connect / disconnect 当初就只出现在自己的定义里。
  const fnNames = [...SCRIPT.matchAll(/^\s*(?:async\s+)?function\s+(\w+)\s*\(/gm)].map(m => m[1]);
  ok(fnNames.length >= 12, `找到 ${fnNames.length} 个顶层函数`);
  const dead = fnNames.filter(n => {
    const c = (SCRIPT.match(new RegExp('\\b' + n + '\\b', 'g')) || []).length;
    return c <= 1;                     // 只出现在定义处
  });
  eq(dead, [], `不能有"定义了却从未被引用"的函数（死代码：${dead.join(', ') || '无'}）`);

  // (5) 用属性选择的按钮组，选择器必须能在 HTML 里找到对应元素
  for (const sel of ['[data-preset]', '[data-note]']) {
    const attr = sel.slice(1, -1);
    ok(HTML_SRC.includes(attr + '='), `HTML 里应存在 ${attr} 元素（供 ${sel} 选择）`);
  }
}

/* =================== 9. 波特率校验（不能把 NaN / 0 喂给 port.open） =================== */
{
  const setBaud = (sel, custom) => {
    app.byId['baud'].value = sel;
    app.byId['baudCustom'].value = custom;
  };

  setBaud('31250', '31250');
  ok(X.baudInfo().ok, '下拉档位 31250 → 有效');
  eq(X.baudInfo().n, 31250, '下拉档位取到正确的数值');

  setBaud('115200', '31250');
  ok(X.baudInfo().ok, '下拉档位 115200 → 有效（非 31250 但合法）');

  setBaud('custom', '115200');   ok(X.baudInfo().ok,   '自定义 115200 → 有效');
  setBaud('custom', '300');      ok(X.baudInfo().ok,   '自定义下边界 300 → 有效');
  setBaud('custom', '3000000');  ok(X.baudInfo().ok,   '自定义上边界 3000000 → 有效');

  // 这些都是"不改就会以 NaN/0 去 open()"的输入
  for (const bad of ['', '   ', 'abc', '0', '-1', 'NaN', 'Infinity', '999999999', '31250.5', '1e9']) {
    setBaud('custom', bad);
    ok(!X.baudInfo().ok, `自定义波特率 "${bad}" 必须判为无效`);
  }

  // 无效时 n 不能被当成可用值使用
  setBaud('custom', 'abc');
  ok(Number.isNaN(X.baudInfo().n) || !X.baudInfo().ok, '无效输入不会产出可用的数值');
}

/* =================== 10. 音符序列解析 =================== */
{
  const P = (t, d) => X.parseSequence(t, d === undefined ? 300 : d);
  const notes = r => r.items.map(x => x.note);
  const durs  = r => r.items.map(x => x.dur);

  // --- 音名解析：科学音高记号 ---
  eq(X.parseNoteToken('60'), 60,        '数字音符号');
  eq(X.parseNoteToken('0'), 0,          '下边界 0');
  eq(X.parseNoteToken('127'), 127,      '上边界 127');
  eq(X.parseNoteToken('128'), null,     '超范围 128 → 认不出');
  eq(X.parseNoteToken('C4'), 60,        'C4 = 60');
  eq(X.parseNoteToken('A4'), 69,        'A4 = 69');
  eq(X.parseNoteToken('C-1'), 0,        'C-1 = 0（最低）');
  eq(X.parseNoteToken('G9'), 127,       'G9 = 127（最高）');
  eq(X.parseNoteToken('c4'), 60,        '小写 c4 也认');
  eq(X.parseNoteToken('F#3'), 54,       '升号 F#3');
  eq(X.parseNoteToken('Bb5'), 82,       '降号 Bb5');
  eq(X.parseNoteToken('G#9'), null,     'G#9 超范围 → 认不出');
  eq(X.parseNoteToken('H4'), null,      'H 不是音名');
  eq(X.parseNoteToken('C'), null,       '缺八度');
  eq(X.parseNoteToken('4C'), null,      '顺序写反');
  eq(X.parseNoteToken(''), null,        '空串');

  // --- 序列解析 ---
  let r = P('C4 D4 E4');
  eq(notes(r), [60, 62, 64], '音名序列');
  eq(durs(r), [300, 300, 300], '默认时长生效');
  eq(r.errors, [], '无错误');

  r = P('60:150 62:250');
  eq(notes(r), [60, 62], '纯数字序列');
  eq(durs(r), [150, 250], '逐个指定时长');

  r = P('C4:600', 300);
  eq(durs(r), [600], '单独时长覆盖默认值');

  r = P('- -:200 C4');
  eq(notes(r), [-1, -1, 60], '休止符记为 note = -1');
  eq(durs(r), [300, 200, 300], '休止符也能指定时长');

  // ⚠ 全角标点：中文输入法下极易打出，不认的话用户会以为功能坏了
  r = P('C4：500 D4');
  eq(durs(r), [500, 300], '全角冒号「：」能认');
  r = P('C4，D4');
  eq(notes(r), [60, 62], '全角逗号「，」能认');
  r = P('C4、D4；E4');
  eq(notes(r), [60, 62, 64], '顿号「、」与分号「；」能当成分隔符');
  r = P('C4　D4');
  eq(notes(r), [60, 62], '全角空格能当分隔符');

  r = P('  ');
  eq(r.items, [], '空白输入 → 无音符');
  eq(r.errors, [], '空白输入不报错');

  // --- 错误处理：不能静默吞掉，也不能让整串作废 ---
  r = P('C4 H4 D4');
  eq(notes(r), [60, 62], '认不出的项被跳过，其他项照常');
  eq(r.errors.length, 1, '认不出的项要记账');

  r = P('C4:0');
  eq(r.items, [], '时长 0 不合法');
  eq(r.errors.length, 1, '时长 0 要报错');

  r = P('C4:abc');
  eq(r.errors.length, 1, '非数字时长要报错');

  r = P('C4:-5');
  eq(r.errors.length, 1, '负时长要报错');

  r = P('C4:99999999');
  eq(notes(r), [60], '超长时长本身仍可解析（由上层夹取）');

  // --- 逐音力度 @ ---
  eq(P('C4').items[0].vel, null, '不写 @ 时 vel = null（用全局力度）');
  eq(P('C4@20').items[0].vel, 20, '逐音力度 @20');
  eq(P('C4@0').items[0].vel, 0, '逐音力度可以是 0');
  eq(P('C4@127').items[0].vel, 127, '逐音力度上边界 127');

  r = P('C4:500@60');
  eq(notes(r), [60], '@ 与时长可以同时写');
  eq(durs(r), [500], '同时写时长的值正确');
  eq(r.items[0].vel, 60, '同时写力度的值正确');

  r = P('C4@128');
  eq(r.items, [], '力度 128 越界 → 整项作废');
  eq(r.errors.length, 1, '力度越界要报错');

  eq(P('C4@-1').errors.length, 1, '负力度要报错');
  eq(P('C4@abc').errors.length, 1, '非数字力度要报错');
  eq(P('C4@1@2').errors.length, 1, '"@" 出现两次要报错');
  eq(P('C4@').items[0].vel, null, '"@" 后面留空视为没写（用全局）');

  // 力度扫描用的那串必须能解析成 5 个音、力度递增
  r = P('C4@20 C4@50 C4@80 C4@110 C4@127');
  eq(r.errors, [], '力度扫描序列无解析错误');
  eq(r.items.map(x => x.vel), [20, 50, 80, 110, 127], '力度扫描的 5 个力度正确');
  eq(r.items.map(x => x.note), [60, 60, 60, 60, 60], '力度扫描都是同一个音');
}

/* =================== 11. 补全的消息解析（0xA0 / 0xD0） =================== */
ok(X.describe([0xA0, 60, 50]).includes('复音触后'), 'describe: Poly Key Pressure (0xA0)');
ok(X.describe([0xA0, 60, 50]).includes('C4'),       'describe: 触后含音名');
ok(X.describe([0xD0, 50]).includes('通道触后'),      'describe: Channel Pressure (0xD0)');
eq(X.splitMessages([0xD0, 40, 0xB0, 7, 100]), [[0xD0,40],[0xB0,7,100]],
   'splitMessages: 0xDn 是 2 字节，不会吞掉下一条');

/* =================== 12. 端到端：拖力度滑杆 → 真的改变发出的字节 ===================
   这一节走完整链路：假串口 → 点「连接串口」→ 拖滑杆 → 点「Note On」→ 检查写入的字节。
   用户报「力度滑杆没功能」，只有走到字节这一层才能分清是 UI 问题还是别的问题。 */
async function sectionEndToEnd() {
  const writes = [];
  const mkWriter = () => ({ write: async u8 => { writes.push([...u8]); }, releaseLock(){} });
  const fakePort = {
    open: async () => {}, close: async () => {}, releaseLock(){},
    writable: { getWriter: () => mkWriter() },
    getInfo: () => ({ usbVendorId: 0x1A86, usbProductId: 0x7523 })
  };

  const a = loadDebugger({ requestPort: async () => fakePort });
  const b = a.byId;
  const fire = (id, ev) => { const e = b[id]; ok(!!(e && e._listeners[ev]), `#${id} 的 ${ev} 监听存在`); return e._listeners[ev][0](); };
  // 假 DOM 不会从 HTML 的 selected/value 属性取初值，这里显式补上（真实浏览器里由 HTML 提供）
  b['baud'].value = '31250';
  b['baudCustom'].value = '31250';
  ok(a.X.baudInfo().ok, '端到端前置：波特率有效');

  // --- 连接 ---
  b['midiCh'].value = '1';
  b['note'].value = '60';
  b['velNum'].value = '100';
  b['vel'].value = '100';
  await b['btnConn']._listeners.click[0]();
  if (b['connState'].textContent !== '已连接'){
    console.error('  [调试] 连接没成功，日志区内容是：');
    console.error('         ' + textOf(b['log']).replace(/\s*\n\s*/g, ' | '));
  }
  ok(b['connState'].textContent === '已连接', '端到端：连接后状态变成「已连接」');

  // --- 力度 100 时按 Note On ---
  const nBefore = writes.length;
  await b['btnOn']._listeners.click[0]();
  let last = writes[writes.length - 1];
  ok(Array.isArray(last), '端到端：Note On 确实往串口写了字节');
  eq(last, [0x90, 60, 100], '端到端：力度 100 → Note On 字节 90 3C 64');
  ok(writes.length > nBefore, '端到端：写次数增加');
  ok(!textOf(b['log']).includes('检查 WARN') && !textOf(b['log']).includes('检查 ERR'),
     '端到端：一条正常的 Note On 不产生任何校验告警（不做假警报）');

  /* 同音再按：页面是"先发 Note Off、再发 Note On"**两笔**发送。
     校验器不能因此误报"同音重触发" —— 那会在每次和弦重按时刷一堆假警告。 */
  const lenBefore = textOf(b['log']).length;
  await b['btnOn']._listeners.click[0]();
  const nowLog = textOf(b['log']).slice(lenBefore);
  ok(!nowLog.includes('同音重触发'), '端到端：同音再按（先 Off 再 On）不误报同音重触发');
  ok(nowLog.includes('Note On'), '端到端：同音再按确实发出了 Note On');

  // --- 拖滑杆到 30，再按 Note On ---
  b['vel'].value = '30';
  fire('vel', 'input');                                  // 拖滑杆
  eq(b['velNum'].value, 30, '端到端：拖滑杆会同步数字框');
  await b['btnOn']._listeners.click[0]();
  last = writes[writes.length - 1];
  eq(last[0], 0x90, '端到端：最后一条是 Note On');
  eq(last[2], 30,   '端到端：力度跟着滑杆变成 30（字节 1E）');

  // --- 直接改数字框 ---
  b['velNum'].value = '7';
  fire('velNum', 'input');
  eq(b['vel'].value, 7, '端到端：改数字框会反向同步滑杆');
  await b['btnOn']._listeners.click[0]();
  eq(writes[writes.length - 1][2], 7, '端到端：数字框输入也生效');

  // --- 通道也跟着全局通道走 ---
  b['midiCh'].value = '16';
  b['velNum'].value = '64';
  await b['btnOn']._listeners.click[0]();
  eq(writes[writes.length - 1][0], 0x9F, '端到端：全局通道 16 → 状态字节 0x9F');

  // --- 力度 0：按规范等价 Note Off，且不能进「正在发声」 ---
  b['midiCh'].value = '1';
  b['velNum'].value = '0';
  const n0 = writes.length;
  await b['btnOn']._listeners.click[0]();
  eq(writes[writes.length - 1], [0x90, 60, 0], '端到端：力度 0 发出的仍是 Note On 字节（惯用手法）');
  ok(b['heldTable'].style.display === 'none' || b['heldBody'].innerHTML === '',
     '端到端：力度 0 不计入「正在发声」');

  // --- 力度 0 之后，列表里不该留下这个音 ---
  b['velNum'].value = '64';
  await b['btnOn']._listeners.click[0]();
  await fire('btnAllOff', 'click');
  ok(writes.some(w => w[0] === 0x80 && w[1] === 60), '端到端：全部关闭发出了 Note Off');
}

/* =================== 13. 指令校验器（面板 8） ===================
   判据全部来自 RTL，不是凭 MIDI 规范猜的：
     rtl/scheduler/midi_filter.v  cc2field / is_mix_cc / case(m_type) / SysEx 只认两种
     rtl/scheduler/midi_parse.v   消息长度、运行状态、SysEx 上限 64、字节间超时只对 SysEx
     rtl/scheduler/timbre_map.v   timbre_slot = program & 7
     rtl/scheduler/chan_table.v   Δsemi = (bend−8192)/8192 × bendRange
   用例表 SELFTEST_CASES 是**网页按钮和这里共用的一份**，所以两边判定不会分叉。 */
async function sectionChecker() {
  const C = (b, ctx) => X.midiCheck(b, ctx || {});
  const codes = r => r.issues.map(i => i.code);
  const has = (r, c) => r.issues.some(i => i.code === c);
  const lvOf = (r, c) => { const i = r.issues.find(x => x.code === c); return i ? i.level : ''; };

  /* --- 运行状态：old splitMessages 不认，手输 90 3C 64 3E 64 会切错 --- */
  eq(X.splitMessages([0x90, 60, 100, 62, 100]), [[0x90,60,100],[62,100]],
     'splitMessages: 运行状态的第二条只含数据字节（不带状态字节）');
  eq(X.parseStream([0x90, 60, 100, 62, 100]).length, 2, 'parseStream: 运行状态切成 2 条消息');
  eq(X.parseStream([0x90, 60, 100, 62, 100])[1].status, 0x90, 'parseStream: 第二条继承运行状态 0x90');
  eq(X.parseStream([0x90, 60, 100, 62, 100])[1].full, [0x90, 62, 100],
     'parseStream: full 补回状态字节（喂 describe 用）');
  eq(X.parseStream([0x3E, 0x64]).map(m => !!m.orphan), [true, true],
     'parseStream: 没有状态也没有运行状态 → 孤儿数据字节');
  eq(X.parseStream([0xC0, 5, 0x90, 60, 100]).length, 2, 'parseStream: PC 只占 2 字节');
  eq(X.parseStream([0x90, 60, 100])[0].data, [60, 100], 'parseStream: data 不含状态字节');

  /* --- 正例：固件真的会执行 --- */
  eq(codes(C([0x90, 60, 100])), [], 'Note On 干净通过');
  eq(codes(C([0xB0, 11, 100])), [], 'CC11 表情在乐器口也干净通过');
  eq(codes(C([0xB0, 7, 100], { port: 'mixer' })), [], 'CC7 在混音口干净通过');
  eq(codes(C([0xB0, 64, 127])), [], 'CC64 延音踏板受支持（交接文档说没有，实际有）');
  eq(codes(C([0xB0, 66, 127])), [], 'CC66 持有踏板受支持');
  ok(!has(C([0xB0, 0x65, 0, 0xB0, 0x64, 0, 0xB0, 6, 12]), 'rpn-not-00'),
     'RPN 0,0 之后的 CC6 是合法的（写弯音范围）');
  ok(has(C([0xB0, 0x65, 0, 0xB0, 0x64, 0, 0xB0, 6, 12]), 'bend-range'),
     'RPN 0,0 → CC6 会报「弯音范围已设」');

  /* --- 端口：乐器口丢弃混音类 CC（midi_filter.v m_mixcc_drop） --- */
  ok(has(C([0xB0, 7, 100], { port: 'instrument' }), 'mix-cc-dropped'), '乐器口发 CC7 → 报丢弃');
  eq(lvOf(C([0xB0, 7, 100], { port: 'instrument' }), 'mix-cc-dropped'), 'err',
     '乐器口发 CC7 是 err 级（不是 warn：它真的不会生效）');
  for (const cc of [10, 91, 93, 94])
    ok(has(C([0xB0, cc, 64], { port: 'instrument' }), 'mix-cc-dropped'),
       `乐器口发 CC${cc} → 报丢弃`);
  ok(!has(C([0xB0, 91, 64], { port: 'mixer' }), 'mix-cc-dropped'), '混音口发 CC91 不报丢弃');

  /* --- 固件忽略的 CC / 消息类型 --- */
  ok(has(C([0xB0, 2, 64]), 'unsupported-cc'), 'CC2 不在支持表 → unsupported-cc');
  ok(has(C([0xB0, 0x79, 0]), 'unsupported-cc'), 'CC121 未实现 → unsupported-cc');
  ok(has(C([0xB0, 0x7C, 0]), 'unsupported-cc'), 'CC124 未实现 → unsupported-cc');
  ok(has(C([0xA0, 60, 50]), 'ignored-type'), '复音触后 An → ignored-type');
  ok(has(C([0xD0, 50]), 'ignored-type'), '通道触后 Dn → ignored-type');
  ok(has(C([0xB0, 0x78, 0]), 'panic-blast'), 'CC120 硬断 → panic-blast 提示用 CC123');
  ok(!has(C([0xB0, 0x7B, 0]), 'panic-blast'), 'CC123 走释放，不作硬断警告');

  /* --- 结构错误 --- */
  ok(has(C([0x90, 60]), 'incomplete'), '缺数据字节 → incomplete');
  ok(has(C([0x3E, 0x64]), 'orphan'), '孤儿数据字节 → orphan');
  ok(has(C([0xC0, 5]), 'pc-without-bank'), '单独发 PC → pc-without-bank');
  ok(has(C([0xB0, 6, 12]), 'rpn-not-00'), 'CC6 前面不是 RPN 0,0 → rpn-not-00');
  ok(has(C([0x90, 60, 0]), 'vel0'), '力度 0 的 Note On → vel0（等价 Note Off）');
  ok(has(C([0x90, 60, 100, 60, 100]), 'retrigger'), '同音重复 Note On → retrigger');
  ok(has(C([0x90, 60, 100], { held: new Set([60]) }), 'retrigger'),
     '已经按住的音再按 → retrigger（用 ctx.held）');

  /* --- SysEx：只认两种格式，且长度字段只有 3 位 --- */
  ok(!has(C([0xF0, 0x7D, 0, 1, 0, 0x40, 0xF7]), 'sysex-wrap'), '效果参数 SysEx（5 数据字节）合法');
  ok(has(C([0xF0, 0x7D, 0, 1, 0, 0x40, 0xF7]), 'sysex-fx'), '效果参数 SysEx 能解出组/参数/值');
  ok(!has(C([0xF0, 0x7F, 0x7F, 0x04, 0x01, 0x00, 0x40, 0xF7]), 'sysex-master-len'),
     '主音量 SysEx（6 数据字节）合法');
  ok(has(C([0xF0, 0x7F, 0x7F, 0x04, 0x01, 0x00, 0x40, 0xF7]), 'sysex-master'),
     '主音量 SysEx 能解出 14 位值');
  ok(has(C([0xF0, 0x7D, 0, 1, 0, 0x40, 0, 0, 0, 0xF7]), 'sysex-wrap'),
     'SysEx 数据 8 字节 → sysex-wrap（midi_filter 的 sysex_len[2:0] 会回绕）');
  ok(has(C([0xF0, 0x7D, 0, 1, 0]), 'sysex-unterminated'), 'SysEx 没有 F7 → sysex-unterminated');
  ok(has(C([0xF0, 0x7E, 0x7F, 0x09, 0x01, 0xF7]), 'sysex-unknown'), '未知厂商 ID → sysex-unknown');

  /* --- 数值/状态 --- */
  ok(has(C([0x90, 60, 100], { baud: 115200 }), 'baud'), '波特率 ≠ 31250 → err');
  ok(!has(C([0x90, 60, 100], { baud: 31250 }), 'baud'), '波特率 31250 → 不报警');
  ok(!has(C([0x90, 60, 100], { baud: NaN }), 'baud'),
     '波特率填了非法值时由「波特率无效」那条管，校验器不重复报');
  const poly = Array.from({ length: 33 }, (_, i) => [0x90, 36 + i, 100]).flat();
  ok(has(C(poly), 'polyphony'), '33 个音 > 复音 32 → polyphony 警告');
  ok(!has(C(poly.slice(0, 32 * 3)), 'polyphony'), '正好 32 个音 → 不警告');

  const bendMid = C([0xE0, 0, 0x40]);
  ok(bendMid.issues.some(i => i.code === 'bend' && i.text.includes('8192')),
     'Pitch Bend 中心 8192 出现在提示里');
  const bendMax = C([0xE0, 0x7F, 0x7F]);
  ok(bendMax.issues.some(i => i.code === 'bend' && i.text.includes('16383')),
     'Pitch Bend 最大值按 MSB×128+LSB 算成 16383');
  ok(bendMax.issues.some(i => i.code === 'bend' && i.text.includes('+2.00')),
     '±2 半音换算正确（16383 ≈ +2.00 半音）');
  ok(C([0xC0, 12]).issues.some(i => i.code === 'timbre-slot' && i.text.includes('4')),
     'prog 12 → timbre_slot 4（program & 7）');

  /* --- 自检用例表：网页按钮与这里共用，必须全过 --- */
  const st = X.runSelfTest();
  eq(st.fails, [], `内置自检用例全部通过（${st.pass}/${st.total}）`);
  ok(st.total >= 25, `自检用例 ${st.total} 条 ≥ 25`);
  eq(X.SELFTEST_CASES.length, st.total, '用例表条数与 runSelfTest 统计一致');
  const badCase = X.SELFTEST_CASES.filter(t => !t.name || !Array.isArray(t.bytes) ||
                                               !['clean','info','warn','err'].includes(t.expect));
  eq(badCase.map(t => t.name), [], '每条用例都必须有 name / bytes / 合法的 expect');
  const pos = X.SELFTEST_CASES.filter(t => t.expect === 'clean').length;
  ok(pos >= 10 && st.total - pos >= 10,
     `正例 ${pos} 条、反例 ${st.total - pos} 条（两边都要够量）`);

  /* --- 未连串口时也要审计（这是"没板子也能验"的关键） --- */
  {
    const a = loadDebugger();
    const b = a.byId;
    b['baud'].value = '31250';
    b['baudCustom'].value = '31250';
    b['rawHex'].value = 'B0 07 64';               // 乐器口发 CC7，默认端口是乐器口
    const btn = b['btnRaw']._listeners.click[0];
    ok(!!btn, '手动发送按钮的 click 监听存在');
    await btn();
    const txt = textOf(b['log']);
    ok(txt.includes('检查 ERR'), '未连接串口时，手动发送仍然做了校验（日志里出现「检查 ERR」）');
    ok(txt.includes('CC7'), '未连接时的校验内容带上了具体 CC 号');
    ok(b['checkSummary'].textContent.includes('err 1'),
       '面板 8 的计数被更新（err 1）');
  }
}

/* =================== 14. 表情：弯音 / CC 表 / 和弦齐发 ===================
   这一节保证"网页上拖一下"能映射成正确字节 —— 弯音是 14 位，和弦是一次写多音。 */
{
  // --- Pitch Bend：14 位、中心 8192、字节顺序 lo→hi ---
  eq(X.msgBend(0, 8192),  [0xE0, 0x00, 0x40], '弯音中心 8192 → E0 00 40');
  eq(X.msgBend(0, 0),     [0xE0, 0x00, 0x00], '弯音最小值 0 → E0 00 00');
  eq(X.msgBend(0, 16383), [0xE0, 0x7F, 0x7F], '弯音最大值 16383 → E0 7F 7F');
  eq(X.msgBend(15, 8192), [0xEF, 0x00, 0x40], '弯音跟随全局通道（16 → 0xEF）');
  eq(X.msgBend(0, 20000), [0xE0, 0x7F, 0x7F], '弯音超上限被夹到 16383');
  eq(X.msgBend(0, -5),    [0xE0, 0x00, 0x00], '弯音负值被夹到 0');
  eq(X.msgBend(0, NaN),   [0xE0, 0x00, 0x00], '弯音 NaN 落回 0（不会发出脏字节）');

  // 14 位还原：MSB×128+LSB 必须等于原值（固件 midi_filter.v 也按这个公式拼）
  let bendOk = 0;
  for (let v = 0; v <= 16383; v += 97){
    const b = X.msgBend(0, v);
    if (((b[2] << 7) | b[1]) === v) bendOk++;
  }
  eq(bendOk, Math.floor(16383 / 97) + 1, '14 位弯音值逐点往返一致');

  // ±2 半音的显示折算
  eq(X.bendSemiText(X.BEND_CENTER), '+0.00 半音', '中心 = 0 半音');
  eq(X.bendSemiText(X.BEND_MAX),    '+2.00 半音', '最大值 ≈ +2 半音');
  eq(X.bendSemiText(0),             '-2.00 半音', '最小值 = -2 半音');
  near(((16383 - 8192) / 8192) * 2, 2, 0.001, '±2 半音的换算公式自洽');

  // --- CC 滑杆表：面板上能拖的每一个 CC 都必须是固件真的支持的 ---
  const panelRows = [...X.CC_ROWS_EXPR];
  const panelCcs  = panelRows.map(r => r.cc);
  eq(panelCcs.filter(cc => !(cc in X.CC_SUPPORTED)), [], '面板上的 CC 全部在固件支持表内');
  eq([...new Set(panelCcs)].length, panelCcs.length, '面板上的 CC 号没有重复');
  eq(panelRows.filter(r => !(r.def >= 0 && r.def <= 127)).map(r => r.cc), [],
     '每个 CC 的默认值都在 0–127');
  eq(panelRows.filter(r => !r.name || !r.note).map(r => r.cc), [], '每个 CC 都有名字和说明');

  // 混音台（面板 15）的 6 个参数：5 个受端口限制 + 表情 CC11 不受限制
  eq(Object.keys(X.mxCtl).filter(k => k !== 'prog' && k !== 'panBtn').sort(),
     ['cho','del','expr','pan','rev','vol'],
     '混音台有 6 个参数控件（vol/pan/expr/rev/cho/del）');
  eq(X.MX_MIX_ONLY.slice().sort(), ['cho','del','pan','rev','vol'],
     '乐器口禁用的是除表情外的 5 个（与 midi_filter.v 丢弃列表一致）');

  // --- 和弦齐发 ---
  eq(X.chordNotes(36, 32).length, 32, '32 音和弦 = 32 个音');
  eq(X.chordNotes(36, 32)[0],  36, '32 音和弦从基准音起');
  eq(X.chordNotes(36, 32)[31], 67, '36 起 32 个正好到 67（上板手册 §6.2 同一串）');
  eq(X.chordNotes(120, 16), [120,121,122,123,124,125,126,127], '到 127 就截断，不发越界音符号');
  eq(X.chordNotes(127, 4), [127], '基准音就是最高音时只发一个');

  const cb = X.chordBytes(0, 60, 4, 100);
  eq(cb.length, 12, '4 音和弦 = 12 字节');
  eq(cb.slice(0, 3), [0x90, 60, 100], '第一个音是 90 3C 64');
  eq(cb.slice(9, 12), [0x90, 63, 100], '最后一个音是 90 3F 64');
  eq(X.parseStream(cb).length, 4, '和弦字节能被切成 4 条 Note On');
  eq(X.chordBytes(15, 60, 2, 1).slice(0, 3), [0x9F, 60, 1], '和弦跟着全局通道走');
  eq(X.chordBytes(0, 60, 32, 100).length, 96, '32 音和弦 = 96 字节，一次写完');

  // 32 个音正好压满复音上限，不该报警；33 个才报
  eq(X.midiCheck(X.chordBytes(0, 36, 32, 100), {}).issues.filter(i => i.code === 'polyphony').length, 0,
     '32 音和弦不报超复音');
  ok(X.midiCheck(X.chordBytes(0, 36, 33, 100), {}).issues.some(i => i.code === 'polyphony'),
     '33 音和弦报超复音');
}

/* =================== 15. 面板 4/5/6：拖一下 → 真的发出对应字节 ===================
   这一节走完整 UI 链路：假串口 → 点「连接」→ 拖 CC 滑杆 / 拖弯音 / 点效果器全关全开
   → 检查实际写进串口的字节。目的：把「网页上这个控件」和「线上那几个字节」钉死，
   以后改布局、改默认值，只要映射歪了这里就会红。 */
async function sectionPanels() {
  const writes = [];
  const mkWriter = () => ({ write: async u8 => { writes.push([...u8]); }, releaseLock(){} });
  const fakePort = {
    open: async () => {}, close: async () => {}, releaseLock(){},
    writable: { getWriter: () => mkWriter() },
    getInfo: () => ({ usbVendorId: 0x1A86, usbProductId: 0x7523 })
  };

  const a = loadDebugger({ requestPort: async () => fakePort });
  const b = a.byId;
  b['baud'].value = '31250';
  b['baudCustom'].value = '31250';
  b['midiCh'].value = '1';
  b['note'].value = '60';
  b['velNum'].value = '100';
  await b['btnConn']._listeners.click[0]();
  ok(b['connState'].textContent === '已连接', '面板 4/5/6 前置：串口已连接');

  /* 在动态生成的行里按标签 "CC<号> …" 找到那一行，取出滑杆 / 数字框 */
  const rowCtl = (host, cc) => {
    const row = (host._children || []).find(r => r._children && r._children[0] &&
                String(r._children[0].textContent).startsWith('CC' + cc + ' '));
    return row ? { range: row._children[1], num: row._children[2] } : null;
  };
  const drag = (ctl, v) => {
    ctl.range.value = String(v);
    ctl.range._listeners.input[0]();
    ctl.range._listeners.change[0]();      // 松手：补发最终值，把节流挂着的也冲掉
  };
  const last = () => writes[writes.length - 1];
  const errCount = () => Number((b['checkSummary'].textContent.match(/err (\d+)/) || [0, 0])[1]);

  /* --- 面板 4：CC 滑杆 --- */
  const c11 = rowCtl(b['ccExprRows'], 11);
  ok(!!c11, '面板 4 生成了 CC11 滑杆');
  drag(c11, 100);
  eq(last(), [0xB0, 11, 100], '拖 CC11 到 100 → B0 0B 64');
  eq(Number(c11.num.value), 100, '拖滑杆会同步数字框');

  const c74 = rowCtl(b['ccExprRows'], 74);
  drag(c74, 0);
  eq(last(), [0xB0, 74, 0], '拖 CC74 到 0 → B0 4A 00');
  drag(c74, 127);
  eq(last(), [0xB0, 74, 127], '拖 CC74 到 127 → B0 4A 7F');

  // 直接改数字框也要生效，并且反向同步滑杆
  c74.num.value = '32';
  c74.num._listeners.input[0]();
  c74.num._listeners.change[0]();
  eq(last(), [0xB0, 74, 32], '数字框输入 CC74 = 32 → B0 4A 20');
  eq(Number(c74.range.value), 32, '改数字框会反向同步滑杆');

  // 越界输入必须被夹住，不能把 >127 的值塞进数据字节
  c74.num.value = '999';
  c74.num._listeners.input[0]();
  c74.num._listeners.change[0]();
  eq(last(), [0xB0, 74, 127], 'CC 值 999 被夹到 127（数据字节不会溢出）');

  /* --- 面板 4：弯音 --- */
  b['bend'].value = '16383';
  b['bend']._listeners.input[0]();
  b['bend']._listeners.change[0]();
  eq(last(), [0xE0, 0x7F, 0x7F], '弯音拖到顶 → E0 7F 7F');
  ok(b['bendOut'].textContent.includes('+2.00 半音'), '弯音显示 ±2 半音（16383 ≈ +2.00）');

  b['bendNum'].value = '0';
  b['bendNum']._listeners.input[0]();
  b['bendNum']._listeners.change[0]();
  eq(last(), [0xE0, 0x00, 0x00], '弯音数字框填 0 → E0 00 00');

  await b['btnBendCenter']._listeners.click[0]();
  eq(last(), [0xE0, 0x00, 0x40], '「回中」→ E0 00 40（8192）');
  eq(Number(b['bend'].value), 8192, '「回中」把滑杆也拉回 8192');

  /* --- CC / 弯音都必须跟着全局通道走 --- */
  b['midiCh'].value = '3';
  drag(c11, 64);
  eq(last(), [0xB2, 11, 64], '全局通道 3 → CC 状态字节 0xB2');
  b['bend'].value = '8192';
  b['bend']._listeners.input[0]();
  b['bend']._listeners.change[0]();
  eq(last(), [0xE2, 0x00, 0x40], '弯音也跟随全局通道 → 0xE2');
  b['midiCh'].value = '1';

  /* --- 面板 15：效果全关 / 全开（对 16 个通道各发一遍） --- */
  await b['mxAllFx']._listeners.click[0]();
  eq(last(), [0xBF, 94, 0], '效果全关：最后一条是 CH16 的 CC94=0');
  await b['mxAllFxOn']._listeners.click[0]();
  eq(last(), [0xBF, 94, 127], '效果全开：最后一条是 CH16 的 CC94=127');
  eq(Number(a.X.mxCtl.rev.nm.value), 127, '「效果全开」把混音台的混响滑杆同步到 127');
  eq(Number(a.X.mxCtl.del.nm.value), 127, '「效果全开」把混音台的延迟滑杆同步到 127');

  /* --- 混音台拖 CC7：值落到当前通道 --- */
  const mxVol = a.X.mxCtl.vol;
  mxVol.rg.value = '80';
  mxVol.rg._listeners.input[0]();
  await mxVol.rg._listeners.change[0]();
  eq(last(), [0xB0, 7, 80], '混音台拖音量 → CC7=80 发到当前通道');

  /* --- 前面模块的操作要同步到混音台 --- */
  // 1) 面板 3 换音色（Program Change）→ 混音台的音色下拉跟着变
  b['prog'].value = '5';
  await b['btnTimbre']._listeners.click[0]();
  eq(String(a.X.mxCtl.prog.value), '5', '面板 3 发 PC 5 → 混音台音色下拉同步到 5');

  // 2) 面板 4 拖 CC11 表情 → 混音台的 expr 滑杆跟着变
  const exprCtl = rowCtl(b['ccExprRows'], 11);
  exprCtl.range.value = '99';
  exprCtl.range._listeners.input[0]();
  exprCtl.range._listeners.change[0]();
  eq(String(a.X.mxCtl.expr.nm.value), '99', '面板 4 拖 CC11=99 → 混音台表情同步到 99');

  // 3) 面板 2 切通道 → 混音台切到那一页、编辑区换成该通道的值
  b['midiCh'].value = '6';
  b['midiCh']._listeners.change[0]();
  eq(String(a.X.mxCtl.expr.nm.value), '127', '切到 CH6 → 编辑区显示 CH6 自己的值（默认 127）');
}

/* =================== 16. 面板 11（一键演示） ===================
   演示流程里有真实等待（约 20 s）。这里用一个"假时钟"（每次取 now() 跳 1 s）
   把 sleepUnless 的等待压掉，于是整条演示能在毫秒内跑完 —— 但发出的字节一模一样，
   所以能逐条核对演示脚本到底发了什么。 */
async function sectionDemo() {
  ok(X.DEMO_STAGES >= 6, `一键演示有 ${X.DEMO_STAGES} 段`);

  const writes = [];
  const mkWriter = () => ({ write: async u8 => { writes.push([...u8]); }, releaseLock(){} });
  const fakePort = {
    open: async () => {}, close: async () => {}, releaseLock(){},
    writable: { getWriter: () => mkWriter() },
    getInfo: () => ({ usbVendorId: 0x1A86, usbProductId: 0x7523 })
  };
  let clock = 0;
  const a = loadDebugger({
    requestPort: async () => fakePort,
    performance: { now: () => (clock += 1000) }      // 假时钟：所有等待立即到点
  });
  const b = a.byId;
  b['baud'].value = '31250';
  b['baudCustom'].value = '31250';
  b['midiCh'].value = '1';
  b['note'].value = '60';
  b['velNum'].value = '100';
  await b['btnConn']._listeners.click[0]();
  ok(b['connState'].textContent === '已连接', '演示前置：串口已连接');

  /* --- 跑完整条演示 --- */
  await b['btnDemo']._listeners.click[0]();
  ok(b['demoStatus'].textContent === '已走完', '一键演示跑完（状态 = 已走完）');
  ok(b['btnDemo'].disabled === false, '演示结束后「开始演示」重新可用');
  ok(b['btnDemoStop'].disabled === true, '演示结束后「停止」变灰');

  eq(writes[0], [0xB0, 123, 0], '演示第 1 条 = 清场 CC123');
  eq(writes[writes.length - 1], [0xB0, 123, 0], '演示最后一条也是 CC123（中途停也不留音）');

  const thirty = writes.find(w => w.length === 96);
  ok(!!thirty, '演示里有 32 音齐发（96 字节一条）');
  if (thirty)
    eq([thirty[0], thirty[1], thirty[93], thirty[94], thirty[95]], [0x90, 36, 0x90, 67, 100],
       '32 音齐发 = 36 起、67 止、力度 100');

  // 音色三连发：CC0 + CC32 + PC 一共 8 字节，取前 "CC0,0 / CC32,0 / PC" 的那种
  const timbre = writes.filter(w => w.length === 8 && w[0] === 0xB0 && w[1] === 0 &&
                                    w[3] === 0xB0 && w[4] === 32 && w[6] === 0xC0);
  eq(timbre.slice(0, 8).map(w => w[7]), [0,1,2,3,4,5,6,7], '演示把音色 0–7 依次走了一遍');
  eq(timbre.length, 9, '8 个音色 + 滤波段切槽 6（共 9 次三连发）');

  eq(writes.filter(w => w.length === 3 && w[0] === 0xB0 && w[1] === 11).map(w => w[2]),
     [127, 90, 64, 32, 8, 127], 'CC11 音量扫描的值与顺序正确');
  eq(writes.filter(w => w.length === 3 && w[0] === 0xB0 && w[1] === 74).map(w => w[2]),
     [0, 64, 127, 64], 'CC74 截止扫描的值与顺序正确');
  eq(writes.filter(w => w.length === 3 && w[0] === 0xB0 && w[1] === 71).map(w => w[2]),
     [0, 64, 127, 64], 'CC71 谐振扫描的值与顺序正确');

  const fxOff = writes.filter(w => w.length === 9 && w[1] === 91 && w[2] === 0);
  const fxOn  = writes.filter(w => w.length === 9 && w[1] === 91 && w[2] === 127);
  eq([fxOff.length, fxOn.length], [1, 1], '效果器做了「全关 / 全开」各一次对照');
  eq(fxOff[0], [0xB0,91,0, 0xB0,93,0, 0xB0,94,0], '效果全关 = 91/93/94 各 0');
  eq(fxOn[0],  [0xB0,91,127, 0xB0,93,127, 0xB0,94,127], '效果全开 = 91/93/94 各 127');

  ok(!writes.some(w => (w[0] & 0xF0) === 0xE0), '演示流程里不发弯音（弯音留给手动拖）');
  ok(writes.length > 40, `整条演示共发了 ${writes.length} 次写`);

}

/* =================== 17. 面板 12（ADSR）/ 13（预设） ===================
   包络的判据同样来自 RTL：full_system.v 的 tp_of() 与 atk_s/rel_s，
   adsr_vca.v 的 attack_step = 32768 / (attack_ms × fs/1000)（反解成时间）。 */
async function sectionEnvPreset() {
  /* --- 包络时间常数：拿槽 0 手算对照 --- */
  const e0 = X.envSegments(0, 64, 64);
  near(e0.aMs, 32768 * 1000 / (2 * 48000), 0.01, '槽 0 起音 ≈ 341 ms（步长 2）');
  near(e0.dMs, (32768 - 24000) * 1000 / (1 * 48000), 0.01, '槽 0 衰减 ≈ 183 ms');
  near(e0.rMs, 24000 * 1000 / (1 * 48000), 0.01, '槽 0 释放 = 500 ms');
  near(e0.sLevel, 24000 / 32768, 1e-9, '槽 0 持续电平 = 24000/32768 ≈ 73%');

  /* --- CC73 / CC72 的方向：值越大越慢（RTL 里是减号） --- */
  const fast = X.envSegments(0, 0, 64);      // CC73=0 → a_step 变大 → 起音变快
  const slow = X.envSegments(0, 127, 64);    // CC73=127 → a_step 钳到 1 → 起音最慢
  ok(fast.aMs < e0.aMs, 'CC73=0 比起音基准更快');
  ok(slow.aMs > e0.aMs, 'CC73=127 比起音基准更慢');
  near(slow.aMs, 32768 * 1000 / (1 * 48000), 0.01, 'CC73=127 时 步长被钳到 1 → 683 ms');
  eq([fast.aStep, slow.aStep], [34, 1], 'CC73 的偏移 = (CC−64)>>>1，并钳到 ≥1');

  // CC72 的方向要在"基准步长 > 1"的槽上才看得出来：
  // 槽 0 的 release_step 本来就是 1（最慢），CC72 再大也只能保持 1。
  const r5base = X.envSegments(5, 64, 64);
  const r5fast = X.envSegments(5, 64, 0);
  const r5slow = X.envSegments(5, 64, 127);
  ok(r5fast.rMs < r5base.rMs, 'CC72=0 → 释放更快（槽 5）');
  ok(r5slow.rMs > r5base.rMs, 'CC72=127 → 释放更慢，方向不能反（槽 5）');
  eq(X.envSegments(0, 64, 127).rStep, 1, '槽 0 的释放步长本来就是 1，CC72 只能让它保持最慢');

  /* --- 槽 7：持续为 0，释放时间也就是 0 --- */
  const e7 = X.envSegments(7, 64, 64);
  eq(e7.sLevel, 0, '槽 7 持续电平 = 0');
  eq(e7.rMs, 0, '槽 7 释放 = 0（持续已经为 0）');
  near(e7.dMs, 32768 * 1000 / (14 * 48000), 0.01, '槽 7 衰减 ≈ 49 ms');

  /* --- 8 个槽都必须算出有限、非负的数 --- */
  const badSlots = [];
  for (let s = 0; s < 8; s++){
    const e = X.envSegments(s, 64, 64);
    if (![e.aMs, e.dMs, e.rMs].every(v => isFinite(v) && v >= 0)) badSlots.push(s);
    if (!(e.sLevel >= 0 && e.sLevel <= 1)) badSlots.push(s);
  }
  eq(badSlots, [], '8 个音色槽的包络参数全部有限且非负');

  /* --- 面板 12 的显示：只剩一行数字，不再画曲线 --- */
  ok(!HTML_SRC.includes('id="envSvg"'), '面板 12 已经不画曲线图了');
  {
    const b = loadDebugger().byId;
    b['prog'].value = '0';
    b['prog']._listeners.input[0]();          // 触发 refreshSlot + renderEnv
    const txt = String(b['envSum'].textContent);
    ok(txt.startsWith('槽 0'), `显示当前音色槽（实为 "${txt}"）`);
    ok(txt.includes('A 341 ms'), '槽 0 起音 341 ms 显示出来');
    ok(txt.includes('D 183 ms'), '槽 0 衰减 183 ms 显示出来');
    ok(txt.includes('S 73%'), '持续电平显示成百分比');
    ok(txt.includes('R 500 ms'), '槽 0 释放 500 ms 显示出来');

    b['prog'].value = '7';
    b['prog']._listeners.input[0]();
    const txt7 = String(b['envSum'].textContent);
    ok(txt7.startsWith('槽 7'), '换音色槽后槽号跟着变');
    ok(txt7.includes('S 0%'), '槽 7 的持续电平是 0%');
    ok(txt7.includes('R 0 ms'), '槽 7 的释放是 0 ms');
  }

  /* --- 预设：校验 --- */
  eq(typeof X.validatePreset(null), 'string', 'null 不是预设');
  eq(typeof X.validatePreset({}), 'string', '缺 _app 不是预设');
  eq(typeof X.validatePreset({ _app: 'other' }), 'string', '别的应用的预设要拒绝');
  eq(X.validatePreset({ _app: X.PRESET_APP }), null, '带 _app 的空预设结构上可接受');
  eq(typeof X.validatePreset({ _app: X.PRESET_APP, cc: [] }), 'string', 'cc 是数组要拒绝');
  eq(typeof X.validatePreset({ _app: X.PRESET_APP, seq: 'x' }), 'string', 'seq 不是对象要拒绝');

  /* --- 预设：往返一致（collect → apply → collect） --- */
  // 用一个干净实例做往返（共享的 app 在前面几节被改过 baud 等值）
  const a1 = loadDebugger();
  a1.byId['baud'].value = '31250';
  a1.byId['baudCustom'].value = '31250';
  const p1 = a1.X.collectPreset();
  ok(p1._app === X.PRESET_APP, 'collectPreset 带上 _app 标记');
  eq(Object.keys(p1.cc).length, 6, `预设里存了 ${Object.keys(p1.cc).length} 个 CC（应为 6，面板 5 已并入混音台）`);
  eq(Object.keys(p1.cc).map(Number).sort((a, b) => a - b), [1,11,71,72,73,74],
     '6 个 CC 号正好是面板 4 上那 6 个（混音类是 16 通道的，不进单值预设）');

  const a2 = loadDebugger();
  a2.X.applyPreset(p1);
  const p2 = a2.X.collectPreset();
  delete p1._savedAt;
  delete p2._savedAt;
  eq(p2, p1, '预设往返一致（collect → apply → collect）');

  /* --- 预设：越界值必须被夹住，不能污染界面 --- */
  const a3 = loadDebugger();
  a3.X.applyPreset({
    _app: X.PRESET_APP, ch: 99, prog: 999, note: -5, vel: 300, bend: 99999,
    baud: '乱填的', baudCustom: 5, cc: { 74: 999, 11: -20 }
  });
  eq(Number(a3.byId['midiCh'].value), 16, '通道 99 被夹到 16');
  eq(Number(a3.byId['prog'].value), 127, 'program 999 被夹到 127');
  eq(Number(a3.byId['note'].value), 0, '音符号 -5 被夹到 0');
  eq(Number(a3.byId['velNum'].value), 127, '力度 300 被夹到 127');
  eq(Number(a3.byId['bend'].value), X.BEND_MAX, '弯音 99999 被夹到 16383');
  eq(a3.byId['baud'].value, '31250', '乱填的波特率落回 31250');
  eq(Number(a3.byId['baudCustom'].value), 300, '自定义波特率 5 被夹到下限 300');

  /* --- 预设：applyPreset 遇到坏数据要抛，而不是默默写坏界面 --- */
  let threw = false;
  try { a3.X.applyPreset({ _app: 'other' }); } catch (_) { threw = true; }
  ok(threw, 'applyPreset 对非本应用的预设会抛异常');

  /* --- 载入预设**不能**发送任何字节（调试器里这条很重要） --- */
  {
    const writes = [];
    const fakePort = {
      open: async () => {}, close: async () => {}, releaseLock(){},
      writable: { getWriter: () => ({ write: async u8 => { writes.push([...u8]); }, releaseLock(){} }) },
      getInfo: () => ({ usbVendorId: 0x1A86, usbProductId: 0x7523 })
    };
    const a4 = loadDebugger({ requestPort: async () => fakePort });
    a4.byId['baud'].value = '31250';
    a4.byId['baudCustom'].value = '31250';
    await a4.byId['btnConn']._listeners.click[0]();
    ok(a4.byId['connState'].textContent === '已连接', '预设前置：串口已连接');
    const before = writes.length;
    a4.X.applyPreset(X.collectPreset());
    eq(writes.length, before, '载入预设不发任何字节（只改界面）');
  }
}

/* =================== 18. 面板 3：8 个音色按钮 ===================
   点一下必须直接发出 CC0 → CC32 → Program（8 字节），并把界面（Program / 高亮 / 提示）同步好。 */
async function sectionTimbre() {
  eq(X.TIMBRE_NAMES.length, 8, '8 个音色名');
  eq(new Set(X.TIMBRE_NAMES).size, 8, '音色名互不重复');
  eq(X.TIMBRE_NAMES.filter(n => !String(n || '').trim()).length, 0, '每个音色都有名字');

  const presetBtns = [...HTML_SRC.matchAll(/data-preset="([^"]+)"/g)].map(m => m[1].split(',').map(Number));
  eq(presetBtns.length, 8, 'HTML 里正好 8 个音色按钮');
  eq(presetBtns.map(b => b[2]), [0,1,2,3,4,5,6,7], '音色按钮覆盖 Program 0–7');
  ok(presetBtns.every(b => b[0] === 0 && b[1] === 0), '音色按钮都是 Bank 0/0');

  const writes = [];
  const fakePort = {
    open: async () => {}, close: async () => {}, releaseLock(){},
    writable: { getWriter: () => ({ write: async u8 => { writes.push([...u8]); }, releaseLock(){} }) },
    getInfo: () => ({ usbVendorId: 0x1A86, usbProductId: 0x7523 })
  };
  const a = loadDebugger({ requestPort: async () => fakePort });
  const b = a.byId;
  b['baud'].value = '31250';
  b['baudCustom'].value = '31250';
  b['midiCh'].value = '1';
  await b['btnConn']._listeners.click[0]();
  ok(b['connState'].textContent === '已连接', '音色按钮前置：串口已连接');

  const btns = a.query('[data-preset]');
  eq(btns.length, 8, '假 DOM 里拿到 8 个音色按钮');
  eq(btns.map(x => x.textContent), X.TIMBRE_NAMES.map((n, i) => `${i} · ${n}`),
     '按钮文案 = Program 号 + TIMBRE_NAMES（文案只从那一处表取）');

  const last = () => writes[writes.length - 1];

  await btns[5]._listeners.click[0]();
  eq(last(), [0xB0,0,0, 0xB0,32,0, 0xC0,5], '点「5 槽 5」→ CC0+CC32+PC5 共 8 字节');
  eq(Number(b['prog'].value), 5, '按钮把 Program 设成 5');
  eq(Number(b['bankMsb'].value), 0, '按钮把 Bank MSB 设成 0');
  ok(b['slotOut'].textContent.includes(X.TIMBRE_NAMES[5]), '提示里显示当前音色名（' + X.TIMBRE_NAMES[5] + '）');
  eq(btns[5].className, 'mini on', '当前音色按钮高亮');
  eq(btns[0].className, 'mini', '其他音色按钮不高亮');

  for (let p = 0; p < 8; p++){
    await btns[p]._listeners.click[0]();
    eq(last(), [0xB0,0,0, 0xB0,32,0, 0xC0,p], `点「${p} · ${X.TIMBRE_NAMES[p]}」→ 发出 PC ${p}`);
  }

  // 手填 Program 时高亮也要跟着走；≥8 没有对应按钮就全灭并提示回绕
  b['prog'].value = '3';
  b['prog']._listeners.input[0]();
  eq(btns[3].className, 'mini on', '手填 Program 3 会高亮「3 · 长笛」');
  b['prog'].value = '9';
  b['prog']._listeners.input[0]();
  eq(btns.filter(x => x.className.includes('on')).length, 0, 'Program ≥ 8 没有对应按钮 → 全不高亮');
  ok(b['slotOut'].textContent.includes('回绕'), 'Program ≥ 8 时提示会回绕');

  // 和弦按钮（同一套"点一下 → 发字节"的检查）
  const chordBtns = a.query('[data-chord]');
  eq(chordBtns.length, 4, '面板 6 有 4 个和弦按钮');
  eq(chordBtns.map(x => x.dataset.chord), ['4','8','16','32'], '和弦按钮是 4 / 8 / 16 / 32 音');
  b['prog'].value = '0';
  b['note'].value = '60';
  b['velNum'].value = '100';
  const n0 = writes.length;
  await chordBtns[0]._listeners.click[0]();
  await new Promise(r => setTimeout(r, 0));        // stackChord 是 async，等它跑完
  ok(writes.length > n0, '点「4 音」确实发出了字节');
  eq(last().length, 12, '4 音和弦 = 12 字节');
  eq(last().slice(0, 3), [0x90, 60, 100], '和弦从当前音符号 60 起、力度 100');
}

/* =================== 19. 面板折叠 ===================
   每个面板（日志区除外）都能点标题收起/展开；默认收起的是调试辅助那 5 个（10–12、14–15）。 */
function sectionFold() {
  const secs = [...HTML_SRC.matchAll(/<section class="panel([^"]*)"([^>]*)>\s*<h2>(\d+) ·/g)]
    .map(m => ({ cls: m[1].trim(), fold: /data-fold/.test(m[2]), num: Number(m[3]) }));
  eq(secs.length, 14, '页面里 14 个面板');
  eq(secs.filter(s => s.fold).length, 14, '14 个面板全部可折叠');

  eq(secs.filter(s => /collapsed/.test(s.cls)).map(s => s.num), [10, 11, 12, 14, 15],
     '默认收起的是 10 / 11 / 12 / 14 / 15');
  eq(secs.filter(s => !/collapsed/.test(s.cls)).map(s => s.num), [1,2,3,4,6,7,8,9,13],
     '其余 10 个面板默认展开（常用面板不该一进来就藏着）');

  // 日志区不参与折叠
  const logSec = HTML_SRC.match(/<section class="panel[^"]*"[^>]*>\s*<h2[^>]*>\s*<span>发送日志/);
  ok(!!logSec, '发送日志区存在');
  ok(!!logSec && !/data-fold/.test(logSec[0]), '发送日志区不加折叠（它要一直能看）');

  ok(HTML_SRC.includes('.panel[data-fold].collapsed > *:not(h2)'),
     '折叠用的 CSS 规则在（收起时隐藏除标题外的直接子元素）');

  // 箭头是给人看的：字号必须比标题（13px）大，且用实心三角而不是小号几何图形
  const arrow = HTML_SRC.match(/\.panel\[data-fold\] > h2::after\{([^}]*)\}/);
  ok(!!arrow, '折叠箭头有独立的 CSS 规则');
  if (arrow) {
    const fs = Number((arrow[1].match(/font-size:(\d+)px/) || [])[1]);
    ok(fs > 13, `箭头字号 ${fs}px 比标题 13px 大（一眼能看见）`);
    ok(/'▶'/.test(arrow[1]), '收起状态用实心三角 ▶');
  }
  ok(/::after\{content:'▼'\}/.test(HTML_SRC), '展开状态用实心三角 ▼');

  const h2s = app.query('[data-fold] > h2');
  eq(h2s.length, 14, '拿到 14 个可折叠标题');
  ok(h2s.every(h => h.title === '点击展开 / 收起'), '每个标题都给了"点击展开/收起"的提示');

  // 面板 1 默认展开：点一次收起、再点展开
  ok(h2s[0].parentNode.className.indexOf('collapsed') === -1, '面板 1 初始是展开的');
  h2s[0]._listeners.click[0]();
  ok(h2s[0].parentNode.className.indexOf('collapsed') >= 0, '点标题 → 面板 1 收起');
  h2s[0]._listeners.click[0]();
  eq(h2s[0].parentNode.className.indexOf('collapsed'), -1, '再点一次 → 面板 1 展开');

  // 面板 10 默认收起：点一次展开
  const h10 = h2s[9];
  ok(h10.parentNode.className.indexOf('collapsed') >= 0, '面板 10 初始是收起的');
  h10._listeners.click[0]();
  eq(h10.parentNode.className.indexOf('collapsed'), -1, '点标题 → 面板 10 展开');

  // 反复点不会把 class 打成一堆重复串（点偶数次回到原状态）
  for (let i = 0; i < 4; i++) h2s[1]._listeners.click[0]();
  eq(h2s[1].parentNode.className.trim(), 'panel', '反复点击后 class 干净（没有重复堆叠）');
}

/* =================== 20. 逐个指令过一遍（把还没"点"过的入口补齐） ===================
   面板上能发出去的每一条指令，都应该有一条"点/拖 → 断言字节"的断言。
   这一节补上前面几节漏掉的：另外 8 个 CC 滑杆、Note Off 按钮、序列播放、力度扫描。 */
async function sectionEveryCommand() {
  const writes = [];
  const fakePort = {
    open: async () => {}, close: async () => {}, releaseLock(){},
    writable: { getWriter: () => ({ write: async u8 => { writes.push([...u8]); }, releaseLock(){} }) },
    getInfo: () => ({ usbVendorId: 0x1A86, usbProductId: 0x7523 })
  };
  let clock = 0;
  const a = loadDebugger({
    requestPort: async () => fakePort,
    performance: { now: () => (clock += 1000) }      // 假时钟：序列/等待都立即到点
  });
  const b = a.byId;
  b['baud'].value = '31250';
  b['baudCustom'].value = '31250';
  b['midiCh'].value = '1';
  b['note'].value = '60';
  b['velNum'].value = '100';
  await b['btnConn']._listeners.click[0]();
  ok(b['connState'].textContent === '已连接', '逐条指令前置：串口已连接');

  const last = () => writes[writes.length - 1];
  const rowCtl = (host, cc) => {
    const row = (host._children || []).find(r => r._children && r._children[0] &&
                String(r._children[0].textContent).startsWith('CC' + cc + ' '));
    return row ? { range: row._children[1], num: row._children[2] } : null;
  };
  const drag = (ctl, v) => {
    ctl.range.value = String(v);
    ctl.range._listeners.input[0]();
    ctl.range._listeners.change[0]();
  };

  /* --- 11 个 CC 滑杆，逐个拖一次，断言发出去的 CC 号就是它自己 --- */
  const ALL_CC = [1, 11, 74, 71, 73, 72];
  for (const cc of ALL_CC){
    const ctl  = rowCtl(b['ccExprRows'], cc);
    ok(!!ctl, `面板里能找到 CC${cc} 滑杆`);
    if (!ctl) continue;
    const v = (cc * 7) % 128;                 // 每个号用一个不同的值，避免"碰巧对"
    drag(ctl, v);
    eq(last(), [0xB0, cc, v], `拖 CC${cc} → 发出 B0 ${cc.toString(16).toUpperCase()} ${v.toString(16).toUpperCase()}`);
  }

  /* --- Note Off 按钮（按住时松开 / 没按住也照发） --- */
  b['note'].value = '64';
  await b['btnOn']._listeners.click[0]();
  eq(last(), [0x90, 64, 100], 'Note On 按钮：按 C4 以上的 E4 → 90 40 64');
  await b['btnOff']._listeners.click[0]();
  eq(last(), [0x80, 64, 0x40], 'Note Off 按钮：松开 → 80 40 40（释放力度 64）');
  await b['btnOff']._listeners.click[0]();
  eq(last(), [0x80, 64, 0x40], 'Note Off 按钮：没按住的音也照发一条');

  /* --- 序列播放：每个音 Note On → Note Off，顺序不能乱 --- */
  b['seqInput'].value = 'C4:100 D4:100';
  b['seqDur'].value = '100';
  b['seqGap'].value = '0';
  b['seqLoop'].checked = false;               // 循环会把测试挂住
  b['velNum'].value = '100';
  writes.length = 0;
  await b['btnSeqPlay']._listeners.click[0]();
  eq(writes.map(w => w.join(' ')), ['144 60 100', '128 60 64', '144 62 100', '128 62 64'],
     '序列播放 C4 D4 → Note On/Off 严格交替，时长按 100 ms 走');

  /* --- 力度扫描：5 个音、力度 20/50/80/110/127 --- */
  writes.length = 0;
  await b['btnSeqVelSweep']._listeners.click[0]();
  eq(writes.filter(w => (w[0] & 0xF0) === 0x90).map(w => w[2]), [20, 50, 80, 110, 127],
     '力度扫描：5 个音的力度依次是 20 / 50 / 80 / 110 / 127');
  eq(writes.length, 10, '力度扫描：5 个音各一对 Note On/Off，共 10 条');
  ok(b['seqInput'].value.indexOf('C4@20') === 0, '力度扫描会把序列框换成那 5 个音');

  /* --- 收尾：全部 Note Off 不能漏发 --- */
  b['note'].value = '72';
  await b['btnOn']._listeners.click[0]();
  writes.length = 0;
  await b['btnAllOff']._listeners.click[0]();
  eq(writes[writes.length - 1], [0x80, 72, 0x40], '全部 Note Off：把按住的音逐个显式发 Note Off');
}

/* =================== 21. 面板 14：CC120 / 两种 SysEx ===================
   字节格式以 midi_filter.v 的解析为准。最容易写反的是这两条的字节顺序：
     效果参数 F0 7D <grp> <idx> <hi> <lo> F7（**hi 在前**）
     主音量   F0 7F <dev> 04 01 <ll> <mm> F7（**lo 在前**） */
async function sectionMisc() {
  eq(X.SYSEX_FX_GRP_NAMES.length, 4, '效果参数有 4 个组（混响/合唱/延迟/主输出）');

  /* --- 效果参数 SysEx --- */
  eq(X.sysexFxBytes(0, 0, 8192), [0xF0, 0x7D, 0x00, 0x00, 0x40, 0x00, 0xF7],
     '值 8192 → hi=0x40 lo=0x00');
  eq(X.sysexFxBytes(1, 3, 16383), [0xF0, 0x7D, 0x01, 0x03, 0x7F, 0x7F, 0xF7], '最大值 → 7F 7F');
  eq(X.sysexFxBytes(2, 5, 0), [0xF0, 0x7D, 0x02, 0x05, 0x00, 0x00, 0xF7], '值 0 → 00 00');
  eq(X.sysexFxBytes(9, 99, 1), [0xF0, 0x7D, 0x01, 0x03, 0x00, 0x01, 0xF7],
     'grp 只取低 2 位、idx 只取低 4 位（RTL 里就是 [1:0] / [3:0]）');
  eq(X.sysexFxBytes(0, 0, 99999), [0xF0, 0x7D, 0x00, 0x00, 0x7F, 0x7F, 0xF7], '超上限被夹到 16383');

  /* --- 主音量 SysEx --- */
  eq(X.sysexMasterBytes(0x7F, 16383), [0xF0, 0x7F, 0x7F, 0x04, 0x01, 0x7F, 0x7F, 0xF7], '满值');
  eq(X.sysexMasterBytes(0x7F, 8192),  [0xF0, 0x7F, 0x7F, 0x04, 0x01, 0x00, 0x40, 0xF7],
     '值 8192 → lo=0x00 hi=0x40');
  eq(X.sysexMasterBytes(0x10, 0),     [0xF0, 0x7F, 0x10, 0x04, 0x01, 0x00, 0x00, 0xF7], '0 = 静音');

  /* --- 两条的字节顺序必须相反（最容易写反的地方） --- */
  eq(X.sysexFxBytes(0, 0, 8192).slice(4, 6),   [0x40, 0x00], '效果参数：hi 在前');
  eq(X.sysexMasterBytes(0x7F, 8192).slice(5, 7), [0x00, 0x40], '主音量：lo 在前');
  eq(X.sysexFxBytes(0, 0, 8192).length, 7, '效果参数 SysEx 是 7 字节');
  eq(X.sysexMasterBytes(0x7F, 0).length, 8, '主音量 SysEx 是 8 字节');

  /* --- 校验器不把这两条判成错，并且能解出内容 --- */
  const fxMsg = X.sysexFxBytes(0, 1, 4096);
  ok(!X.midiCheck(fxMsg, {}).issues.some(i => i.level === 'err'), '效果参数 SysEx 不报 err');
  ok(X.midiCheck(fxMsg, {}).issues.some(i => i.code === 'sysex-fx'), '效果参数 SysEx 能解出组/参数/值');
  const mvMsg = X.sysexMasterBytes(0x7F, 12000);
  ok(!X.midiCheck(mvMsg, {}).issues.some(i => i.level === 'err'), '主音量 SysEx 不报 err');
  ok(X.midiCheck(mvMsg, {}).issues.some(i => i.code === 'sysex-master'), '主音量 SysEx 能解出 14 位值');

  /* --- UI：点按钮 → 真的发字节 --- */
  const writes = [];
  const fakePort = {
    open: async () => {}, close: async () => {}, releaseLock(){},
    writable: { getWriter: () => ({ write: async u8 => { writes.push([...u8]); }, releaseLock(){} }) },
    getInfo: () => ({ usbVendorId: 0x1A86, usbProductId: 0x7523 })
  };
  const a = loadDebugger({ requestPort: async () => fakePort });
  const b = a.byId;
  b['baud'].value = '31250';
  b['baudCustom'].value = '31250';
  b['midiCh'].value = '1';
  await b['btnConn']._listeners.click[0]();
  ok(b['connState'].textContent === '已连接', '杂项面板前置：串口已连接');
  const last = () => writes[writes.length - 1];

  await b['btnCC120']._listeners.click[0]();
  eq(last(), [0xB0, 120, 0], 'CC120 按钮 → B0 78 00（立即断音）');
  await b['btnCC123']._listeners.click[0]();
  eq(last(), [0xB0, 123, 0], 'CC123 按钮 → B0 7B 00（温和关音）');

  b['midiCh'].value = '5';
  await b['btnCC120']._listeners.click[0]();
  eq(last(), [0xB4, 120, 0], 'CC120 也跟着全局通道走（通道 5 → 0xB4）');
  b['midiCh'].value = '1';

  b['fxGrp'].value = '1';
  b['fxIdx'].value = '2';
  b['fxVal'].value = '4096';
  await b['btnSysexFx']._listeners.click[0]();
  eq(last(), [0xF0, 0x7D, 0x01, 0x02, 0x20, 0x00, 0xF7], '效果参数按钮 → F0 7D 01 02 20 00 F7');

  b['masterDev'].value = '127';
  b['masterVol'].value = '16383';
  await b['btnSysexMaster']._listeners.click[0]();
  eq(last(), [0xF0, 0x7F, 0x7F, 0x04, 0x01, 0x7F, 0x7F, 0xF7],
     '主音量按钮 → F0 7F 7F 04 01 7F 7F F7');

  // 改输入框时预览要跟着变
  b['fxVal'].value = '8192';
  b['fxVal']._listeners.input[0]();
  ok(b['fxPreview'].innerHTML.includes('F0 7D'), '效果参数预览里显示十六进制');
  ok(b['fxPreview'].innerHTML.includes('8192'), '预览里显示 14 位值');
  ok(b['masterPreview'].innerHTML.includes('F0 7F'), '主音量预览里显示十六进制');
}

/* =================== 22. 状态一致性 + 主音量拖动条 + 所有按钮体检 ===================
   起因：用户实测「点完全部 Note Off，正在发声那里没变化」。
   根因是 noteOn() 无条件把音塞进表，而 releaseOne() 只在 send() 成功时才删 ——
   没连串口时就是"能加不能删"，界面卡死。这一节把它钉死，顺便把每个按钮都点一遍。 */
async function sectionButtons() {
  /* --- A. 未连接时的状态一致性（能加就能删） --- */
  {
    const u = loadDebugger();                     // 故意不连串口
    const b = u.byId;
    ok(b['connHint'].style.display === 'none',
       '未连接且环境正常时，顶部**不显示**那套操作指引（改成失败时写进日志）');
    b['note'].value = '60';
    b['velNum'].value = '100';
    await b['btnOn']._listeners.click[0]();
    eq(b['heldTable'].style.display, '', '未连接：按 Note On 后「正在发声」里出现这个音');

    await b['btnOff']._listeners.click[0]();
    eq(b['heldTable'].style.display, 'none', '未连接：点 Note Off 也能清掉（原来清不掉，就是这个 bug）');

    // 多个音 + 全部 Note Off
    b['note'].value = '60'; await b['btnOn']._listeners.click[0]();
    b['note'].value = '64'; await b['btnOn']._listeners.click[0]();
    ok(b['btnAllOff'].disabled === false, '未连接：有音时「全部 Note Off」可用');
    await b['btnAllOff']._listeners.click[0]();
    ok(b['btnAllOff'].disabled === true, '未连接：点「全部 Note Off」后按钮变灰 = 表已清空');

    // 连上串口后正常收发
    const writes = [];
    const port = {
      open: async () => {}, close: async () => {}, releaseLock(){},
      writable: { getWriter: () => ({ write: async u8 => { writes.push([...u8]); }, releaseLock(){} }) },
      getInfo: () => ({ usbVendorId: 0x1A86, usbProductId: 0x7523 })
    };
    const c = loadDebugger({ requestPort: async () => port });
    const cb = c.byId;
    cb['baud'].value = '31250'; cb['baudCustom'].value = '31250';
    await cb['btnConn']._listeners.click[0]();
    eq(cb['connHint'].style.display, '', '已连接：顶部的连接提示显示');
    eq(cb['connHint'].innerHTML.includes('已连接'), true, '已连接时提示只有一句「已连接」');

    // 已连接时正常收发
    cb['note'].value = '72'; cb['velNum'].value = '100';
    await cb['btnOn']._listeners.click[0]();
    eq(writes[writes.length - 1], [0x90, 72, 100], '已连接：Note On 真的写串口');
    await cb['btnAllOff']._listeners.click[0]();
    eq(writes[writes.length - 1], [0x80, 72, 0x40], '已连接：全部 Note Off 发了一条 Note Off');
    ok(cb['btnAllOff'].disabled === true, '已连接：全部 Note Off 之后表也清空了');
  }

  /* --- B. 主音量拖动条 --- */
  {
    const b = loadDebugger().byId;
    // 注意：数字框上挂了两个 input 监听（刷新预览 + 同步拖动条），要**全部**触发
    const fireAll = (el, type) => el._listeners[type].forEach(f => f());
    b['masterVolRange'].value = '8192';
    fireAll(b['masterVolRange'], 'input');
    eq(Number(b['masterVol'].value), 8192, '拖主音量条 → 数字框同步');
    b['masterVol'].value = '4000';
    fireAll(b['masterVol'], 'input');
    eq(Number(b['masterVolRange'].value), 4000, '改数字框 → 拖动条反向同步');
    b['masterVolRange'].value = '99999';
    fireAll(b['masterVolRange'], 'input');
    eq(Number(b['masterVol'].value), 16383, '主音量越界被夹到 16383');
    ok(b['masterPreview'].innerHTML.includes('F0 7F'), '主音量预览跟着变');
  }

  /* --- C. 所有按钮体检 --- */
  const idBtns = [...HTML_SRC.matchAll(/<button\b[^>]*\bid="([^"]+)"/g)].map(m => m[1]);
  ok(idBtns.length >= 25, `页面里 ${idBtns.length} 个带 id 的按钮`);

  const dataBtns = ['[data-preset]', '[data-chord]', '[data-note]'];
  const noListener = dataBtns.filter(sel => {
    const els = app.query(sel);
    return els.length === 0 || els.some(e => !e._listeners.click || !e._listeners.click.length);
  });
  eq(noListener, [], '按属性选择的按钮组（音色/和弦/音准）每个都绑了 click');

  const mkPort = sink => ({
    open: async () => {}, close: async () => {}, releaseLock(){},
    writable: { getWriter: () => ({ write: async u8 => { sink.push([...u8]); }, releaseLock(){} }) },
    getInfo: () => ({ usbVendorId: 0x1A86, usbProductId: 0x7523 })
  });
  const fresh = sink => {
    let clk = 0;
    const ins = loadDebugger({ requestPort: async () => mkPort(sink),
                               performance: { now: () => (clk += 1000) } });
    const b = ins.byId;
    b['baud'].value = '31250'; b['baudCustom'].value = '31250';
    b['midiCh'].value = '1'; b['note'].value = '60'; b['velNum'].value = '100';
    b['seqLoop'].checked = false; b['seqInput'].value = 'C4:100';
    b['seqDur'].value = '100'; b['seqGap'].value = '0'; b['rawHex'].value = '90 3C 64';
    b['prog'].value = '0'; b['fxVal'].value = '100'; b['masterVol'].value = '100';
    return b;
  };

  // (1) 每个按钮都点了不抛异常
  {
    const b = fresh([]);
    await b['btnConn']._listeners.click[0]();
    const errs = [];
    for (const id of idBtns){
      try { await b[id]._listeners.click[0](); }
      catch (e) { errs.push(id + ': ' + (e && e.message ? e.message : e)); }
    }
    eq(errs, [], '点遍所有带 id 的按钮都不抛异常');
  }

  // (2) 该有反应的按钮确实有反应（不是"绑了但什么都不做"的假按钮）
  const mustChange = {
    btnTimbre: '', btnBendCenter: '',
    btnOn: '', btnOff: 'note-first', btnAllOff: 'note-first',
    btnSeqPlay: '', btnSeqVelSweep: '', btnRaw: '', btnSelfTest: '',
    btnDemo: '',
    btnCC120: '', btnCC123: '', btnSysexFx: '', btnSysexMaster: '', btnSustain: '',
    btnProbe: '', btnPick: '', btnDisconn: '', btnPresetSave: '', btnPresetLoad: '',
    btnPresetExport: '', btnCopyLog: ''
  };
  for (const [id, setup] of Object.entries(mustChange)){
    const sink = [];
    const b = fresh(sink);
    await b['btnConn']._listeners.click[0]();
    if (setup === 'note-first') await b['btnOn']._listeners.click[0]();
    const sig = () => [sink.length, b['log']._children.length, b['connState'].textContent,
                       b['heldBody'].innerHTML, b['selfTestOut'].textContent].join('|');
    const before = sig();
    await b[id]._listeners.click[0]();
    ok(sig() !== before, `「${id}」点了有可见变化（不是假按钮）`);
  }

  // (3) 清空日志单独验（它的效果是 innerHTML 变空串，签名法看不出来）
  {
    const b = fresh([]);
    b['log'].innerHTML = 'something';
    await b['btnClearLog']._listeners.click[0]();
    eq(b['log'].innerHTML, '', '「清空日志」把内容清成空串');
  }

  // (4) 三个「停止」按钮：真的能把正在跑的东西停下来
  {
    const sink = [];
    const b = fresh(sink);
    await b['btnConn']._listeners.click[0]();

    const demoP = b['btnDemo']._listeners.click[0]();       // 故意不 await，先跑起来
    b['btnDemoStop']._listeners.click[0]();
    await demoP;
    eq(b['demoStatus'].textContent, '已停止', '「停止」真的停下了演示');

    const seqP = b['btnSeqPlay']._listeners.click[0]();
    b['btnSeqStop']._listeners.click[0]();
    await seqP;
    eq(b['btnSeqStop'].disabled, true, '「停止」之后序列按钮变灰（序列已退出）');


  }
}

/* =================== 23. 布局：日志固定在底部 ===================
   原来日志在页面最底下，点完按钮得滚很久才看得到字节。
   现在整页不滚动、面板区自己滚、日志贴底，中间一条可拖的分割条。 */
function sectionLayout() {
  // 高度夹取：不能把日志拖成 0，也不能让日志吃掉整个面板区
  eq(X.clampLogHeight(300, 800), 300, '日志高度 300 正常通过');
  eq(X.clampLogHeight(50, 800), 110, '拖太小被抬到下限 110');
  eq(X.clampLogHeight(2000, 800), 576, '拖太大被压到 72% 窗口高（800 × 0.72）');
  eq(X.clampLogHeight(300, 0), 300, '窗口高传 0 时按 800 兜底');
  eq(X.clampLogHeight(NaN, 800), 110, 'NaN 落回下限（不会把日志拖没）');
  eq(X.clampLogHeight('420', 800), 420, '字符串数值也能用');

  // 结构
  ok(HTML_SRC.includes('id="logResizer"'), '有可拖的分割条 #logResizer');
  ok(HTML_SRC.includes('id="logPanel"'), '日志区有 id #logPanel');
  ok(!/height:min\(72vh,760px\)/.test(HTML_SRC), '旧的固定高度已去掉（现在由 flex 撑满）');

  // CSS：整页不滚、面板区自己滚、日志贴底
  ok(/body\{[^}]*overflow:hidden/.test(HTML_SRC), 'body 不再整体滚动（overflow:hidden）');
  ok(/\.wrap\{[^}]*overflow:auto/.test(HTML_SRC), '面板区 .wrap 自己滚动');
  ok(/#logPanel\{[^}]*display:flex[^}]*flex-direction:column/.test(HTML_SRC),
     '#logPanel 是纵向 flex（标题 + 日志）');
  ok(/#log\{[^}]*flex:1 1 auto/.test(HTML_SRC), '#log 用 flex 撑满剩余高度');
  ok(/#logResizer\{[^}]*cursor:row-resize/.test(HTML_SRC), '分割条是上下拖动光标');
  ok(/#logResizer\{[^}]*height:9px/.test(HTML_SRC), '分割条有 9px 抓取高度（太细不好拖）');
  ok(/\.wrap\{[^}]*flex:1 1 auto/.test(HTML_SRC), '面板区是 flex 剩余空间（日志才贴得住底）');
}

/* =================== 24. 分类栏 + 序列预设 + 序列状态同步 =================== */
async function sectionCategory() {
  /* --- 15 个面板的分类归属 --- */
  const cats = [...HTML_SRC.matchAll(/data-cat="(\w+)">\s*<h2>(\d+) ·/g)]
    .map(m => ({ cat: m[1], num: Number(m[2]) }));
  eq(cats.length, 14, '14 个面板都标了 data-cat');
  const numsOf = c => cats.filter(x => x.cat === c).map(x => x.num).sort((a, b) => a - b);
  eq(numsOf('conn'), [1, 2, 13], '「连接」= 1 / 2 / 13');
  eq(numsOf('play'), [3, 6, 7, 8], '「演奏」= 3 / 6 / 7 / 8');
  eq(numsOf('mod'),  [4, 12], '「调制」= 4 / 12（面板 5 已并入混音台）');
  eq(numsOf('cmd'),  [9, 10, 11, 14], '「指令」= 9 / 10 / 11 / 14（含一键演示）');
  eq(numsOf('mix'),  [15], '「混音」= 15（混音台）');
  eq(cats.filter(x => !['conn','play','mod','cmd','mix'].includes(x.cat)).map(x => x.num), [],
     '没有面板落在未知分类里');

  /* --- 类型栏的位置：在面板区之前（不跟着面板滚） --- */
  const iBar  = HTML_SRC.indexOf('id="catBar"');
  const iFlow = HTML_SRC.indexOf('id="panelFlow"');
  ok(iBar > 0 && iBar < iFlow, '类型栏在面板区之前');
  ok(/#catBar\{[^}]*flex:0 0 auto/.test(HTML_SRC), '类型栏是 flex:0 0 auto（固定不滚）');
  ok(/#panelFlow\{[^}]*column-count:2/.test(HTML_SRC), '面板区用两列流（列高自动平衡）');

  /* --- 点类型栏：真的只显示该类 --- */
  const panels = app.query('#panelFlow > section[data-cat]');
  eq(panels.length, 14, '拿到 14 个面板');
  const btns = app.query('[data-catbtn]');
  eq(btns.length, 6, '类型栏有 6 个按钮（全部 + 5 类）');
  const clickCat = key => btns.find(b => b.dataset.catbtn === key)._listeners.click[0]();
  const visible = () => panels.filter(p => p.style.display !== 'none');

  clickCat('play');
  eq(visible().length, 4, '点「演奏」只剩 4 个面板');
  eq([...new Set(visible().map(p => p.dataset.cat))], ['play'], '「演奏」里只有 play 类');
  clickCat('cmd');
  eq(visible().length, 4, '点「指令」剩 4 个面板');
  clickCat('all');
  eq(visible().length, 14, '点「全部」恢复 14 个');
  eq(btns.filter(b => String(b.className).includes(' on')).map(b => b.dataset.catbtn), ['all'],
     '「全部」按钮高亮，其他不高亮');
  ok(String(app.byId['catHint'].textContent).includes('14'), '提示里显示了当前可见面板数');

  /* --- 面板 8：4 个一键填入 --- */
  const seqBtns = app.query('[data-seq]');
  eq(seqBtns.length, 4, '面板 8 有 4 个一键填入按钮');
  eq(seqBtns.map(b => b.dataset.seq), ['scale', 'chroma', 'sweep', 'arp'],
     '四个预设是 音阶 / 半音阶 / 低→高扫 / 琶音');
  {
    // ⚠ 必须用同一个实例：按钮的监听绑在该实例自己的元素上
    const ins = loadDebugger();
    const b = ins.byId;
    const sb = ins.query('[data-seq]');
    sb[0]._listeners.click[0]();
    ok(String(b['seqInput'].value).startsWith('C4 D4 E4'), '点「音阶」填入音阶');
    eq(Number(b['seqDur'].value), 300, '音阶的默认时长 300ms');
    sb[1]._listeners.click[0]();
    ok(String(b['seqInput'].value).includes('C#4'), '点「半音阶」填入 12 个半音');
    sb[2]._listeners.click[0]();
    eq(b['seqInput'].value, '36 48 60 72 84 96', '点「低→高扫」填入 36→96（手册 §2 那串）');
    eq(Number(b['seqDur'].value), 600, '低→高扫的时长 600ms');
    sb[3]._listeners.click[0]();
    eq(b['seqInput'].value, 'C4 E4 G4 C5 G4 E4', '点「琶音」填入来回琶音');
    eq(b['seqLoop'].checked, false, '填入预设后循环是关的（免得不小心停不下来）');
  }

  /* --- 序列播放时，「正在发声」和进度都要跟着动 --- */
  {
    const writes = [];
    const port = {
      open: async () => {}, close: async () => {}, releaseLock(){},
      writable: { getWriter: () => ({ write: async u8 => { writes.push([...u8]); }, releaseLock(){} }) },
      getInfo: () => ({ usbVendorId: 0x1A86, usbProductId: 0x7523 })
    };
    const b = loadDebugger({ requestPort: async () => port }).byId;   // 真实时钟，方便中途观察
    b['baud'].value = '31250'; b['baudCustom'].value = '31250';
    b['midiCh'].value = '1'; b['velNum'].value = '100';
    b['seqInput'].value = 'C4:200 D4:200';
    b['seqDur'].value = '200'; b['seqGap'].value = '0'; b['seqLoop'].checked = false;
    await b['btnConn']._listeners.click[0]();

    const playP = b['btnSeqPlay']._listeners.click[0]();      // 故意不 await
    await new Promise(r => setTimeout(r, 60));                // 等第一个音发出去

    eq(b['heldTable'].style.display, '', '序列播放中「正在发声」里有音（原来一直是空的）');
    ok(String(b['seqProgress'].textContent).includes('正在播'), '面板 8 显示播放进度');
    ok(String(b['seqProgress'].textContent).includes('1/2'), '进度是 1/2');

    b['btnSeqStop']._listeners.click[0]();
    await playP;
    eq(b['heldTable'].style.display, 'none', '序列停止后「正在发声」清空');
    eq(b['seqProgress'].textContent, '', '序列停止后进度清空');
    ok(b['btnAllOff'].disabled === true, '序列停止后没有残留的音');
  }
}

/* =================== 25. 乐器口下面板 5 整组禁用 ===================
   那 5 个 CC 在乐器口上会被 midi_filter.v 丢掉，与其让人白拖，不如直接禁用 + 黄字警告。 */
function sectionMixDisable() {
  const a = loadDebugger();
  const b = a.byId;
  const setPmode = v => {
    a.pmode.value = v;
    a.query('input[name=pmode]').forEach(r => { if (r._listeners.change) r._listeners.change[0](); });
  };

  // 默认是混音器端口（2026-11-02 改的默认值）
  ok(/value="mixer" checked/.test(HTML_SRC), '默认端口是混音器（HTML 里 mixer 带 checked）');

  // 假 DOM 不解析 checked，所以显式切一次混音口
  setPmode('mixer');
  eq(a.X.mxCtl.vol.rg.disabled, false, '混音口：混音台音量可用');
  ok(!String(b['mxPortNote'].className).includes('warn'), '混音口：提示不是警告');

  // 切到乐器口 → 5 个 CC 禁用，表情不受影响
  setPmode('instrument');
  for (const k of ['vol', 'pan', 'rev', 'cho', 'del']){
    eq(a.X.mxCtl[k].rg.disabled, true, `乐器口：混音台 ${k} 滑杆禁用`);
    eq(a.X.mxCtl[k].nm.disabled, true, `乐器口：混音台 ${k} 数字框禁用`);
  }
  eq(a.X.mxCtl.expr.rg.disabled, false, '乐器口：表情 CC11 仍可用（不在丢弃名单里）');
  eq([b['mxAllVol'].disabled, b['mxAllPan'].disabled, b['mxAllFx'].disabled, b['mxAllFxOn'].disabled],
     [true, true, true, true], '乐器口：批量按钮也禁用');
  eq(String(b['mxPortNote'].className).includes('warn'), true, '乐器口：混音台顶部是黄色警告');
  eq(b['mxPortNote'].innerHTML.includes('丢弃'), true, '警告文案点明了会被丢弃');

  // 切回混音口 → 全部恢复
  setPmode('mixer');
  eq(a.X.mxCtl.vol.rg.disabled, false, '混音口：音量恢复可用');
  eq(b['mxAllFxOn'].disabled, false, '混音口：效果全开恢复可用');
  ok(!String(b['mxPortNote'].className).includes('warn'), '混音口：警告变回普通提示');
}

/* =================== 26. 启动脚本（serve.ps1 / start.cmd） ===================
   这两个文件不进浏览器，但踩过一次很隐蔽的坑：
   serve.ps1 存成 UTF-8 **无 BOM** 时，Windows PowerShell 5.1 会按 GBK 解码中文注释，
   报 "Missing ')' in function parameter list" —— 看起来像语法错，其实是编码问题。
   下面几条就是为了防止以后被人"顺手另存"又弄丢 BOM。 */
function sectionLaunchScripts() {
  const ps1Raw = fs.readFileSync(path.join(__dirname, 'serve.ps1'));
  eq([ps1Raw[0], ps1Raw[1], ps1Raw[2]], [0xEF, 0xBB, 0xBF],
     'serve.ps1 必须是 UTF-8 带 BOM（否则 PowerShell 5.1 按 GBK 解码，直接语法错误）');

  const ps1 = ps1Raw.toString('utf8');
  ok(ps1.includes('python3') && ps1.includes("'py'"), 'serve.ps1 先试 PATH 上的 python3 / python / py');
  ok(ps1.includes('D:\\anaconda\\python.exe'), 'serve.ps1 带 anaconda 兜底路径');
  ok(ps1.includes('Programs\\Python\\Python3*'), 'serve.ps1 带官方安装位置的兜底');
  ok(ps1.includes('import sys'), 'serve.ps1 会真的跑一遍解释器再认（光看文件存在不够）');
  ok(ps1.includes('[string]$Python'), 'serve.ps1 支持 -Python 手动指定');
  ok(ps1.includes('试过这些位置'), 'serve.ps1 找不到时会把试过的路径列出来');

  const cmd = fs.readFileSync(path.join(__dirname, 'start.cmd'));
  eq(cmd.filter(b => b > 127).length, 0, 'start.cmd 必须是纯 ASCII（cmd.exe 的要求）');
  ok(!/[^\r]\n/.test(cmd.toString('latin1')), 'start.cmd 用 CRLF 换行（LF-only 会被 cmd 误解析）');
}

/* =================== 27. 延音踏板（CC64，面板 4） ===================
   CC64 在固件里是真踏板：adsr_vca 的 SUSTAIN 状态松键时若踏板踩着 → PENDING_RELEASE（保持），
   踏板松开才进 RELEASE。页面这边只要把 CC64=127 / 0 发对就行。
   （CC66 sostenuto 固件没接到声部层，所以页面不提供 —— 那条不测。） */
async function sectionSustain() {
  const writes = [];
  const port = {
    open: async () => {}, close: async () => {}, releaseLock(){},
    writable: { getWriter: () => ({ write: async u8 => { writes.push([...u8]); }, releaseLock(){} }) },
    getInfo: () => ({ usbVendorId: 0x1A86, usbProductId: 0x7523 })
  };
  const b = loadDebugger({ requestPort: async () => port }).byId;
  b['baud'].value = '31250'; b['baudCustom'].value = '31250';
  b['midiCh'].value = '1'; b['note'].value = '60'; b['velNum'].value = '100';
  await b['btnConn']._listeners.click[0]();
  const last = () => writes[writes.length - 1];

  eq(b['btnSustain'].textContent, '踩下延音踏板', '初始是「踩下延音踏板」');
  eq(String(b['sustainOut'].textContent).includes('松开'), true, '状态显示「松开」');

  await b['btnSustain']._listeners.click[0]();
  eq(last(), [0xB0, 64, 127], '点一下 → CC64=127（踩下）');
  eq(b['btnSustain'].textContent, '松开延音踏板', '按钮文字变成「松开延音踏板」');
  eq(String(b['sustainOut'].textContent).includes('踩下'), true, '状态显示「踩下」');
  eq(String(b['btnSustain'].className).includes('on'), true, '踩下时按钮高亮');

  await b['btnSustain']._listeners.click[0]();
  eq(last(), [0xB0, 64, 0], '再点一下 → CC64=0（松开）');
  eq(b['btnSustain'].textContent, '踩下延音踏板', '文字变回「踩下延音踏板」');
  ok(!String(b['btnSustain'].className).includes('on'), '松开后不高亮');

  // 跟着全局通道走
  b['midiCh'].value = '4';
  await b['btnSustain']._listeners.click[0]();
  eq(last(), [0xB3, 64, 127], '通道 4 → 状态字节 0xB3');
  eq(writes[writes.length - 1][1], 64, 'CC 号是 64（不是别的）');

  // 「全部 Note Off」必须先松踏板，否则 Note Off 会被踏板挡住
  await b['btnOn']._listeners.click[0]();      // 此刻踏板是踩下的
  writes.length = 0;
  await b['btnAllOff']._listeners.click[0]();
  eq(writes[0], [0xB3, 64, 0], '「全部 Note Off」第一笔先发 CC64=0 松踏板');
  ok(writes.some(w => (w[0] & 0xF0) === 0x80), '然后再发 Note Off');
}

/* =================== 28. 声像「居中」按钮 =================== */
async function sectionPanCenter() {
  const writes = [];
  const port = {
    open: async () => {}, close: async () => {}, releaseLock(){},
    writable: { getWriter: () => ({ write: async u8 => { writes.push([...u8]); }, releaseLock(){} }) },
    getInfo: () => ({ usbVendorId: 0x1A86, usbProductId: 0x7523 })
  };
  const a = loadDebugger({ requestPort: async () => port });
  const b = a.byId;
  b['baud'].value = '31250'; b['baudCustom'].value = '31250';
  b['midiCh'].value = '1';
  await b['btnConn']._listeners.click[0]();

  const panCtl = a.X.mxCtl.pan;
  const btn10 = () => a.X.mxCtl.panBtn;

  ok(!!panCtl, '混音台里有声像控件');
  ok(!!btn10(), '声像那行有「居中」按钮');
  eq(btn10().disabled, true, '乐器口：「居中」按钮和滑杆一起被禁用');

  // 切到混音口 → 可用
  a.pmode.value = 'mixer';
  a.query('input[name=pmode]').forEach(r => { if (r._listeners.change) r._listeners.change[0](); });
  eq(btn10().disabled, false, '混音口：「居中」按钮恢复可用');

  // 拖到偏左，点「居中」→ 必须发出 CC10 = 64
  const rg = a.X.mxCtl.pan.rg;
  rg.value = '20';
  rg._listeners.input[0]();
  a.X.mxCtl.panBtn._listeners.click[0]();
  const lastW = writes[writes.length - 1];
  eq(lastW, [0xB0, 10, 64], '「居中」按钮发出 CC10 = 64');
}

/* =================== 结果 =================== */
(async () => {
  await sectionEndToEnd();
  await sectionChecker();
  await sectionPanels();
  await sectionDemo();
  await sectionEnvPreset();
  await sectionTimbre();
  sectionFold();
  await sectionEveryCommand();
  await sectionMisc();
  await sectionButtons();
  sectionLayout();
  await sectionCategory();
  sectionMixDisable();
  sectionLaunchScripts();
  await sectionSustain();
  await sectionPanCenter();

  console.log('');
  if (fail === 0) {
    console.log(`PASS  test_logic.js —— ${pass} 项断言全部通过`);
    process.exit(0);
  } else {
    console.log(`FAIL  test_logic.js —— 通过 ${pass}，失败 ${fail}`);
    process.exit(1);
  }
})();
