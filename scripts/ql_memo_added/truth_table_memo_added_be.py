#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""建议池②「AI 记住气泡反馈 + 一键撤销」**后端**真值表 —— 跑线上那份字节。

为什么必须在容器外单独 import 线上 memory_store.py（照 ql_followup 的同款做法）：
本项的后端判定全在 memory_store.check_and_save / delete_entry 与 stream_api 的
memoAdded 下发里，纯逻辑，本机可 import 执行。镜像一份实现等于自己骗自己。

⚠️ 隔离铁律：**必须先把 QL_DATA_DIR 指到临时目录再 import**，否则 import 时
MEMORY_PATH 就按默认 /volume1/.../data/memory.json 算好了，本表会**写真实用户记忆**
（2026-10-04 已踩过一次：写进真 memory.json 才发现，只能 delete 撤回）。

钉住的行为：
  1) 「记住我喜欢喝美式」→ 真存进 memory.json（这条链路历史上从未被调过，见 stream_api 注释）
  2) 同一条再说一遍 → 返回 []（去重）⇒ App 侧天然不会重复弹「已记住」
  3) 一句里含两个记忆意图 → 都返回（App 弹「等 N 条」）
  4) 撤销 = delete_entry 真删；删完 list_entries 里没有
  5) 删不存在的条目 → False 且不误删别的（App 撤销失败要能如实报错）
  6) 空文本 / 过短 → 不写盘
  7) stream_api 的 memoAdded 必须是「只增不减的累积数组」且**只报本次新增**（源级断言）
  8) memory_api 的 delete 响应要带 ok 字段（App undoMemo 判 ok==true）
