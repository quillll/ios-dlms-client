#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
把 docs/DLMS知识库.md 拆成语义块，输出 docs/DLMS知识库.jsonl。

设计目标：给 AI（RAG / embedding 检索）用，而不是给人读。
每个 JSON 对象 = 一个最小可独立理解的语义块，带：
  - section_path : 章节路径，便于定位与过滤
  - tags          : 检索关键词
  - evidence      : 从正文里抽出的证据锚点（如 C:client.h:226）
  - confidence    : A 级源码确认 / B 级多源一致 / 未核实

用法：
    python tools/gen_kb_jsonl.py
"""

import json
import os
import re

DOC_NAME = "DLMS知识库"
SRC = os.path.join("docs", "DLMS知识库.md")
DST = os.path.join("docs", "DLMS知识库.jsonl")

# 证据锚点：形如 C:client.h:226 / REF:communication.c:914 / C:enums.h:525-558
EVIDENCE_RE = re.compile(r"\b((?:C|REF):[A-Za-z0-9_.]+(?::\d+(?:-\d+)?)?)")

# 可信度标记
CONF_PATTERNS = [
    (r"❓\s*未核实", "未核实"),
    (r"\bA\s*级", "A级-源码确认"),
    (r"\bB\s*级", "B级-多源一致"),
]


def split_sections(text):
    """按 ## / ### 标题切成 (level, title, body_lines) 序列。"""
    out = []
    cur = None
    for line in text.splitlines():
        m = re.match(r"^(#{2,3})\s+(.*)$", line)
        if m:
            if cur:
                out.append(cur)
            cur = {"level": len(m.group(1)), "title": m.group(2).strip(),
                   "lines": []}
        elif cur is not None:
            cur["lines"].append(line)
    if cur:
        out.append(cur)
    return out


def build_chunks(text):
    sections = split_sections(text)
    chunks = []
    # 维护当前章节路径
    path_h2 = ""
    path_h3 = ""
    idx = 0

    for sec in sections:
        body = "\n".join(sec["lines"]).strip()
        if sec["level"] == 2:
            path_h2 = sec["title"]
            path_h3 = ""
        else:
            path_h3 = sec["title"]

        if not body:
            continue

        idx += 1
        section_path = " > ".join([p for p in (path_h2, path_h3) if p]) or DOC_NAME

        evidence = sorted(set(EVIDENCE_RE.findall(body)))

        # 第 0 章是"怎么读本文档"的元说明，本身不承载事实，单独标记，
        # 否则它逐条解释分级规则会被下面的规则误判成"未核实"。
        if path_h2.startswith("0."):
            confidence = "元信息"
        else:
            confidence = "未标注"
            for pat, label in CONF_PATTERNS:
                if re.search(pat, body):
                    confidence = label
                    break

        # 检索关键词：标题分词 + 正文里出现的高频专有名词
        title_tokens = re.findall(r"[A-Za-z_][A-Za-z0-9_]{2,}|[一-鿿]{2,}", sec["title"])
        known_terms = [
            "cl_readLN", "cl_writeLN", "cl_methodLN", "cl_aarqRequest",
            "cl_parseAAREResponse", "cl_getApplicationAssociationRequest",
            "cl_parseApplicationAssociationResponse", "cl_releaseRequest2",
            "cl_disconnectRequest", "cl_getObjectsRequest", "cl_receiverReady",
            "DLMS_SECURITY", "DLMS_DATA_TYPE", "DLMS_AUTHENTICATION",
            "DLMS_OBJECT_TYPE", "DLMS_COMMAND", "DLMS_SECURITY_POLICY",
            "DLMS_SECURITY_SUITE", "systemTitle", "sourceSystemTitle",
            "invocationCounter", "blockCipherKey", "authenticationKey",
            "dedicatedKey", "bb_addHexString", "cip_tracePdu", "byteArray",
            "OBIS", "HLS", "GMAC", "LLS", "AARQ", "AARE", "HDLC", "Wrapper",
            "SNRM", "Association View", "Profile Generic", "Register",
        ]
        tags = sorted(set(title_tokens) | {t for t in known_terms if t in body})

        chunks.append({
            "id": "%s-%03d" % (DOC_NAME, idx),
            "doc": DOC_NAME,
            "section_path": section_path,
            "title": sec["title"],
            "level": sec["level"],
            "tags": tags[:24],
            "confidence": confidence,
            "evidence": evidence,
            "chars": len(body),
            "content": body,
        })
    return chunks


def main():
    with open(SRC, "r", encoding="utf-8") as f:
        text = f.read()

    chunks = build_chunks(text)

    with open(DST, "w", encoding="utf-8", newline="\n") as f:
        for c in chunks:
            f.write(json.dumps(c, ensure_ascii=False) + "\n")

    print("chunks: %d -> %s" % (len(chunks), DST))
    for c in chunks[:5]:
        print("  %s | %s | %s" % (c["id"], c["section_path"], c["confidence"]))


if __name__ == "__main__":
    main()
