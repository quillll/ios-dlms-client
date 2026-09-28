#!/usr/bin/env python3
"""
检查 Swift 文件里「跨 struct 引用」的疑似错误 —— 本机提前抓，别等 CI。

背景（真实事故）
---------------
`ObisLibraryView.swift` 里有**两个** struct：
  · `ObisLibraryView`  —— 复制源属性叫 `copySource`
  · `ObisEditorSheet`  —— 复制源属性叫 `template`（由 `ObisEditorSheet(item:template:)` 传入）
我在编辑器里写了 `copySource?.id` → 那是**外层 struct 的属性，本类型看不到** →
`error: cannot find 'copySource' in scope`。

这类错误**只有 CI 能发现**（SwiftUI 本机编不了），一次往返约 5 分钟。
所以用纯文本启发式在本地先抓一遍。

判据（刻意偏向"高精度、宁少报不误报"）
------------------------------------
1. 按大括号深度切出**顶层类型**（struct/class/enum/extension）的行范围
2. 类型 B 的「成员」= **直接在大括号深度 1 上**声明的 var/let/func
   （不收集嵌套函数里的局部变量 —— 那会带来大量误报）
3. 在类型 A 的正文里找**裸标识符**：
   · 排除 `x.y` 里的 `y`（成员访问，最常见的一类误报来源）
   · 排除注释与字符串字面量里的内容
   · 排除 Swift 关键字与常见泛型/标准库名
4. 若该标识符「只在 B 里声明为成员、且 A 里**任何位置**都没有声明」→ 报为疑似

退出码：0 = 干净；1 = 有疑似（用于闸门）
"""
import io
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TARGET_DIRS = ["DLMSApp", "Sources/DLMSBridge", "Sources/DLMSModels"]

# Swift 关键字 / 标准库 / 常见无需声明的名字 —— 避免误报
KEYWORDS = set("""
Self self super nil true false some any in out inout var let func return if else for while
repeat switch case default break continue guard defer do try catch throw throws as is
init deinit subscript extension struct class enum protocol typealias associatedtype
import static public private fileprivate internal open final lazy weak unowned mutating
nonmutating override required convenience dynamic indirect prefix postfix infix
Any AnyObject Void Never Error String Int Int8 Int16 Int32 Int64 UInt UInt8 UInt16 UInt32 UInt64
Double Float Bool Character Array Dictionary Set Optional Result Range IndexSet UUID Date Data URL
Get Set willSet didSet get async await actor where with print
""".split())

# 属性包装器（它们后面才是真正的属性名）
WRAPPERS = {"State", "Binding", "Environment", "EnvironmentObject", "ObservedObject",
            "StateObject", "Published", "FocusState", "SceneStorage", "AppStorage"}

DECL_RE = re.compile(r'\b(?:var|let|func)\s+([A-Za-z_]\w*)')
# 绑定式声明：`for X in` / `if let X` / `case .a(let X)` —— 漏了它们会大量误报
BIND_RE = re.compile(r'\b(?:for|let|var|case)\s+([A-Za-z_]\w*)')
# 闭包参数：`{ item in` / `{ a, b in`
CLOSURE_RE = re.compile(r'\{\s*([A-Za-z_]\w*(?:\s*,\s*[A-Za-z_]\w*)*)\s+in\b')
# 函数形参：`func f(a: T, b: T)` —— 取每个 `名字:` 的名字
PARAM_RE = re.compile(r'func\s+[A-Za-z_]\w*\s*\(([^)]*)\)')
PARAM_NAME_RE = re.compile(r'(?:^|,)\s*(?:[A-Za-z_]\w*\s+)?([A-Za-z_]\w*)\s*:')
# `@State private var query` / `@Environment(\.editMode) private var editMode`
WRAPPED_RE = re.compile(r'@' + '(' + '|'.join(sorted(WRAPPERS)) + r')'
                        r'(?:\([^)]*\))?\s*(?:private|public|internal|fileprivate)?\s*'
                        r'(?:var|let)\s+([A-Za-z_]\w*)')
TYPE_RE = re.compile(r'^\s*(?:public\s+|private\s+|internal\s+|fileprivate\s+|final\s+)*'
                     r'(struct|class|enum|extension|protocol)\s+([A-Za-z_]\w*)')
IDENT_RE = re.compile(r'[A-Za-z_]\w*')