"""
import json
import os
import shutil
import sys
import tempfile

MEM = os.environ.get("QL_MEM_SRC") or "/opt/data/cache/scratch/mem_store_live.py"
API = os.environ.get("QL_MAPI_SRC") or "/opt/data/cache/scratch/mapi_live.py"
SA = os.environ.get("QL_STREAM_SRC") or "/opt/data/cache/scratch/stream_api_live.py"

PASS = FAIL = 0
FAILS = []


def check(name, cond, extra=""):
    global PASS, FAIL
    if cond:
        PASS += 1
        print("  ✅ %s%s" % (name, ("  ← " + str(extra)) if extra else ""))
    else:
        FAIL += 1
        FAILS.append("%s  ← %s" % (name, extra))
        print("  ❌ %s%s" % (name, ("  ← " + str(extra)) if extra else ""))


for p in (MEM, API, SA):
    if not os.path.exists(p):
        print("❌ 找不到后端线上源码：%s" % p)
        sys.exit(1)

tmp = tempfile.mkdtemp(prefix="ql_memo_added_")
try:
    sys.path.insert(0, tmp)
    shutil.copy(MEM, os.path.join(tmp, "memory_store.py"))
    import memory_store as M

    # 🚨🚨 隔离铁律（2026-10-04 实踩过一次）：线上 memory_store.py 第 16 行是
    # **硬编码** MEMORY_PATH = "/volume1/.../data/memory.json"（不像仓内旧副本那样读
    # QL_DATA_DIR），所以本表**在容器外直接 import 它就会写真用户的记忆**——
    # 第一次跑时写进了两条真条目，只能调 delete_entry 撤回。
    # 办法：import 后立刻把模块变量改到临时目录；改不了就不是隔离，一律拒绝跑。
    check("① import 后 MEMORY_PATH 可被重定向（能隔离）",
          M.MEMORY_PATH.startswith("/"), M.MEMORY_PATH)
    M.MEMORY_PATH = os.path.join(tmp, "memory.json")
    check("① 已改写到临时目录（绝不碰真实 memory.json）",
          M.MEMORY_PATH.startswith(tmp) and not M.MEMORY_PATH.startswith("/volume1"),
          M.MEMORY_PATH)
    # 改完必须自检：真读一次确认落在临时目录里
    M.check_and_save("记住隔离自检条目")
    check("① 自检条目写在临时目录里",
          os.path.exists(os.path.join(tmp, "memory.json"))
          and "隔离自检条目" in M.list_entries())
    M.delete_entry("隔离自检条目")

    # ─────── ① 自动写入（这条链路历史上是死的：check_and_save 无调用点）───────
    got = M.check_and_save("记住我喜欢喝美式", session_id="s1")
    check("① 记住…→ 返回新条目", got == ["我喜欢喝美式"], got)
    check("① 已落盘", "我喜欢喝美式" in M.list_entries(), M.list_entries())

    # ─────── ② 去重（同一条不重复报 → App 不重复弹条）───────
    got2 = M.check_and_save("记住我喜欢喝美式", session_id="s1")
    check("② 同一条再说一遍返回空（不重复报）", got2 == [], got2)
    check("② 条目不重复", M.list_entries().count("我喜欢喝美式") == 1)

    # ─────── ③ 一句多意图 ───────
    # 两个前提（照 check_and_save 的正则与守卫写，别写成想当然）：
    #   ① 用词表里真有的前缀（我是 / 我喜欢）；捕获组吃到标点为止，故两个意图必须
    #      用逗号/句号隔开，否则后一个会被前一个的捕获组一起吞掉。
    #   ② 捕获内容长度必须 ≥2（len<2 不存），所以不能写「我喜欢猫」这种单字词组。
    got3 = M.check_and_save("我是苏州人，我喜欢喝奶茶", session_id="s1")
    check("③ 一句两意图都返回", len(got3) == 2, got3)
    ents = M.list_entries()
    check("③ 两意图都落盘", any("苏州" in e for e in ents) and any("奶茶" in e for e in ents), ents)
    check("③ 单字词组不入库（len<2 守卫）",
          M.check_and_save("我喜欢猫") == [] and not any(e == "猫" for e in M.list_entries()))

    # ─────── ④ 撤销 = 真删（App「撤销」按钮的唯一实现路径）───────
    ok = M.delete_entry("我喜欢喝美式")
    check("④ delete_entry 真删成功", ok is True, ok)
    check("④ 删后不在列表", "我喜欢喝美式" not in M.list_entries())

    # ─────── ⑤ 删不存在 → False 且不误伤 ───────
    before = list(M.list_entries())
    ok2 = M.delete_entry("根本不存在的条目")
    check("⑤ 删不存在返回 False", ok2 is False, ok2)
    check("⑤ 列表未被误伤", M.list_entries() == before)

    # ─────── ⑥ 空/过短不写盘 ───────
    n0 = len(M.list_entries())
    check("⑥ 空文本不写", M.check_and_save("") == [])
    check("⑥ 单字不写", M.check_and_save("记住你") == [])
    check("⑥ 数量未变", len(M.list_entries()) == n0)

    # ─────── ⑦ 源级：memoAdded 只报本次新增 + 只增不减 ───────
    sa = open(SA, encoding="utf-8", errors="ignore").read()
    check("⑦ stream_api 调 check_and_save", "memory_store.check_and_save(" in sa)
    check("⑦ 写入走 _memo_seen 去重（同一流不重复报）",
          '_memo_seen = st.setdefault("memoAdded", [])' in sa)
    check("⑦ 单流最多冒 3 条（防刷屏）", "_memo_new[:3]" in sa)
    check("⑦ poll 下发 memoAdded 键", '"memoAdded"' in sa)
    check("⑦ 下发为整流累积（非本次增量）",
          '"memoAdded": [str(x) for x in (st.get("memoAdded") or [])]' in sa)
    # 写入异常必须被吞（否则整条流挂掉）：判据用**紧随其后的 except 分支**，
    # 不用「往上找最近的 try」（那会捞到 _worker 开头那个包住整个函数的 try，
    # 距离 900+ 字符，导致判据形同虚设——第一版就是这么写错的，变异没红）。
    i_try = sa.rfind('memory_store.check_and_save(')   # 末次 = 真调用点（前面几处都在注释里）
    tail = sa[i_try:i_try + 900]
    check("⑦ check_and_save 有专属 except 兜住（写失败不带崩流）",
          'except Exception as e:' in tail and '[memory] 自动写入失败' in tail,
          "调用后 900 字符内无 except 兜底")

    # ─────── ⑧ 源级：memory_api delete 响应带 ok（App 判 ok==true）───────
    api = open(API, encoding="utf-8", errors="ignore").read()
    check("⑧ delete 分支存在", "/api/memory/delete" in api)
    check("⑧ delete 回 ok 字段", '"ok": ok' in api or '"ok": True' in api)
    check("⑧ delete 回 entries（App 同步记忆页）",
          '"entries": memory_store.list_entries()' in api)
finally:
    shutil.rmtree(tmp, ignore_errors=True)

print("\n建议池② AI 记住反馈+撤销 · 后端真值表：%d 通过 / %d 失败" % (PASS, FAIL))
if FAIL:
    for f in FAILS:
        print("  ❌ " + f)
    sys.exit(1)
print("🎉 全部通过 %d" % PASS)
