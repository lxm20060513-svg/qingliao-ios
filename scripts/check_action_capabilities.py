#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""v4.0.x AI 本地动作 / 能力扩容一致性护栏（check_swift.sh 第 37 段调用）。

为什么需要它：本轮把 5 类新能力（提醒事项/通讯录/定位/剪贴板/文件）接进来后，
"动作表" 这一个概念被复制到了 6 个地方，任何一处漏改都**不会**在本地报错：

  1. Core/AppPermissionKit.swift      AppCapability 枚举（权限页、闸门、展示名、图标）
  2. scripts/shims/AppCapabilityShim.swift  Linux 单测替身（不同步 → 单测假绿）
  3. Core/AgentAction.swift           Kind 的 rawValue / capability / impact / capabilityLabel
  4. Core/AgentActionExecutor*.swift  分派 switch（漏一个 = 运行期 "内部错误"）
  5. Features/Chat/AgentActionCard.swift  icon switch（漏一个 = CI archive 报 switch 不穷尽）
  6. scripts/test_agent_action.swift  分级真值表（漏一个 = 按错的分级执行，且全绿）
  7. project.yml                      权限串（漏一个 = 真机第一次用就 SIGABRT 闪退）
  8. 后端 QLACTION_PROMPT             模型只认得写进 prompt 的动作名（漏 = 模型永远不发这个动作）

第 8 条是跨仓的：后端 prompt 的**部署源副本**在 ../../scripts/ql_be_deploy/ 下，
本脚本在有副本时做一致性校验，没有（如 CI runner）就跳过并打印提示 —— 跳过要出声，
不能静默当通过。
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))       # iOS 仓根
BE_COPY = os.path.join(os.path.dirname(ROOT), 'scripts', 'ql_be_deploy', 'stream_api.qlaction.py')

# ── 真值表：能力（顺序即权限页展示顺序，**改动要连 AppPermissionKit 一起对齐**）
CAPS = ['calendar', 'reminders', 'photos', 'contacts', 'location',
        'clipboard', 'files', 'notifications', 'homekit']

# ── 真值表：19 个动作 → (影响分级, 归属能力, prompt 里给模型看的动作名)
#     prompt 名 = rawValue，唯一例外是 notify（后端一直写作 notify）
ACTIONS = [
    ('calendarCreate', 'calendar.create', 'write', 'calendar'),
    ('calendarUpdate', 'calendar.update', 'write', 'calendar'),
    ('calendarDelete', 'calendar.delete', 'delete', 'calendar'),
    ('calendarFree', 'calendar.free', 'read', 'calendar'),
    ('calendarToday', 'calendar.today', 'read', 'calendar'),
    ('reminderCreate', 'reminder.create', 'write', 'reminders'),
    ('reminderList', 'reminder.list', 'read', 'reminders'),
    ('reminderDelete', 'reminder.delete', 'delete', 'reminders'),
    ('photoSave', 'photo.save', 'write', 'photos'),
    ('photoDelete', 'photo.delete', 'delete', 'photos'),
    ('contactsSearch', 'contacts.search', 'read', 'contacts'),
    ('contactsCreate', 'contacts.create', 'write', 'contacts'),
    ('locationCurrent', 'location.current', 'read', 'location'),
    ('clipboardRead', 'clipboard.read', 'read', 'clipboard'),
    ('clipboardWrite', 'clipboard.write', 'write', 'clipboard'),
    ('fileList', 'file.list', 'read', 'files'),
    ('fileRead', 'file.read', 'read', 'files'),
    ('fileWrite', 'file.write', 'write', 'files'),
    ('notify', 'notify', 'write', 'notifications'),
]
ACT_NAMES = [a[1] for a in ACTIONS]

fails = []


def read(rel):
    p = os.path.join(ROOT, rel)
    if not os.path.exists(p):
        fails.append('缺少文件：%s' % rel)
        return ''
    return open(p, encoding='utf-8').read()


def check(name, cond, detail=''):
    if cond:
        print('✅ %s' % name)
    else:
        print('❌ %s %s' % (name, detail))
        fails.append(name)


# ── 1. AppCapability 枚举
kit = read('qingliao/Core/AppPermissionKit.swift')
m = re.search(r'enum AppCapability: String, CaseIterable[^{]*\{(.*?)\n\}', kit, re.S)
cases = re.findall(r'^\s*case\s+(\w+)\s*$', m.group(1), re.M) if m else []
check('AppCapability 九项齐全且顺序一致（权限页展示顺序）',
      cases == CAPS, '实际 %s' % cases)

# 每个能力都要有展示名 / 图标 / 说明（漏一个 → 权限页出现空行或编译错）
for label, pattern in (('displayName', r'var displayName: String \{(.*?)\n    \}'),
                       ('sfSymbol', r'var sfSymbol: String \{(.*?)\n    \}'),
                       ('blurb', r'var blurb: String \{(.*?)\n        \}')):
    mm = re.search(pattern, kit, re.S)
    body = mm.group(1) if mm else ''
    missing = [c for c in CAPS if ('case .%s:' % c) not in body]
    check('能力表 %s 覆盖全部九项' % label, not missing, '缺 %s' % missing)