def strip_noise(text: str) -> str:
    """把注释与字符串字面量替换成等长空白（保留行列位置，便于按行处理）。"""
    out = list(text)
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        # 行注释
        if c == '/' and i + 1 < n and text[i + 1] == '/':
            while i < n and text[i] != '\n':
                out[i] = ' '
                i += 1
            continue
        # 块注释（Swift 支持嵌套）
        if c == '/' and i + 1 < n and text[i + 1] == '*':
            depth = 1
            out[i] = out[i + 1] = ' '
            i += 2
            while i < n and depth:
                if text[i] == '/' and i + 1 < n and text[i + 1] == '*':
                    depth += 1
                    out[i] = out[i + 1] = ' '
                    i += 2
                elif text[i] == '*' and i + 1 < n and text[i + 1] == '/':
                    depth -= 1
                    out[i] = out[i + 1] = ' '
                    i += 2
                else:
                    if text[i] != '\n':
                        out[i] = ' '
                    i += 1
            continue
        # 字符串字面量
        #
        # ⚠️ **必须只吞掉字符串本身，不能吞到行尾** ✗
        # 第一版写成"从引号到 EOL 全部置空"，于是
        #     Button("好", role: .cancel) {}
        # 里字符串**之后**的收尾 `{}` 也被吞掉 → 每行多算一个 `{`
        # → 大括号深度一路漂移，`ObisEditorSheet` 根本没被识别成独立类型，
        # 于是**注入原 bug 也报通过**（反向自测抓到的）。
        if c == '"':
            if text.startswith('"""', i):                 # 三引号多行字符串
                out[i] = out[i + 1] = out[i + 2] = ' '
                j = i + 3
                while j < n:
                    if text.startswith('"""', j):
                        out[j] = out[j + 1] = out[j + 2] = ' '
                        j += 3
                        break
                    if text[j] != '\n':
                        out[j] = ' '
                    j += 1
                i = j
                continue
            j = i + 1                                     # 单行字符串
            out[i] = ' '
            while j < n:
                ch2 = text[j]
                if ch2 == '\\':                          # 转义：连下一个字符一起吞
                    out[j] = ' '
                    if j + 1 < n:
                        out[j + 1] = ' '
                    j += 2
                    continue
                if ch2 == '\n':
                    break                                 # 未闭合（容错）
                out[j] = ' '
                j += 1
                if ch2 == '"':
                    break                                 # 闭引号，之后的内容保留
            i = j
            continue
        i += 1
    return ''.join(out)


