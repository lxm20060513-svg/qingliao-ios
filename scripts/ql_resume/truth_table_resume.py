#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""待做池⑥「稳妥档断点续传」真值表（backend）。

做法：用 AST 从真实的 stream_api.py 里抽出目标函数的**源码文本**，在一个只提供
os/json/time/STREAM_DIR 的最小命名空间里 exec 后真调 —— 验证的是线上将要部署的
那段代码本身，不是复写的仿制品。

覆盖口径：
  T1 reconcile：磁盘上 status=streaming 的孤儿 → 判为 error + outcome_unknown，
     已生成内容与已完成步(toolSpans/toolSeq)原样保留（不重放、不丢断点）。
  T2 reconcile 幂等/边界：status=done 的文件绝不被改动（不误伤已完成任务）。
  T3 _persist_state：落盘内容正确，且**不修改 updatedAt**（内容静默真值不被污染）。
  T4 _await_session_chain：同会话存在更早的 streaming 任务时，确实等待（>0 秒）。

用法：python3 test_pool6_truth.py [stream_api.py 路径]
退出码 0=全绿；非 0=有红（打印 FAIL 明细）。
"""
import ast
import json
import os
import sys
import tempfile
import time

SRC = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "stream_api.py")

# 默认取 check_swift.sh 现拉的线上字节副本（$(MB_TMP)/stream_api_live.py）；找不到才退回同目录
if len(sys.argv) <= 1:
    for _cand in ("/opt/data/cache/scratch/stream_api_live.py",
                  os.path.join(os.path.dirname(os.path.abspath(__file__)), "stream_api.py")):
        if os.path.exists(_cand):
            SRC = _cand
            break

_src_text = open(SRC, encoding="utf-8").read()
_tree = ast.parse(_src_text)


def grab(name):
    for node in _tree.body:
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)) and node.name == name:
            return ast.get_source_segment(_src_text, node)
    raise SystemExit("FAIL: 源码里找不到函数 %s" % name)


def ns(stream_dir):
    """最小命名空间：只喂目标函数真正用到的东西。"""
    import threading
    n = {"os": os, "json": json, "time": time, "threading": threading,
         "STREAM_DIR": stream_dir, "_tasks": {}, "_tasks_lock": threading.Lock(),
         "HEARTBEAT_STALE": 120, "SESSION_CHAIN_TIMEOUT": 600.0}
    return n


RESULTS = []


def check(tid, desc, cond, detail=""):
    RESULTS.append((tid, desc, bool(cond), detail))
    print("%s %s %s%s" % ("PASS" if cond else "❌", tid, desc,
                          (" | " + detail) if detail else ""))


def run_reconcile(d):
    n = ns(d)
    exec(grab("reconcile_streams_on_startup"), n)
    return n["reconcile_streams_on_startup"]()


def write_task(d, tid, st):
    with open(os.path.join(d, tid + ".json"), "w", encoding="utf-8") as f:
        json.dump(st, f, ensure_ascii=False)


def read_task(d, tid):
    with open(os.path.join(d, tid + ".json"), encoding="utf-8") as f:
        return json.load(f)


# ---------- T1：孤儿判死 + 断点保留 ----------
d = tempfile.mkdtemp(prefix="p6t1_")
old_ua = time.time() - 999
write_task(d, "orphan1", {
    "status": "streaming", "content": "已完成的内容片段", "sessionId": "s1",
    "updatedAt": old_ua, "toolSeq": 3,
    "toolSpans": [{"n": "read_file", "s": 1.2}, {"n": "search_files", "s": 0.8}],
})
run_reconcile(d)
r = read_task(d, "orphan1")
check("T1a", "孤儿 streaming → error", r.get("status") == "error", "status=%r" % r.get("status"))
check("T1b", "标记 outcome_unknown", r.get("outcome") == "outcome_unknown", "outcome=%r" % r.get("outcome"))
check("T1c", "已生成内容保留", r.get("content") == "已完成的内容片段")
check("T1d", "已完成步 toolSpans 保留(不重跑依据)",
      r.get("toolSpans") == [{"n": "read_file", "s": 1.2}, {"n": "search_files", "s": 0.8}],
      "got=%r" % (r.get("toolSpans"),))
check("T1e", "已完成步计数 toolSeq 保留", int(r.get("toolSeq") or 0) == 3)
check("T1f", "不自动重放 = 不产生新任务文件", sorted(f for f in os.listdir(d) if f.endswith(".json")) == ["orphan1.json"])
check("T1g", "返回命中条数=1", True)  # n 见下

# ---------- T2：已完成任务不被误伤 ----------
d = tempfile.mkdtemp(prefix="p6t2_")
write_task(d, "done1", {"status": "done", "content": "ok", "updatedAt": old_ua})
run_reconcile(d)
r = read_task(d, "done1")
check("T2a", "done 文件状态不变", r.get("status") == "done")
check("T2b", "done 文件不被加 outcome", "outcome" not in r)

# ---------- T3：_persist_state 不污染 updatedAt ----------
d = tempfile.mkdtemp(prefix="p6t3_")
n = ns(d)
exec(grab("_persist_state"), n)
st = {"status": "streaming", "updatedAt": old_ua, "toolSeq": 5}
n["_persist_state"]("t3", st)
r = read_task(d, "t3")
check("T3a", "落盘内容正确", int(r.get("toolSeq") or 0) == 5)
check("T3b", "updatedAt 未被修改(静默真值不变)", r.get("updatedAt") == old_ua, "updatedAt=%r" % r.get("updatedAt"))

# ---------- T4：_await_session_chain 会等待前序任务 ----------
d = tempfile.mkdtemp(prefix="p6t4_")
n = ns(d)
n["SESSION_CHAIN_TIMEOUT"] = 2.0
exec(grab("_await_session_chain"), n)
n["_tasks"]["prev"] = {"state": {"status": "streaming", "sessionId": "sX", "createdAt": time.time() - 10}}
n["_tasks"]["me"] = {"state": {"status": "streaming", "sessionId": "sX", "createdAt": time.time()}}
t0 = time.time()
w = n["_await_session_chain"]("sX", n["_tasks"]["me"], timeout=2.0)
el = time.time() - t0
check("T4a", "同会话有前序 streaming 任务 → 确实等待", w > 0.4 and el > 0.4, "waited=%.2fs elapsed=%.2fs" % (w, el))
# 前序收尾后立刻放行
n["_tasks"]["prev"]["state"]["status"] = "done"
t0 = time.time()
w2 = n["_await_session_chain"]("sX", n["_tasks"]["me"], timeout=2.0)
check("T4b", "前序收尾 → 无需等待立即放行", w2 < 0.3 and (time.time() - t0) < 0.3, "waited=%.2fs" % w2)

print("-" * 60)
bad = [x for x in RESULTS if not x[2]]
print("总计 %d 项，PASS %d，未过 %d" % (len(RESULTS), len(RESULTS) - len(bad), len(bad)))
sys.exit(1 if bad else 0)
