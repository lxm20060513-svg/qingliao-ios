#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""第 5 项「主动跟进闭环」后端真值表 —— 跑的是**容器里那份线上字节**。

为什么真值表在 Python 而不是 Swift：本项的后端判定（到期判定 / 次数上限 / 剪枝 /
勾销回写）全在 proactive_agent.py + memory_api.py 里，纯逻辑、可在本机直接 import 执行。
镜像一份实现等于自己骗自己，所以本表把 NAS 上真文件拉下来（QL_PA_SRC / QL_MAPI_SRC，
默认指向 /opt/data/cache/scratch 下由 ql.py nas read 拉取的**线上副本**），
在一个临时数据目录里真实调用它的函数并断言行为。

钉住的行为：
  1) 判定池 = memory_store 里 status=pending 的条目（active/stale 不进池）
  2) 未到期（updated 太新）不产事件；到期（老于 followupAfterHours）产
  3) 最多问 FOLLOWUP_MAX_ROUNDS 遍就闭嘴（防同一条被永久追问）
  4) dry_run 只判定：产事件数 > 0 但**不**加 asked 计数、**不**落盘、**不**入事件队列
  5) 剪枝：条目已不在 pending 池 → 它的留痕被清掉（否则同名条目重生会继承上一世计数）
  6) 勾销回写：状态离开 pending / 删除 / 改正文 → clear_followup 被调到
  7) 非法 followupAfterHours 被 save_config 拒掉（0 会被静默兜成 1）
  8) followupEnable=false 时整条链路不产事件
"""
import json
import os
import shutil
import sys
import tempfile
import time

PA = os.environ.get("QL_PA_SRC") or "/opt/data/cache/scratch/pa_live.py"
MAPI = os.environ.get("QL_MAPI_SRC") or "/opt/data/cache/scratch/mapi_live.py"

_res = []


def check(name, cond, extra=""):
    _res.append((name, bool(cond), extra))


for p in (PA, MAPI):
    if not os.path.exists(p):
        print("❌ 找不到后端源码：%s（用 QL_PA_SRC 指定线上副本）" % p)
        sys.exit(1)

pa_src = open(PA, encoding="utf-8").read()
mapi_src = open(MAPI, encoding="utf-8").read()

# ── 源码层：两个文件都还在（防有人删了分支只留注释）──
check("proactive_agent 有 followup_event 定义",
      "def followup_event(" in pa_src)
check("proactive_agent 有 clear_followup 定义",
      "def clear_followup(" in pa_src)
check("proactive_agent 有 FU_FILE 常量", "FU_FILE =" in pa_src)
check("memory_api 有 _clear_followup 定义",
      "def _clear_followup(" in mapi_src)
check("记忆文件 _FEEDBACK 常量未被误删（回归：上一轮插 FU_FILE 时差点写掉 FB_FILE）",
      "FB_FILE =" in pa_src and "_feedback()" in pa_src)

# ── 行为层：真 import 线上副本 ──
tmp = tempfile.mkdtemp(prefix="ql_followup_")
try:
    # 造一份假的 memory_store（第 4 项的契约：list_meta 返回 dict 列表）
    ms_path = os.path.join(tmp, "memory_store.py")
    with open(ms_path, "w", encoding="utf-8") as f:
        f.write("""
import json, os
P = os.environ["QL_MEM_FAKE"]
def list_meta():
    with open(P, encoding="utf-8") as fh:
        return json.load(fh)
def list_entries():
    return [r.get("text", "") for r in list_meta()]
def set_meta(text, status=None, **kw):
    rows = list_meta()
    for r in rows:
        if r.get("text") == text:
            if status is not None:
                r["status"] = status
            with open(P, "w", encoding="utf-8") as fh:
                json.dump(rows, fh)
            return True
    return False
def delete_entry(text):
    rows = [r for r in list_meta() if r.get("text") != text]
    with open(P, "w", encoding="utf-8") as fh:
        json.dump(rows, fh)
    return True
