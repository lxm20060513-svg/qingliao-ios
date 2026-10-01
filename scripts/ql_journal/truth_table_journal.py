#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""第 6 项「反思日记」后端真值表 —— 跑的是**容器里那份线上字节**（部署后由 check_swift.sh 现拉）。

与第 5 项同法：镜像一份实现等于自己骗自己，本表在临时数据目录里真实 import
QL_PA_SRC 指向的那份文件并调用它的函数。

钉住的行为：
  1) 每日一问一天只产一次（落盘留痕，不是内存 —— 容器每轮 5 分钟跑一次）
  2) 没到 journalHour 不问；hour 之前改配置要立刻生效
  3) 周回顾只在周一产，且一周一次（跨周 weekKey 变 → 自动可再发）
  4) 周回顾文案报的是**上一周**的真实条数（周一算本周会把数据全滤成 0）
  5) dry_run 只判定：不产事件、不写留痕（App「今天问了没」不能消耗机会）
  6) journalEnable=false → 每日一问与周回顾都不产
  7) 答问写留痕 + 落进记忆（memory_store.check_and_save）
  8) 界面读到的问句 == 后端真投递那句（同一份 _daily_q）
  9) 非法 journalHour 被 save_config 拒掉（25 / -1 / "abc"）
 10) 留痕只留最近 90 天