# ── 2. shim 同步
shim = read('scripts/shims/AppCapabilityShim.swift')
sm = re.search(r'enum AppCapability: String, CaseIterable, Sendable \{(.*?)\n\}', shim, re.S)
scases = [c.strip() for c in (sm.group(1).split('case', 1)[-1].split('\n')[0].split(','))] if sm else []
scases = [c for c in scases if c and not c.startswith('//')]
check('shim（Linux 单测替身）与生产枚举逐字同步',
      scases == CAPS, 'shim=%s' % scases)

# ── 3. AgentAction.Kind 的 rawValue / capability / impact / label
act = read('qingliao/Core/AgentAction.swift')
raw = dict(re.findall(r'case\s+(\w+)\s*=\s*"([^"]+)"', act))
missing = [c for c, name, _, _ in ACTIONS if raw.get(c) != name]
check('AgentAction.swift 的 %d 个动作名与后端 prompt 口径一致' % len(ACTIONS),
      not missing, '不一致 %s' % missing)
extra = [v for k, v in raw.items() if v not in ACT_NAMES]
check('没有多余动作（多余 = 后端永远不会发，纯死码）', not extra, '多余 %s' % extra)

cap_block = re.search(r'var capability: AppCapability \{(.*?)\n        \}', act, re.S)
impact_block = re.search(r'var impact: Impact \{(.*?)\n        \}', act, re.S)
label_block = re.search(r'var capabilityLabel: String \{(.*?)\n            \}', act, re.S)
good, bad = [], []
for camel, name, impact, cap in ACTIONS:
    if cap_block and re.search(r'\.%s\b' % camel, cap_block.group(1)):
        found_cap = re.search(r'(?:case|,|\n)\s*\.%s\b[^;]*?return\s+\.(\w+)' % camel, cap_block.group(1))
        # 分支多为「case a, b, c: return .x」并列 → 该 case 所在分支的返回值
        seg = cap_block.group(1)
        idx = seg.find('.%s' % camel)
        tail = seg[idx:idx + 600]
        mm = re.search(r'return\s+\.(\w+)', tail)
        if mm and mm.group(1) == cap:
            good.append(camel)
        else:
            bad.append('%s 归属应为 %s（实际 %s）' % (camel, cap, mm.group(1) if mm else '?'))
    else:
        bad.append('%s 未在 capability switch 里出现' % camel)
check('每个动作的归属能力正确（放错能力 = 闸门查错对象）', not bad, '; '.join(bad))

if impact_block:
    seg = impact_block.group(1)
    bad = []
    for camel, name, impact, cap in ACTIONS:
        idx = seg.find('.%s' % camel)
        if idx < 0:
            bad.append('%s 未出现在 impact switch' % camel)
            continue
        mm = re.search(r'return\s+\.(\w+)', seg[idx:idx + 400])
        if not mm or mm.group(1) != impact:
            bad.append('%s 分级应为 %s（实际 %s）' % (camel, impact, mm.group(1) if mm else '?'))
    check('每个动作的影响分级正确（读=免确认自动跑 / 写=点一下 / 删=红色确认）', not bad, '; '.join(bad))

if label_block:
    lb = label_block.group(1)
    missing = [a[1] for a in ACTIONS if not re.search(r'\.%s:' % a[0], lb)]
    check('每个动作都有中文卡片标题', not missing, '缺 %s' % missing)

# ── 4. 分派：每个动作都要在 executor 里有落点
ex = read('qingliao/Core/AgentActionExecutor.swift') + read('qingliao/Core/AgentActionExecutorLocal.swift')
missing = [a[0] for a in ACTIONS if not re.search(r'\.%s\b' % a[0], ex)]
check('每个动作都在执行器里有落点（漏 = 运行期"内部错误"）', not missing, '缺 %s' % missing)
check('本地动作只由 runLocal 二级分派（不许出现第二个入口）',
      ex.count('static func runLocal(') == 1)

# ── 5. 卡片图标
card = read('qingliao/Features/Chat/AgentActionCard.swift')
icon_block = re.search(r'private var icon: String \{(.*?)\n    \}', card, re.S)
ib = icon_block.group(1) if icon_block else ''
missing = [a[0] for a in ACTIONS if not re.search(r'case \.%s:' % a[0], ib)]
check('动作卡图标覆盖全部动作（漏 = CI archive 报 switch 不穷尽）', not missing, '缺 %s' % missing)

# ── 6. 分级真值表（单测里的那张表）
test = read('scripts/test_agent_action.swift')
rows = dict((c, (imp, cap)) for c, imp, cap in
            re.findall(r'\(\.(\w+),\s*\.(\w+),\s*"(\w+)"\)', test))