def update_entry(old, new):
    rows = list_meta()
    hit = False
    for r in rows:
        if r.get("text") == old:
            r["text"] = new
            hit = True
    with open(P, "w", encoding="utf-8") as fh:
        json.dump(rows, fh)
    return hit
""")

    os.environ["QL_DATA_DIR"] = tmp
    os.environ["QL_MEM_FAKE"] = os.path.join(tmp, "memory.json")

    old_ts = time.time() - 30 * 3600      # 30 小时前 → 到期
    fresh_ts = time.time() - 60           # 1 分钟前 → 未到期
    rows = [
        {"text": "交年度预算表", "status": "pending", "updated": old_ts, "created": old_ts},
        {"text": "刚标的事", "status": "pending", "updated": fresh_ts, "created": fresh_ts},
        {"text": "生效中的偏好", "status": "active", "updated": old_ts, "created": old_ts},
        {"text": "过时的事", "status": "stale", "updated": old_ts, "created": old_ts},
    ]

    def dump(r):
        with open(os.environ["QL_MEM_FAKE"], "w", encoding="utf-8") as f:
            json.dump(r, f)

    dump(rows)
    # 把线上副本当模块装进临时目录：模块名必须叫 proactive_agent（import 按名找，不按文件名），
    # 所以复制一份进去而不是直接 add sys.path —— 后者只能 import 到 pa_live 这个名字。
    import shutil as _sh
    _sh.copyfile(PA, os.path.join(tmp, "proactive_agent.py"))
    sys.path.insert(0, tmp)
    import proactive_agent as pa
    check("线上副本以 proactive_agent 载入（真跑而非镜像实现）",
          os.path.abspath(pa.__file__) == os.path.join(tmp, "proactive_agent.py"),
          str(getattr(pa, "__file__", "?")))

    # 配置默认值：followupEnable 开、20h
    with open(pa.CFG_FILE, "w", encoding="utf-8") as f:
        json.dump({"enabled": True, "dailyMax": 6, "quietStart": 23, "quietEnd": 7,
                   "minScore": 0.55, "followupEnable": True,
                   "followupAfterHours": 20}, f)

    # 1) 判定池只含 pending
    pool = [r["text"] for r in pa._pending_rows()]
    check("判定池只含 status=pending",
          pool == ["交年度预算表", "刚标的事"], str(pool))

    # 2) 未到期不产、到期才产（真跑，非 dry_run）
    n, detail = pa.followup_event()
    texts = [d["text"] for d in (detail or [])]
    check("只对到期的 pending 产事件（active/stale/未到期都不产）",
          n == 1 and texts == ["交年度预算表"], "n=%d %s" % (n, texts))
    evs = pa._events()
    check("追问事件真的入队且 kind=followup",
          len(evs) == 1 and evs[0].get("kind") == "followup"
          and "交年度预算表" in evs[0].get("text", ""), str(evs)[:200])
    check("asked 计数已落盘",
          pa._followups().get("交年度预算表", {}).get("asked") == 1,
          str(pa._followups()))

    # 3) 次数上限：连跑到上限后闭嘴
    for _ in range(5):
        pa._save(pa.EVT_FILE, [])
        pa.followup_event()
    check("同一条最多问 %d 遍就闭嘴" % pa.FOLLOWUP_MAX_ROUNDS,
          pa._followups().get("交年度预算表", {}).get("asked") == pa.FOLLOWUP_MAX_ROUNDS,
          str(pa._followups()))

    # 4) dry_run 只判定：不加计数、不入队、不落盘
    before_asked = pa._followups().get("交年度预算表", {}).get("asked")
    pa._save(pa.EVT_FILE, [])
    # 把「刚标的事」改成到期，让 dry_run 有东西可判
    rows[1]["updated"] = old_ts
    dump(rows)
    n2, d2 = pa.followup_event(dry_run=True)
    check("dry_run 能看到到期条目", n2 >= 1 and any(
        d["text"] == "刚标的事" for d in (d2 or [])), "n2=%d" % n2)
    check("dry_run 不消耗 asked 计数",
          pa._followups().get("交年度预算表", {}).get("asked") == before_asked
          and pa._followups().get("刚标的事") is None,
          str(pa._followups()))
    check("dry_run 不入事件队列", pa._events() == [], str(pa._events()))

    # 5) 剪枝：条目离开 pending → 留痕被清
    rows[0]["status"] = "active"
    dump(rows)
    pa.followup_event()
    check("条目改回 active 后它的追问留痕被剪掉（同名条目重生不会继承上一世计数）",
          "交年度预算表" not in pa._followups(), str(pa._followups()))

    # 6) clear_followup：勾销回写
    # 🚨 断言必须夹在两次 clear_followup **之间**（下面收尾还要再清一次做现场复原）。
    #    写成「先清两次、再断言」＝ 断言读的是自己刚清空的表，红的是表不是代码。
    pa._save(pa.EVT_FILE, [])
    pa.clear_followup("刚标的事")
    check("clear_followup 清掉留痕",
          "刚标的事" not in pa._followups(), str(pa._followups()))
    n3, d3 = pa.followup_event()
    check("清留痕后重新到期可再问（计数从头算，不继承上一世）",
          pa._followups().get("刚标的事", {}).get("asked") == 1,
          "n3=%s fu=%s" % (n3, pa._followups()))
    pa.clear_followup("刚标的事")
    pa._save(pa.EVT_FILE, [])

    # 7) followupEnable=false → 不产
    pa.save_config({"followupEnable": False})
    rows[1]["updated"] = old_ts
    dump(rows)
    pa._save(pa.EVT_FILE, [])
    n4, d4 = pa.followup_event()
    check("followupEnable=false 时不产事件", n4 == 0, "n4=%d" % n4)
    pa.save_config({"followupEnable": True})

    # 8) 非法 followupAfterHours 被拒
    r0 = pa.save_config({"followupAfterHours": 0})
    check("followupAfterHours=0 被拒（否则会被静默兜成 1，界面还显示 0）",
          r0.get("ok") is False, str(r0))
    r1 = pa.save_config({"followupAfterHours": "abc"})
    check("followupAfterHours 非整数被拒", r1.get("ok") is False, str(r1))
    r2 = pa.save_config({"followupAfterHours": 20})
    check("followupAfterHours=20 被接受", r2.get("ok") is True, str(r2))
    check("followupEnable 默认开",
          pa.DEFAULT_CFG.get("followupEnable") is True)
    check("followupAfterHours 默认 20h",
          pa.DEFAULT_CFG.get("followupAfterHours") == 20)

    # 9) state 的 followup 段：due 必须**后端算好下发**，前端不重写到期规则
    rows[1]["updated"] = old_ts
    dump(rows)
    pa.save_config({"followupAfterHours": 20, "followupEnable": True})
    st_fu = pa._state()["followup"]
    check("state.followup 含 pending/asked/afterHours/maxRounds",
          all(k in st_fu for k in ("pending", "asked", "afterHours", "maxRounds")),
          str(sorted(st_fu.keys())))
    pm = {r["text"]: r for r in st_fu["pending"]}
    # 🚨 dueAt 是**到期时刻**（绝对戳），所以已过期条目的 dueAt 必然在**过去**，
    #    不是「未来附近」。这里钉的是它等于 updated+after，而不是和 now 比大小。
    check("到期条目 due=True 且 dueAt = 标记时刻 + 阈值（10 小时前）",
          pm["刚标的事"]["due"] is True
          and abs(pm["刚标的事"]["dueAt"] - (old_ts + 20 * 3600)) <= 2,
          str(pm.get("刚标的事")))
    rows[1]["updated"] = fresh_ts
    dump(rows)
    pm2 = {r["text"]: r for r in pa._state()["followup"]["pending"]}
    check("未到期条目 due=False（界面不会误报「已到点」）",
          pm2["刚标的事"]["due"] is False, str(pm2.get("刚标的事")))
    check("pending 段不带 asked 以外的注入内容（只回正文/计数/到期）",
          all(set(r.keys()) <= {"text", "asked", "dueAt", "due"}
              for r in pa._state()["followup"]["pending"]),
          str([sorted(r.keys()) for r in pa._state()["followup"]["pending"]]))
    # 与 followup_event 共用同一口径：界面说 due=True 的，dry_run 必须真的判它到期
    d_run = {d["text"] for d in (pa.followup_event(dry_run=True)[1] or [])}
    check("界面 due 与实际到期判定同源（界面说到点就一定被判到期）",
          all(t in d_run for t, r in pm2.items() if r["due"] is True
              and r["asked"] < pa.FOLLOWUP_MAX_ROUNDS),
          "due=%s dry=%s" % ([t for t, r in pm2.items() if r["due"]], sorted(d_run)))
    # 无时间戳的条目：不谎报已到点
    pa.clear_followup("刚标的事")
    rows.append({"text": "无戳条目", "status": "pending"})
    dump(rows)
    pm3 = {r["text"]: r for r in pa._state()["followup"]["pending"]}
    check("没时间戳的条目不谎报已到点（due=False, dueAt=0）",
          pm3["无戳条目"]["due"] is False and pm3["无戳条目"]["dueAt"] == 0,
          str(pm3.get("无戳条目")))
    rows = [r for r in rows if r["text"] != "无戳条目"]
    dump(rows)
    pa._save(pa.EVT_FILE, [])

    # 9b) 已问满上限的条目：仍列出来，但不许显示「已到点」
    rows.append({"text": "问够了的事", "status": "pending",
                 "updated": old_ts, "created": old_ts})
    dump(rows)
    with pa._lock:
        fu = pa._followups()
        fu["问够了的事"] = {"asked": pa.FOLLOWUP_MAX_ROUNDS, "lastTs": time.time()}
        pa._save(pa.FU_FILE, fu)
    pm4 = {r["text"]: r for r in pa._state()["followup"]["pending"]}
    check("已问满上限的条目仍列出（用户看得见它为什么不问了）",
          "问够了的事" in pm4, str(sorted(pm4)))
    check("已问满上限的条目 due=False（界面不能骗用户说会主动问）",
          pm4.get("问够了的事", {}).get("due") is False
          and pm4.get("问够了的事", {}).get("asked") == pa.FOLLOWUP_MAX_ROUNDS,
          str(pm4.get("问够了的事")))
    pa.clear_followup("问够了的事")
    rows = [r for r in rows if r["text"] != "问够了的事"]
    dump(rows)

    # 9c) 到期口径**必须**是同一个函数：真投递和界面显示各自算一遍 = 早晚不一致
    check("真投递与界面显示共用同一个到期口径函数 _due_at",
          "_due_at(r, after)" in pa_src
          and "_pending_with_due" in pa_src
          and pa_src.count("now - ts < after * 3600") == 0
          and pa_src.count("_due_at(") >= 3,
          "count(_due_at)=%d 旧口径残留=%d"
          % (pa_src.count("_due_at("), pa_src.count("now - ts < after * 3600")))

    # 10) memory_api 三处回写点都在（源码级：勾销/删除/改正文）
    check("状态端点离开 pending 时清留痕",
          "if ok and st != \"pending\":" in mapi_src)
    check("删除端点清留痕",
          "self._clear_followup(text if ok else \"\")" in mapi_src)
    check("改正文端点清新旧两条留痕",
          "self._clear_followup(old, new)" in mapi_src)
    check("清理失败不会带崩记忆页（proactive_agent 是可选模块）",
          "import proactive_agent\n        except Exception:\n            return" in mapi_src)

finally:
    shutil.rmtree(tmp, ignore_errors=True)

# ── 输出 ──
ok = sum(1 for _n, p, _e in _res if p)
for name, passed, extra in _res:
    print("%s %s%s" % ("✅" if passed else "❌", name,
                       ("  ← %s" % extra) if (extra and not passed) else ""))
print("—— 第 5 项后端真值表：%d/%d 通过" % (ok, len(_res)))
sys.exit(0 if ok == len(_res) else 1)
