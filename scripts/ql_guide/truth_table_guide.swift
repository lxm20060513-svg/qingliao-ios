// MARK: - 登录页「使用指南」文案真值表（v4.0.47）
//
// 用户原话（2026-10-04）：*「针对登录页的使用说明有需要更新一下吗？或者从源头上简化一下部署步骤，评审一下」*
//   → 两路评审结论：**要改**，其中第 1 步是**硬错**（照它装 = 收件箱/推送静默失效）。
//   → 用户拍板：A 全改（硬错 + 遗漏 + 措辞）随 v4.0.47 一起发；B 只改文案，App 侧不改协议探测逻辑。
//
// 为什么必须有这张表：LoginGuideSheet 是全 App 唯一一份「面向用户的部署教学」，
//   而它**此前零护栏** —— 文案与后端真实流程漂移不会被任何真值表拦下，一直教到 v3.9.88 口径：
//   第 1 步「编辑 docker-compose.yml → docker compose up -d」，而 QL_INBOX_TOKEN / QL_PUSH_TOKEN
//   是**必填**（compose 默认留空 → 后端 inbox_api.py / push_api.py 一律拒绝放行**且不报错**，
//   只有 install.sh 会随机生成）。照旧文案部署的用户：聊天能用，收件箱/推送/后台作业全静默失效。
//
// 本表把「指南 = 真实部署流程」变成硬断言：改错、改回旧口径、漏补必填提醒、把误导写回来 → 必红。
//
// 判据真源（2026-10-04 逐条复核，非子代理自述）：
//   · 后端仓 README:41（官方路径 = `bash install.sh`）、README:121-123（QL_PASSWORD / QL_INBOX_TOKEN /
//     QL_PUSH_TOKEN 均标 ✅必填，token 行明文「空=拒绝放行」）
//   · 后端仓 install.sh:35（循环生成两个 token）、install.sh:26/48（交互式 read -p）
//   · 后端仓 backend/inbox_api.py:47、push_api.py:24（读环境变量，空值即拒绝）
//   · 本仓 AuthStore.swift:133-136（裸主机无协议 → 按 **https** 处理；末尾斜杠自动去掉）
//
// ⚠️ 本表是**文本级**断言（指南是纯文案，没有可跑逻辑）。因此：
//   · 只钉「换了就代表口径变了」的判别性子串，不做整段字面量等值比对（避免无意义假红）；
//   · 注释按**整行**剥离（不按行内 `//` 剥）—— 指南文本里有 `http://…` 等 URL 字面量，
//     行内剥注释会把字符串截断成假红。

import Foundation

// Swift 6 严格并发：顶层 var 默认 MainActor 隔离，非隔离的 ok() 改不了 → 与本仓其它新表同写法。
nonisolated(unsafe) var pass = 0
nonisolated(unsafe) var fail = 0
func ok(_ cond: Bool, _ name: String) {
    if cond { pass += 1; print("  ✅ \(name)") } else { fail += 1; print("  ❌ \(name)") }
}

let repo: String = {
    if let e = ProcessInfo.processInfo.environment["QL_REPO"], !e.isEmpty { return e }
    // #filePath = <repo>/scripts/ql_guide/truth_table_guide.swift → 上溯三级到仓库根
    return URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path
}()
let path = repo + "/qingliao/Features/Auth/LoginGuideSheet.swift"
let raw = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
if raw.isEmpty { print("❌ 读不到 \(path)"); exit(1) }

// 入口侧：指南必须真的挂得上（可见入口都要能用）
let lvPath = repo + "/qingliao/Features/Auth/LoginView.swift"
let lvRaw = (try? String(contentsOfFile: lvPath, encoding: .utf8)) ?? ""
if lvRaw.isEmpty { print("❌ 读不到 \(lvPath)"); exit(1) }

/// 整行注释剥离：本文件自身带着「旧口径长什么样」的说明注释，
/// 不剥会把「注释里提到旧文案」当成真命中（本仓老坑：注释里写了就假绿/假红）。
func stripFullLineComments(_ text: String) -> String {
    text.split(separator: "\n", omittingEmptySubsequences: false)
        .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        .joined(separator: "\n")
}
let src = stripFullLineComments(raw)
let lvSrc = stripFullLineComments(lvRaw)

func count(_ needle: String) -> Int { src.components(separatedBy: needle).count - 1 }