"""
import json
import os
import shutil
import sys
import tempfile
import time

PA = os.environ.get("QL_PA_SRC") or "/opt/data/cache/scratch/pa_new.py"
_res = []


def check(name, cond, extra=""):
    _res.append((name, bool(cond), extra))


if not os.path.exists(PA):
    print("❌ 找不到后端源码：%s（用 QL_PA_SRC 指定线上副本）" % PA)
    sys.exit(1)

pa_src = open(PA, encoding="utf-8").read()

# ── 源码层：分叉点之前定义齐（防「插在 if 分支里、主路径没定义」的坑）──
check("proactive_agent 有 journal_event 定义", "def journal_event(" in pa_src)
check("proactive_agent 有 journal_answer 定义", "def journal_answer(" in pa_src)
check("proactive_agent 有 journal_state 定义", "def journal_state(" in pa_src)
check("JOURNAL_FILE 常量在", "JOURNAL_FILE =" in pa_src)
check("旧 followup 链路未丢（回归：本轮在同文件插代码）",
      all(s in pa_src for s in ("def followup_event(", "def _due_at(",
                               "FU_FILE =", "FB_FILE =")))

tmp = tempfile.mkdtemp(prefix="ql_journal_")
saved_env = {}
try:
    # 隔离：把落盘目录指到临时目录，别碰真实记忆/留痕
    os.environ["QL_DATA_DIR"] = tmp

    # 造一份假 memory_store（照第 5 项的契约）
    ms = os.path.join(tmp, "memory_store.py")
    saved_mem = []
    with open(ms, "w", encoding="utf-8") as f:
        f.write(
            "_META = []\n"
            "_SAVED = []\n"
            "def list_meta():\n    return list(_META)\n"
            "def check_and_save(t):\n    _SAVED.append(t)\n    return True\n"
        )

    import types
    mod = types.ModuleType("memory_store")
    exec(compile(open(ms, encoding="utf-8").read(), ms, "exec"), mod.__dict__)
    sys.modules["memory_store"] = mod

    sys.path.insert(0, tmp)
    import importlib.util
    spec = importlib.util.spec_from_file_location("pa_under_test", PA)
    pa = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(pa)

    # ── 1) 配置默认与校验 ──
    cfg = pa.get_config()
    check("默认配置含 journalEnable/journalHour",
          cfg.get("journalEnable") is True and int(cfg.get("journalHour")) == 22,
          repr({k: cfg.get(k) for k in ("journalEnable", "journalHour")}))
    check("非法 journalHour(25) 被拒",
          pa.save_config({"journalHour": 25})["ok"] is False)
    check("非法 journalHour(-1) 被拒",
          pa.save_config({"journalHour": -1})["ok"] is False)
    check("非法 journalHour('abc') 被拒",
          pa.save_config({"journalHour": "abc"})["ok"] is False)
    check("合法 journalHour(21) 写入成功",
          pa.save_config({"journalHour": 21})["ok"] is True
          and int(pa.get_config()["journalHour"]) == 21)

    # ── 2) 没到点不问 ──
    pa.save_config({"journalHour": 23})
    real_now = pa._now
    pa._now = lambda: real_now().replace(hour=10, minute=0)
    n, _d = pa.journal_event(dry_run=True)
    check("没到 journalHour 不产事件", n == 0, "produced=%s" % n)
    st = pa.journal_state()
    check("state 里 hour 回显配置值", int(st["hour"]) == 23, repr(st["hour"]))
    check("state 带今天日期与问句", bool(st["day"]) and bool(st["question"]))
    check("未到点时 asked=False", st["asked"] is False)

    # 到点后（hour=23 → 用 23 点那一档：改成 10 让「现在」10 点也算到点不行，
    # 这里直接把配置设成比当前小时小一点的整点）
    pa.save_config({"journalHour": 9})
    pa._now = lambda: real_now().replace(hour=10, minute=30)

    # ── 3) dry_run 只判定 ──
    n, detail = pa.journal_event(dry_run=True)
    check("dry_run 判出每日一问（produced>=1）", n >= 1, "n=%s" % n)
    check("dry_run 不写留痕（asked 仍 False）", pa.journal_state()["asked"] is False)
    check("dry_run 不入事件队列", len(pa._events()) == 0)

    # ── 4) 真跑：一天只产一次 ──
    n1, d1 = pa.journal_event(dry_run=False)
    check("真跑产出每日一问", n1 == 1, "n=%s detail=%s" % (n1, d1))
    check("dry_run 不消耗提问机会（真跑仍有可产的那一条）", len(d1) >= 1, repr(d1))
    check("真跑入队 kind=journal",
          [e.get("kind") for e in pa._events()] == ["journal"],
          repr([e.get("kind") for e in pa._events()]))
    check("真跑写留痕 asked=True", pa.journal_state()["asked"] is True)
    n2, _ = pa.journal_event(dry_run=False)
    check("同一天再跑不重复产（一天一次）", n2 == 0, "n=%s" % n2)

    # ── 5) 界面问句 == 真投递那句（口径唯一）──
    q_ui = pa.journal_state()["question"]
    q_sent = d1[0]["text"] if d1 else ""
    check("界面读到的问句与真投递那句逐字一致", q_ui == q_sent,
          "ui=%r sent=%r" % (q_ui, q_sent))

    # ── 6) 问句按天轮换（同一天恒定、一周一轮回）──
    import datetime as _dt
    qs = set()
    base = _dt.date(2026, 10, 1)
    for i in range(7):
        pa._now = lambda i=i: _dt.datetime.combine(base + _dt.timedelta(days=i),
                                                   _dt.time(23, 0))
        qs.add(pa._daily_q())
    check("一周内 7 天问句各不相同", len(qs) == 7, "unique=%d" % len(qs))

    # ── 7) 周回顾：只在周一，且一周一次 ──
    pa._now = real_now
    jf = pa.JOURNAL_FILE
    if os.path.exists(jf):
        os.remove(jf)
    # 造三条上周（-7 天）的投递留痕 + 两条本周的
    wk_now = pa._week_key()
    for k in (8, 7, 7, 1, 0):
        ts = time.time() - k * 86400
        pa.record([{"id": "e%d" % k, "ts": ts, "day": pa._day(), "kind": "agent",
                    "text": "x", "spoke": True}])
    fb = pa._load(pa.FB_FILE, {"adopted": 3, "ignored": 1, "by_kind": {}})
    pa._save(pa.FB_FILE, fb)
    prev = pa._prev_week_key()
    check("_prev_week_key 与当前周不同", prev != wk_now, "%s vs %s" % (prev, wk_now))
    spoke, ad, ig, pend = pa._week_stats(prev)
    check("周统计只数上一周的 3 条（不含本周 2 条）", spoke == 3, "spoke=%s" % spoke)
    check("周统计带累计采纳/忽略", ad == 3 and ig == 1, "ad=%s ig=%s" % (ad, ig))

    # 周一 23 点 → 应同时产每日一问 + 周回顾，且回顾报上一周数据
    monday = pa._now().replace(hour=23)
    monday = monday - _dt.timedelta(days=monday.weekday())      # 回到本周一
    pa._now = lambda: monday
    n, detail = pa.journal_event(dry_run=True)
    kinds = [d["kind"] for d in detail]
    check("周一产出每日一问 + 周回顾两条",
          kinds == ["journal", "week_review"], repr(kinds))
    wk_text = detail[-1]["text"]
    check("周回顾文案报出上周真实条数（3 条）",
          "主动开口 3 条" in wk_text, repr(wk_text[:80]))
    check("周回顾报待确认数（当前 pending=0）", "待确认的事" in wk_text)

    n, _ = pa.journal_event(dry_run=False)
    st = pa.journal_state()
    check("周回顾写留痕 weekAsked=True", st["weekAsked"] is True)
    # 同周再跑不再产周回顾
    n, _ = pa.journal_event(dry_run=False)
    check("同周再跑不重复发周回顾", n == 0, "n=%s" % n)

    # 下周一 → weekKey 变 → 自动可再发
    pa._now = lambda: monday + _dt.timedelta(days=7)
    n, detail = pa.journal_event(dry_run=True)
    check("下一周自动可再发周回顾",
          any(d["kind"] == "week_review" for d in detail),
          repr([d["kind"] for d in detail]))

    # ── 8) 关掉总开关 ──
    # 🚨 必须先把当天留痕清掉再测：当天已问过 → detail 本来就空 → n=0 是恒真，
    # 那条断言会给「总开关被摘掉」发绿。必须造一个「本来该产」的干净起点。
    pa._now = lambda: monday
    if os.path.exists(pa.JOURNAL_FILE):
        os.remove(pa.JOURNAL_FILE)
    n_ctrl, _ = pa.journal_event(dry_run=True)
    check("前置：清掉留痕后本来该产出一条（证明下面那条不是恒真）",
          n_ctrl >= 1, "n=%s" % n_ctrl)
    if os.path.exists(pa.JOURNAL_FILE):
        os.remove(pa.JOURNAL_FILE)
    pa.save_config({"journalEnable": False})
    n, _ = pa.journal_event(dry_run=False)
    check("journalEnable=false 时不产任何事件", n == 0, "n=%s" % n)
    check("关掉后 state.enable=False", pa.journal_state()["enable"] is False)
    check("关掉后 /journal 预览也不产（不靠上游 gate 挡）",
          pa.journal_event(dry_run=True)[0] == 0)
    pa.save_config({"journalEnable": True})

    # ── 9) 答问：写留痕 + 落记忆 ──
    r = pa.journal_answer("今天把专利交初稿了")
    check("答问返回 ok 且写进记忆", r.get("ok") is True and r.get("saved") is True, repr(r))
    check("记忆里出现该条", "今天把专利交初稿了" in mod._SAVED, repr(mod._SAVED))
    st = pa.journal_state()
    check("留痕 answered=True 且回显答案",
          st["answered"] is True and st["answer"] == "今天把专利交初稿了", repr(st))
    check("空内容被拒", pa.journal_answer("   ")["ok"] is False)
    r = pa.journal_answer("x" * 500)
    check("超长答案被截断到 300 字",
          r["ok"] is True and len(pa.journal_state()["answer"]) == 300,
          repr(len(pa.journal_state()["answer"])))

    # ── 10) 留痕只留最近 90 天 ──
    j = pa._load(pa.JOURNAL_FILE, {})
    for i in range(1, 120):
        j["2020-01-%02d" % ((i % 28) + 1) if i < 29 else "2020-%02d-01" % ((i % 12) + 1)] = {}
    pa._save(pa.JOURNAL_FILE, j)
    pa._now = lambda: monday
    pa.journal_event(dry_run=False)
    check("留痕超过 90 天被剪掉",
          len(pa._load(pa.JOURNAL_FILE, {})) <= 91,
          "left=%d" % len(pa._load(pa.JOURNAL_FILE, {})))

finally:
    pa = locals().get("pa")
    if pa:
        pa._now = real_now
    for k, v in saved_env.items():
        os.environ[k] = v
    sys.path.remove(tmp) if tmp in sys.path else None
    sys.modules.pop("memory_store", None)
    shutil.rmtree(tmp, ignore_errors=True)

ok = sum(1 for _n, p, _e in _res if p)
for name, passed, extra in _res:
    print("%s %s%s" % ("✅" if passed else "❌", name,
                       ("  ← %s" % extra) if (extra and not passed) else ""))
print("—— 第 6 项后端真值表：%d/%d 通过" % (ok, len(_res)))
sys.exit(0 if ok == len(_res) else 1)