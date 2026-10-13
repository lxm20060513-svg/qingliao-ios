#!/usr/bin/env python3
"""#24 技能库 · 护栏变异验证驱动。

证明「改坏必红」：对每条护栏做一次定向破坏，断言对应护栏**真的变红**，再还原并比对 md5。

铁律（与仓内口径一致）：
  · 还原只许 `cp <file> <file>.bak` → 改 → 跑 → `mv <file>.bak <file>` → 比 md5（**绝不 git checkout/restore/stash**）。
  · 变异前**先断言锚点命中 == 1**（锚点漂移就报红停下，不盲改）。
  · **拒绝写空文件**（置换后内容必须非空且 != 原文）。
  · 每次还原后**再跑一次**护栏，必须恢复全绿（否则是「还原没生效」伪装成通过）。

用法：python3 scripts/ql_skills/mutate_check.py   （cwd 任意，脚本自定位仓库根）
"""
import hashlib
import os
import subprocess
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
SW = "/opt/data/swift-toolchain/swift-6.0.3-RELEASE-ubuntu24.04/usr/bin"
ENV = dict(os.environ, HOME="/opt/data/home", TZ="Asia/Shanghai",
           LD_LIBRARY_PATH="/opt/data/swift-libs:" + SW + "/../lib/swift/linux")
ENV.pop("QL_REPO", None)   # 会话里可能有陈旧的 QL_REPO，清掉让真值表走 cwd

TT_GUARD = ["/tmp/tt_skills"]   # 源级真值表（读文件，运行期即当前内容）
TEST_GUARD = [SW + "/swiftc", "-swift-version", "6", "-parse-as-library",
              "-o", "/tmp/test_skills_mut",
              "qingliao/Core/SkillsClient.swift", "scripts/ql_skills/test_skills.swift"]


def md5(path):
    with open(path, "rb") as f:
        return hashlib.md5(f.read()).hexdigest()


def run(cmd):
    return subprocess.run(cmd, cwd=ROOT, env=ENV, capture_output=True, text=True)


def guard_red(name):
    """返回 (is_red, tail)：护栏在这次破坏后是否变红。"""
    if name == "tt":
        r = run(TT_GUARD)
        return (r.returncode != 0 or "❌" in r.stdout), r.stdout
    r = run(TEST_GUARD)
    if r.returncode != 0:
        return True, (r.stdout + r.stderr)   # 编译失败也算红（改坏编译不通过）
    r2 = run(["/tmp/test_skills_mut"])
    return (r2.returncode != 0 or "❌" in r2.stdout), r2.stdout


# (说明, 文件, 锚点, 置换, 护栏)
MUTATIONS = [
    ("端点改裸 /api/skills（蜂窝白名单会整片死）",
     "qingliao/Core/SkillsClient.swift",
     'static let basePath = "/api/agent/skills"',
     'static let basePath = "/api/skills"', "tt"),
    ("Sheet 不再走现成封装（自拼请求）",
     "qingliao/Features/Settings/SkillsLibrarySheet.swift",
     "auth.request(method: method, path: path, body: body)",
     "legacyFetch(method: method, path: path, body: body)", "tt"),
    ("name 校验放宽到 99 位",
     "qingliao/Core/SkillsClient.swift",
     "(2...48).contains(n.count)",
     "(2...99).contains(n.count)", "test"),
    ("列表 ok:false 不再抛错（把后端错误当成功）",
     "qingliao/Core/SkillsClient.swift",
     'guard env.ok else { throw SkillsError.backend(env.error ?? "") }\n        return env.skills ?? []',
     'return env.skills ?? []', "test"),
    ("删掉 openSearchEntry 的 skillsLibrary 分支",
     "qingliao/Features/Settings/SettingsCore.swift",
     'case "skillsLibrary": showSkillsLibrary = true\n',
     '', "tt"),
]

fails = 0
for desc, rel, anchor, repl, guard in MUTATIONS:
    path = os.path.join(ROOT, rel)
    orig = open(path, encoding="utf-8").read()
    n = orig.count(anchor)
    print("=" * 72)
    if n != 1:
        print(f"❌ 锚点命中 {n} 次（应为 1）：{desc}  → {rel}")
        fails += 1
        continue
    before = md5(path)
    bak = path + ".bak"
    subprocess.run(["cp", path, bak], cwd=ROOT, check=True)
    mutated = orig.replace(anchor, repl, 1)
    if not mutated.strip() or mutated == orig:
        subprocess.run(["mv", bak, path], cwd=ROOT, check=True)
        print(f"❌ 拒绝写空文件/无变化：{desc}")
        fails += 1
        continue
    with open(path, "w", encoding="utf-8") as f:
        f.write(mutated)
    red, _ = guard_red(guard)
    # 还原
    subprocess.run(["mv", bak, path], cwd=ROOT, check=True)
    after = md5(path)
    restored_ok = (after == before)
    still_red, tail = guard_red(guard)
    green = not still_red   # 还原后应当**不再红**
    ok = red and restored_ok and green
    print(f"{'✅' if ok else '❌'} 变异：{desc}")
    print(f"    护栏={guard} 改坏后变红={red} 还原md5一致={restored_ok} 还原后又全绿={green}")
    if not ok:
        fails += 1
        print("    —— 还原后护栏输出尾部 ——")
        for ln in tail.strip().splitlines()[-4:]:
            print("    " + ln)

print("=" * 72)
print(f"{'🎉 全部变异验证通过' if fails == 0 else f'❌ {fails} 条变异验证失败'}（{len(MUTATIONS) - fails}/{len(MUTATIONS)}）")
sys.exit(1 if fails else 0)