def scan(path: str):
    raw = io.open(path, encoding='utf-8', errors='ignore').read()
    clean = strip_noise(raw)
    lines = clean.split('\n')
    raw_lines = raw.split('\n')

    # ── 切出顶层类型：追踪大括号深度，记录 depth 0→1 的那一行
    scopes = []          # (name, start_line, end_line)
    depth = 0
    open_scope = None
    for ln, line in enumerate(lines):
        for ch in line:
            if ch == '{':
                if depth == 0:
                    m = TYPE_RE.match(line)
                    if m:
                        open_scope = (m.group(2), ln)
                depth += 1
            elif ch == '}':
                depth -= 1
                if depth == 0 and open_scope:
                    scopes.append((open_scope[0], open_scope[1], ln))
                    open_scope = None
    if open_scope:                                   # 文件末尾没闭合（容错）
        scopes.append((open_scope[0], open_scope[1], len(lines) - 1))

    # ── 每个类型的「直接深度成员」（depth 1）与「任意位置声明」
    def line_depth(ln):
        d, base = 0, None
        # 从类型起始行开始累计
        for k in range(scope_start, ln + 1):
            for ch in lines[k]:
                if ch == '{':
                    if k == scope_start and base is None:
                        base = d + 1        # 类型自身那一层
                    d += 1
                elif ch == '}':
                    d -= 1
        return d

    members = {}      # 类型名 → set(成员名)
    declared = {}     # 类型名 → set(任意位置的声明名)
    for name, s, e in scopes:
        scope_start = s
        dm, alld = set(), set()
        for k in range(s, e + 1):
            for m in DECL_RE.finditer(lines[k]):
                alld.add(m.group(1))
            for m in WRAPPED_RE.finditer(lines[k]):
                alld.add(m.group(2))
            for m in BIND_RE.finditer(lines[k]):
                alld.add(m.group(1))
            for m in CLOSURE_RE.finditer(lines[k]):
                for part in m.group(1).split(','):
                    alld.add(part.strip())
            for m in PARAM_RE.finditer(lines[k]):
                for pm in PARAM_NAME_RE.finditer(m.group(1)):
                    alld.add(pm.group(1))
            # 直接深度：数这一行之前的花括号净值
            d = 0
            for j in range(s, k):
                for ch in lines[j]:
                    if ch == '{':
                        d += 1
                    elif ch == '}':
                        d -= 1
            if d == 1:                                # 类型体的直接层
                for m in DECL_RE.finditer(lines[k]):
                    dm.add(m.group(1))
                for m in WRAPPED_RE.finditer(lines[k]):
                    dm.add(m.group(2))
        # 形参必须对**整个作用域文本**扫 —— 函数签名常常跨行：
        #     private static func makeItem(code: String, name: String, unit: String,
        #                                  objectClass: Int? = nil, attribute: Int? = nil,
        #                                  data: String = "") -> ObisItem?
        # 按单行扫会漏掉后两行的形参 → 它们被当成"别的类型的成员" → 误报。
        joined = '\n'.join(lines[s:e + 1])
        for m in PARAM_RE.finditer(joined):
            for pm in PARAM_NAME_RE.finditer(m.group(1)):
                alld.add(pm.group(1))
        # ⚠️ **按类型名合并**，不是按 scope 覆盖 ——
        # `struct ObisItem` 与 `extension ObisItem` 是**同一个类型**的两个 scope，
        # 用名字做 key 直接赋值会让后者把前者的成员表冲掉 → 大量误报。
        members.setdefault(name, set()).update(dm)
        declared.setdefault(name, set()).update(alld)

    # ── 找跨类型引用
    problems = []
    for name, s, e in scopes:
        others = set()
        for other, dm in members.items():
            if other != name:
                others |= dm
        if not others:
            continue
        mine = declared[name]
        for k in range(s, e + 1):
            line = lines[k]
            for m in IDENT_RE.finditer(line):
                tok = m.group(0)
                if tok in KEYWORDS or tok in mine or tok not in others:
                    continue
                # 跳过 `x.y` 里的 y（成员访问）
                p = m.start() - 1
                while p >= 0 and line[p] == ' ':
                    p -= 1
                if p >= 0 and line[p] == '.':
                    continue
                # 跳过实参标签 / 类型标注：`ObisEditorSheet(item:…, template: …)`、
                # `objectClass: cls`、`String(format: "…")` —— 全都以 `名字:` 形态出现
                q = m.end()
                while q < len(line) and line[q] == ' ':
                    q += 1
                if q < len(line) and line[q] == ':':
                    continue
                # 跳过 `func y(` / `struct y` 之类的声明处
                if re.search(r'\b(var|let|func|struct|class|enum|case)\s+' + re.escape(tok) + r'\b', line):
                    continue
                problems.append((name, k + 1, tok, raw_lines[k].strip()))
    return scopes, problems


def main():
    files, total, bad = [], 0, 0
    for d in TARGET_DIRS:
        base = os.path.join(ROOT, d)
        for dirpath, _, names in os.walk(base):
            for f in sorted(names):
                if f.endswith('.swift'):
                    files.append(os.path.join(dirpath, f))

    for path in files:
        scopes, problems = scan(path)
        if len(scopes) < 2:
            continue                                  # 单类型文件不可能有这个问题
        total += 1
        if problems:
            bad += 1
            rel = os.path.relpath(path, ROOT).replace('\\', '/')
            print('[!] %s（%d 个类型）' % (rel, len(scopes)))
            seen = set()
            for owner, ln, tok, text in problems:
                key = (owner, tok)
                if key in seen:
                    continue
                seen.add(key)
                print('    第 %d 行  在 %s 里用了 `%s` —— 它只在别的类型里声明' % (ln, owner, tok))
                print('      %s' % text[:90])
            print()

    print('检查了 %d 个多类型 Swift 文件' % total)
    if bad:
        print('❌ %d 个文件有疑似跨类型引用 —— 这类错误本机编不出来，但 CI 会红' % bad)
        return 1
    print('✅ 未发现跨类型引用')
    return 0


if __name__ == '__main__':
    sys.exit(main())