print("── ① 第 1 步：必须走 install.sh（硬错修复的核心）──")
ok(src.contains("跑 bash install.sh"), "手动部署指向 bash install.sh（官方路径，非手改 compose）")
ok(src.contains("QL_INBOX_TOKEN / QL_PUSH_TOKEN"), "点名两个必填的服务间 token")
ok(src.contains("静默失效"), "写明漏掉 token 的后果是**静默**失效（不报错才最坑）")
ok(src.contains("bash install.sh          # 交互式"), "命令块第 1 条就是 install.sh")
ok(count("docker compose up -d") == 0, "命令块不再教「直接 up -d 起服务」（漏 token 的元凶）")
ok(count("编辑 docker-compose.yml 设置密码与上游 AI 端点") == 0, "旧「编辑 compose 设密码」口径清零")
ok(src.contains("智能家居需另配 Home Assistant"), "智能家居写清需另配 HA（非「自动随服务开启」）")
ok(count("智能家居 / 文件管理等模块自动随服务开启") == 0, "旧「自动开启」误导清零")

print("── ② 第 3 步：地址栏口径（原「自动补 https」是主动误导）──")
ok(src.contains("局域网填 http://你的NAS地址:9127"), "局域网明确要求写 http://（明文部署）")
ok(src.contains("App 会按 https 处理"), "把真实行为讲清：裸主机按 https 处理（不再说「自动补」）")
ok(count("只填主机不确定协议时，App 会自动补 https") == 0, "旧「自动补 https」误导清零")
ok(count("地址末尾不要带斜杠") == 0, "旧「末尾不要带斜杠」清零（App 自动去，写成用户要求不实）")
ok(src.contains("带不带斜杠都行"), "改为「带不带斜杠都行，App 会自动去掉」")
ok(src.contains("非 443 端口要带上"), "公网非标端口要带上（如 :16666），防漏填端口")

print("── ③ 第 4 / 5 步：补回被漏掉的两条关键信息 ──")
ok(src.contains("cat .env 查看"), "留空取密码的**可执行**路径（install.sh 随机生成只写 .env 且不打印 → 必须教 cat .env）")
ok(src.contains("没用 install.sh、QL_PASSWORD 真为空时，后端才会把随机密码写到 data/initial_password.txt"),
   "initial_password.txt 必须写成**条件式**（只在没用 install.sh 时才生成）")
ok(!src.contains("随机生成，写在部署目录的 data/initial_password.txt 里"),
   "旧误导整句已清零（install.sh 路径下部署目录里根本没有这个文件）")
ok(src.contains("账号与安全 → 修改密码"), "改密码路径补全（账号与安全 → 修改密码）")
ok(src.contains("设置 → 后端更新 → 一键更新"), "补 App 内一键更新（用户变多后最值钱的一条）")
ok(src.contains("--version v4.0.xx"), "补 ./update.sh --version <tag>（配套指定 App 版本）")
ok(src.contains("设置 → 关于轻聊"), "「关于轻聊」用实际页名（不是「关于」）")

print("── ④ 页脚：两份 README 要可点（不只文字里提一句）──")
ok(count("Label(\"后端仓库 README\"") == 1, "后端仓 README 是可点 Link")
ok(count("Label(\"插件仓库 README\"") == 1, "插件仓 README 是可点 Link")
ok(count("Link(destination: url)") >= 3, "页脚两条 README 链接都在（第 1 步原有一条 skill 链接）")

print("── ⑤ 结构不许被「全改」误伤 + 入口可用 + 脱敏 ──")
ok(count("GuideStep(") == 5, "仍是 5 步（改文案不许误删步骤）")
ok(lvSrc.contains(".sheet(isPresented: $showGuide) { LoginGuideSheet() }"), "指南弹层仍接线（可见入口 = 能用）")
ok(lvSrc.contains("Text(\"使用指南\")"), "登录页「使用指南」入口仍在")
ok(count("ghp_") == 0 && count("sk-") == 0, "不得出现 token 形态字符串")
ok(count("192.168.") == 0, "不得出现私网 IP 字面量（对外文案脱敏）")
ok(count("你的NAS地址") >= 1 && count("你的域名") >= 1, "示例一律用占位符（你的NAS地址 / 你的域名）")

print("")
print("通过 \(pass) / 失败 \(fail)")
exit(fail == 0 ? 0 : 1)
