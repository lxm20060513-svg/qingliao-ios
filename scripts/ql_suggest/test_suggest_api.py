# -*- coding: utf-8 -*-
"""suggest_api 纯逻辑真值表（不触网）：_normalize / _parse_questions / _key / _is_question。

设计要点（对齐 App 侧口径）：
  · 质量闸门宁缺勿滥：去重后 < MIN_Q 条 ⇒ 空数组（空数组是合法成功）
  · 与 exclude 有交集的丢弃
  · 非问句丢弃
  · 超长截断但保留句末问号
"""
import sys, os, json, re

REPO = "/opt/data/ql_backend_repo/backend"
sys.path.insert(0, REPO)
import suggest_api as S

PASS = FAIL = 0
FAILS = []


def ck(name, got, want):
    global PASS, FAIL
    if got == want:
        PASS += 1
    else:
        FAIL += 1
        FAILS.append(f"{name}\n     期望={want!r}\n     实得={got!r}")


# ---------- _key / _is_question ----------
ck("key 去句末标点", S._key("今天吃什么？"), "今天吃什么")
ck("key 去半角问号+空白", S._key("  今天吃什么?  "), "今天吃什么")
ck("key 空串", S._key(""), "")
ck("key None", S._key(None), "")
ck("疑问词判定-问号", S._is_question("今天吃什么？"), True)
ck("疑问词判定-半角问号", S._is_question("吃什么呢?"), True)
ck("疑问词判定-无问号但有词", S._is_question("该吃火锅吗"), True)
ck("疑问词判定-陈述句", S._is_question("今天天气不错"), False)
ck("疑问词判定-数字不算", S._is_question("买3个"), False)

# ---------- _normalize 正常路径 ----------
ck("正常三条去重截断", S._normalize(
    ["今天吃什么？", "附近有什么好吃的？", "要不要点外卖？", "第四个？"]),
    ["今天吃什么？", "附近有什么好吃的？", "要不要点外卖？"])
ck("超过 MAX_Q 截断到 3", len(S._normalize(["a%d？" % i for i in range(6)])), S.MAX_Q)
ck("非问句丢弃", S._normalize(["今天天气不错", "那吃什么呢？"]), ["那吃什么呢？"])
ck("与 exclude 交集丢弃", S._normalize(
    ["今天吃什么？", "晚上吃火锅？"], exclude=["今天吃什么"]), ["晚上吃火锅？"])
ck("exclude 归一化后仍命中", S._normalize(
    ["今天吃什么？"], exclude=["今天吃什么？"]), [])
ck("批内自重复只留一条", S._normalize(["吃火锅吗？", "吃火锅吗", "吃火锅吗?"]), ["吃火锅吗？"])
ck("超长截断且留问号", S._normalize(["一二三四五六七八九十" * 6 + "？"])[0].endswith("？"), True)
ck("超长截断到上限内", len(S._normalize(["一二三四五六七八九十" * 6 + "？"])[0]) <= S.MAX_Q_LEN + 1, True)
ck("空输入", S._normalize([]), [])
ck("None 输入", S._normalize(None), [])
ck("非字符串丢弃", S._normalize([None, 123, {"a": 1}, "吃什么呢？"]), ["吃什么呢？"])
ck("全是非问句 → 空", S._normalize(["天气不错", "股票涨了"]), [])

# ---------- 质量闸门 ----------
def _gate(items, exclude=None):
    qs = S._normalize(items, exclude)
    return qs if len(qs) >= S.MIN_Q else []


ck("闸门：只剩 1 条 → 空数组", _gate(["今天吃什么？"]), [])
ck("闸门：正好 2 条 → 保留", _gate(["今天吃什么？", "晚上吃火锅？"]),
   ["今天吃什么？", "晚上吃火锅？"])
ck("闸门：模型返空 → 空数组", _gate([]), [])
ck("闸门：全是垃圾 → 空数组", _gate(["好的", "嗯嗯"]), [])

# ---------- _parse_questions ----------
ck("parse 纯数组", S._parse_questions('["a？","b？"]'), ["a？", "b？"])
ck("parse 裸数组", S._parse_questions('  ["a？"] '), ["a？"])
ck("parse dict/questions", S._parse_questions('{"questions":["a？"]}'), ["a？"])
ck("parse dict/items", S._parse_questions('{"items":["a？"]}'), ["a？"])
ck("parse 带前缀散文 + 数组", S._parse_questions('好的：\n["a？","b？"]\n以上'), ["a？", "b？"])
ck("parse 无数组 → 空", S._parse_questions("我不知道"), [])
ck("parse 空串 → 空", S._parse_questions(""), [])
ck("parse 坏 JSON + 无数组 → 空", S._parse_questions("{oops"), [])
ck("parse 数字数组（类型不符）", S._parse_questions("[1,2]"), [1, 2])

# ---------- prompt 形态（源级） ----------
src = open(os.path.join(REPO, "suggest_api.py"), encoding="utf-8").read()
ck("prompt 要求纯 JSON 数组", "只输出 JSON 数组" in src, True)
ck("prompt 带 exclude", "{ex}" in src, True)
ck("prompt 禁无信息量问题", "无信息量" in src, True)
ck("prompt 传 max_tokens", '"max_tokens": 500' in src, True)
_body_blk = src[src.index("body = {"):src.index("resp = stream_api._chat_once")]
ck("body 字面量禁带 model_options（实测触发 400）", "model_options" not in _body_blk, True)
ck("body 只有 4 个键", sorted(set(re.findall(r'"(model|messages|stream|max_tokens|model_options)":', _body_blk))),
   ["max_tokens", "messages", "model", "stream"])
ck("判网关 failed 状态", 'resp.get("hermes") or {}).get("failed")' in src, True)
ck("拒网关错误文案进 content", '"custom rejected"' in src, True)
ck("复用 _chat_once（禁新增流协议）", "stream_api._chat_once(body)" in src, True)
ck("不新增第二套上游调用件", src.count("def build_questions"), 1)
ck("异常吞成空数组", "except Exception:\n        return []" in src, True)
ck("门控常量 MIN_Q=2", S.MIN_Q, 2)
ck("门控常量 MAX_Q=3", S.MAX_Q, 3)

# ---------- 端点注册（源级真值） ----------
ag = open(os.path.join(REPO, "agent_api.py"), encoding="utf-8").read()
ck("端点挂在 /api/agent 前缀下", 'startswith("/api/agent/suggest_questions")' in ag, True)
ck("端点在 /api/agent/suggest 之前（长前缀优先）",
   ag.index('startswith("/api/agent/suggest_questions")') < ag.index('startswith("/api/agent/suggest"'), True)
ck("端点走鉴权", "if not self._auth():" in ag, True)
ck("端点失败也返 200", 'self._send(200, {"ok": False, "questions": []' in ag, True)
ck("端点传 batch", 'd.get("batch")' in ag, True)

# ROUTE_TABLE 前缀注册（决定 nginx 可达性）
rr = open(os.path.join(REPO, "unified_router.py"), encoding="utf-8").read()
ck("ROUTE_TABLE 已注册 /api/agent", '"/api/agent"' in rr, True)

print(f"\n建议池① 提问推荐·后端纯逻辑：{PASS} 通过 / {FAIL} 失败")
if FAILS:
    print("\n失败明细：")
    for f in FAILS:
        print("  ✗ " + f)
    sys.exit(1)
print("🎉 全绿")