bad = []
for camel, name, impact, cap in ACTIONS:
    if camel not in rows:
        bad.append('%s 不在分级表里' % camel)
    elif rows[camel] != (impact, cap):
        bad.append('%s 表里是 %s，应为 %s' % (camel, rows[camel], (impact, cap)))
check('单测分级表与真值表逐条一致', not bad, '; '.join(bad))

# ── 7. 权限串（缺 = 真机首次使用 SIGABRT）
proj = read('project.yml')
need = {
    'NSRemindersFullAccessUsageDescription': '提醒事项',
    'NSContactsUsageDescription': '通讯录',
    'NSLocationWhenInUseUsageDescription': '定位',
    'UIFileSharingEnabled': '文件 App 共享（用户要看得到 AI 写的文件）',
}
missing = ['%s(%s)' % (k, v) for k, v in need.items() if k not in proj]
check('project.yml 权限串齐全（缺 = 第一次用就闪退/看不到文件）', not missing, '缺 %s' % missing)
for k in need:
    mm = re.search(r'^%s:\s*(\S+)' % k, proj, re.M)
    if mm and not mm.group(1):
        fails.append('%s 值为空' % k)

# ── 8. 过期文案：源码里不许再出现「提醒事项没有接口」的错误说法
stale = []
for rel in ('qingliao/Core/AppPermissionKit.swift',
            'qingliao/Features/Settings/AppPermissionsSheet.swift'):
    src = read(rel)
    for line in src.split('\n'):
        if '提醒事项' in line and ('未开放' in line or '没有接口' in line or '无接口' in line):
            if '此前' in line or '已更正' in line or '错' in line:
                continue          # v4.0.x 的"更正说明"本身提到这句是允许的
            stale.append('%s: %s' % (rel, line.strip()[:60]))
check('源码里没有残留「提醒事项无接口」的过期文案', not stale, '; '.join(stale))

pagesrc = read('qingliao/Features/Settings/AppPermissionsSheet.swift')
check('权限页写明了「删除照片可在最近删除恢复」这条退路',
      '最近删除' in pagesrc)

# ── 9. 跨仓：后端 prompt 副本
if os.path.exists(BE_COPY):
    be = open(BE_COPY, encoding='utf-8').read()
    mm = re.search(r'QLACTION_PROMPT\s*=\s*\((.*?)\n\)', be, re.S)
    prompt = mm.group(1) if mm else ''
    check('后端 QLACTION_PROMPT 可定位', bool(prompt))
    missing = [n for n in ACT_NAMES if n != 'notify' and n not in prompt]
    check('后端 prompt 覆盖全部新动作（漏 = 模型永远不会发）',
          not missing, '缺 %s' % missing)
    for must, what in (('提醒事项', '提醒事项不再是"做不到"'),
                       ('通讯录', '通讯录'),
                       ('定位', '定位'),
                       ('剪贴板', '剪贴板'),
                       ('文件', '文件读写')):
        if must not in prompt:
            fails.append('后端 prompt 缺 %s 的能力说明' % what)
    if '提醒事项' in prompt and re.search(r'提醒事项[^。]{0,40}(没有任何公开接口|未提供|做不到)', prompt):
        fails.append('后端 prompt 仍写着"提醒事项做不到"（与 App 侧矛盾）')
    if all('后端 prompt 缺' not in f for f in fails):
        print('✅ 后端 prompt 五项新能力说明齐全')
else:
    print('⚠️ 跳过跨仓检查：未找到部署源副本（%s）—— CI runner 上属正常' % BE_COPY)

# ── 10. 测试用例的 JSON 换行转义（2026-09-27 实踩）
# Swift 多行字符串 """…""" 里写 \n 是**转义符**（真落成裸换行）→ JSON 里字符串值带裸换行 = 非法
# → JSONSerialization 解析失败 → parse 返回 nil → 三条断言假红（产品代码其实是对的）。
# 口径：JSON 里要换行必须写 \\n（文件里两个反斜杠 + n），断言侧比较值才写 \n（Swift 转义）。
t = read('scripts/test_agent_action.swift')
check('file.write 用例的 JSON 换行写成 \\\\n（JSON 转义形态）',
      '"content":"买牛奶\\\\n交房租"' in t)
check('断言侧比较值用 \\n（Swift 转义 = 真实换行）',
      'file?.param("content") == "买牛奶\\n交房租"' in t)

print('')
if fails:
    print('❌ 动作/能力一致性护栏失守 %d 处：' % len(fails))
    for f in fails:
        print('   · %s' % f)
    sys.exit(1)
print('✅ AI 动作 / 能力扩容护栏全绿（%d 动作 × %d 能力 × %d 个接线点）'
      % (len(ACTIONS), len(CAPS) - 1, 8))
