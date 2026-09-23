#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
检查 Swift 的 `enum CodingKeys: String, CodingKey` 是否**只列了真实存在的存储属性**。

## 为什么需要这个脚本

合成 `Encodable` 时，编译器会为 `CodingKeys` 的**每一个 case** 去找同名存储属性；
找不到就整份不满足协议。而报错**只落在 struct 声明行**：

    error: type 'ConnectionConfig' does not conform to protocol 'Encodable'

**完全不会指向那个多余的 case** —— 本项目 CI 已经因此红过两次
（先是往 `CodingKeys` 里留了 `serverAddressWidth`；半修之后又被 `serverAddress` 绊倒）。
本脚本把判据变成可本地执行的检查，把"等 CI、然后大海捞针"变成一条命令。

## 判据

- `CodingKeys` 里的每个 case 都必须能对应到一个**存储属性**（`var`/`let`，非 `static`、非计算属性）。
- **已淘汰、只读不写**的旧键要另开一个 enum（例如 `LegacyKeys`）**只用于解码** ——
  别的名字不参与合成 Codable，所以那里的 case 没有对应属性是**故意的、合法的**。
  本脚本只检查名为 `CodingKeys` 的那个 enum。

### 关于"显式实现 encode(to:)"的补充

严格来说：**只要显式实现了 `encode(to:)`**，编译器就不再合成它，
此时 `CodingKeys` 里多留一个"只读不写"的旧 case **并不会**报错（本项目历史上就是这么绕过的）。

但本项目仍**按严格判据检查**，理由是：
- 那种做法把正确性挂在一个"必须记得别删掉显式 encode"的约定上，删了就立刻炸；
- 把旧键分离到 `LegacyKeys` 后，`CodingKeys` 的含义永远只有一种（"会写出的字段"），
  显式 `encode(to:)` 也就回到"声明要写哪些字段"的本职。

→ 风格规定：**`CodingKeys` 只列真实存储属性；旧键一律走单独的 enum。**

## 用法

    python3 tools/chk_codingkeys.py            # 从脚本位置推断仓库根
    python3 tools/chk_codingkeys.py <repo根>   # 显式指定

退出码：0 = 全部通过；1 = 发现问题。
"""
import io
import os
import re
import sys

SCAN_DIRS = ["Sources", "DLMSApp", "Tests"]


def repo_root():
    if len(sys.argv) > 1:
        return os.path.abspath(sys.argv[1])
    return os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def swift_files(root):
    for d in SCAN_DIRS:
        base = os.path.join(root, d)
        if not os.path.isdir(base):
            continue
        for dirpath, _, names in os.walk(base):
            for n in sorted(names):
                if n.endswith(".swift"):
                    yield os.path.join(dirpath, n)


def brace_block(text, start):
    """start 是 '{' 的下标；返回与之匹配的 '}' 下标（找不到返回 -1）。"""
    depth = 0
    for i in range(start, len(text)):
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                return i
    return -1


def case_names(body):
    """取 body 里所有 case 名。

    ⚠️ **必须逐行解析**：早前用单个正则 `case\\s+([\\w\\s,]*)` 时，字符类里的 `\\s`
    **含换行**，会把后面几行连着吞成一次匹配，而代码只取了首行 →
    每段只拿到第一行的 case，**漏检**就是这么来的。
    """
    out = []
    for line in body.split("\n"):
        s = line.strip()
        if not s.startswith("case "):
            continue
        rest = s[5:]                      # 去掉 'case '
        rest = rest.split("//")[0]        # 去行内注释
        rest = rest.split("=")[0]         # 去 rawValue（若写成 case a = "a"）
        for part in rest.split(","):
            name = part.strip()
            if re.fullmatch(r"[A-Za-z_]\w*", name):
                out.append(name)
    return out


def stored_properties(type_body):
    """类型的存储属性名（排除 static / 计算属性）。"""
    props = []
    for line in type_body.split("\n"):
        s = line.strip()
        if not s or s.startswith("//"):
            continue
        if "static" in s:
            continue
        m = re.match(r"(?:public |private |internal |fileprivate )?(?:var|let)\s+(\w+)\s*[:=]", s)
        if not m:
            continue
        if "{" in s:                      # 计算属性（同行就带闭包体）
            continue
        props.append(m.group(1))
    return props


def check(root):
    problems = []
    checked = 0
    for path in swift_files(root):
        text = io.open(path, encoding="utf-8", errors="replace").read()
        for m in re.finditer(r"enum\s+CodingKeys\s*:\s*String\s*,\s*CodingKey\s*\{", text):
            bstart = text.index("{", m.end() - 1)
            bend = brace_block(text, bstart)
            if bend < 0:
                continue
            cases = case_names(text[bstart + 1:bend])
            if not cases:
                continue

            # 所属类型：向前找最近的**行首** struct/class（行首锚定，避免匹配到注释里的文字）
            head = text[:m.start()]
            tm = None
            for t in re.finditer(r"^[ \t]*(?:struct|final class|class)\s+(\w+)", head, re.M):
                tm = t
            if tm is None:
                continue

            tbs = head.index("{", tm.end()) if "{" in head[tm.end():] else -1
            if tbs < 0:
                continue
            tbe = brace_block(head, tbs)
            type_body = head[tbs:tbe] if tbe > 0 else head[tbs:]

            props = set(stored_properties(type_body))
            checked += 1
            for c in cases:
                if c not in props:
                    problems.append((os.path.relpath(path, root), tm.group(1), c))
    return checked, problems


def main():
    root = repo_root()
    checked, problems = check(root)
    print(u"检查了 %d 个 CodingKeys 声明" % checked)
    if not problems:
        print(u"全部 OK ✓ —— 每个 case 都能对应到一个存储属性")
        return 0
    print(u"\n!! 有 case 找不到对应存储属性（会让类型不满足 Encodable/Decodable）:")
    for rel, type_name, case in problems:
        print(u"  %s  类型 %s 的 CodingKeys 里的 case '%s' 无对应属性" % (rel, type_name, case))
    print(u"\n修法（二选一）：\n"
          u"  a) 把这类「只读不写」的旧键移到单独的 enum（如 LegacyKeys），只用它做解码\n"
          u"     —— CodingKeys 保持「只含真实属性」，最稳（本项目采用）。\n"
          u"  b) 显式实现 encode(to:)、且**不编码**那个旧键 —— 合成的 encode 就不会再发生。\n"
          u"     注意：这种做法下，一旦有人删掉显式 encode，同样的报错会立刻回来。")
    return 1


if __name__ == "__main__":
    sys.exit(main())
