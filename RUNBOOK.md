# 轻聊工程 RUNBOOK（新模型 5 分钟上手）

> 目的：把"每次都要重新发现的东西"写死在这里。**先读本文件，再动手。**
> 详细历史看 `HANDOFF.md`（仓库根，只留最近 3 版）；细枝末节看技能库 `qingliao-*`。历史脚本在 `scripts/_archive/`。

## 0. 环境事实

| 项 | 值 |
|---|---|
| 工作机 | 本容器 `/opt/data`（Linux），住着 Hermes；NAS 是 `192.168.31.40`（SSH 用户 `lxm20060513`，密码在 `/opt/data/.nas_cred`） |
| NAS 共享目录 | NAS 侧 `/volume1/docker/hermes/…` ↔ **本地挂载 `/opt/hermes_host/…`**（读写优先走挂载，不必 SSH） |
| 轻聊后端 | NAS 上的 docker 容器 **`qingliao`**，bind mount 源码；**改文件后 `docker restart qingliao` 即生效** |
| iOS 仓库 | `/opt/data/qingliao_ios`，分支 **`feature/handoff-301`**，CI 由 **tag** 触发 |
| python 环境 | 无 pip；paramiko 用 `/tmp/paramiko_old`；NAS 命令一律走 `ql.py`（内部复用 PTY sudo） |

## 1. 统一入口：`ql.py`（**优先用它，别手写 SSH/git 片段**）

```bash
cd /opt/data/scripts
python3 ql.py                                    # 全部命令
python3 ql.py <组> <动作> --help                  # 单条说明书（这就是文档）

python3 ql.py nas read 微信文件/轻聊web/backend/stream_api.py   # 读（走本地挂载，0.06s）
python3 ql.py nas read <路径> --grep "关键词" --limit 20         # 带过滤
python3 ql.py nas exec "docker ps | grep qingliao"              # root 执行（噪声已过滤）
python3 ql.py nas put ./patch.py 微信文件/轻聊web/backend        # 上传 + md5 回读校验
python3 ql.py backend deploy ./stream_api.py --restart          # 备份→上传→语法检查→重启→冒烟→打印回滚命令
python3 ql.py backend check                                     # 三处接线一致性
python3 ql.py ios check                                         # 语法 + switch 穷尽性 + 真值表
python3 ql.py ios release 3.9.15 [460]                          # bump 8 处 → 校验 → push 重试 → tag → 盯 CI 命令
python3 ql.py diag ci [run号]                                   # CI 失败：失败步骤 + error 行
python3 ql.py diag voice                                        # 读语音诊断上报
python3 ql.py scripts                                           # 脚本目录现状（现役 vs 归档）
python3 ql.py test [--with-ios]                                 # 跑全部真值表（166 项）+ iOS 仓 check_swift.sh
python3 ql.py doctor                                            # 环境体检（凭据/容器/后端/仓库/cron/磁盘），6 秒出结论
```

## 2. 三条主流程

### A. 发版 iOS
```
1) 改代码 → python3 ql.py ios check           # 语法 + 穷尽性（跑不过就别发）
2) 用户同意后 → python3 ql.py ios release <版本>   # bump/push/tag 一条龙（push 会自动重试）
3) 盯包（约 15-20 分钟，用后台进程 + notify，别用 cron）：
   python3 /opt/data/scripts/ql_release/watch_ci.py v<版本> <版本> <构建号>
4) 出包后**必须独立复核**：解包看版本/挂件 appex/实时活动/metallib + md5 + NAS 回读
5) 发微信（MEDIA 路径）+ 更新 HANDOFF + 同步 NAS 镜像 /opt/hermes_host/微信文件/轻聊app/HANDOFF.md
```

### B. 改后端（NAS 上的 python）
```
1) **先取运行源**（暂存副本会漂移，别信它）：python3 ql.py nas read 微信文件/轻聊web/backend/<文件>
2) 本地改 → 端到端验证（带 token 打真实接口，别只看代码）
3) python3 ql.py backend deploy <本地文件> --restart     # 内建备份 + md5 回读 + 回滚命令
4) 新增 API → 必须同步三处，跑 python3 ql.py backend check
   · nginx server.d/qingliao_http.conf（16668）
   · nginx webui_443.conf 的 location
   · backend/stream_api.py 的 ALLOWED_RELAY
   注：relay 真实状态码在 `Location: qingliao://relay?r=<b64>` 的 s 字段（HTTP 恒 302）
```

### C. 排查线上问题
```
1) python3 ql.py nas exec "docker logs --tail 300 qingliao | grep -i <关键词>"
2) 会话/流证据：NAS `微信文件/轻聊web/data/streams/<taskId>.json`
3) 崩溃/诊断：`data/diag/reports.jsonl`（`ql diag voice` / `ql diag ci`）
4) ⚠️ 先看日志 mtime 再判断新旧，别把旧日志当最新
```

## 3. 硬约束（违反就出事，脚本能查的已内建）

1. **新增后端 API 必须同步三处**，漏一处 404/403 → `ql backend check`
2. **改后端文件后必须 `docker restart qingliao`**（bind mount，restart 生效；`systemd qingliao.service` 已废弃）
3. **改后端前先取运行源**，改前备份、改后 md5 回读
4. **发版必须 bump `project.yml` 8 处**（`MARKETING_VERSION` ×2 + `CFBundleShortVersionString` ×2 + 构建号 ×2 + `CFBundleVersion` ×2）——SideStore 同名覆盖不生效
5. **发版后必须校验 IPA**：版本/构建号、主 App 与挂件 appex **逐字一致**、`NSSupportsLiveActivities`、`default.metallib`、md5、NAS 回读
6. **加 enum case 后必须查所有 switch**（本机 `check_swift.sh` 只查语法，`switch must be exhaustive` 只有 CI 会报 —— 曾烧掉一轮 20 分钟 CI）→ `ql ios check`
7. **Codable 加字段必须手写 `init(from:)` + `decodeIfPresent`**，否则旧 JSON 解不开 = 用户数据"消失"
8. **编解码策略必须与编码对齐**（`save` 用 `.iso8601` 就必须用 `.iso8601` 解；曾导致本地兜底从未生效）
9. **本地+远端合并的比较基准用「最后修改时间」而不是创建时间**（否则编辑被旧数据覆盖）
10. **程序化切 tab 必须 `skipBurstOnce()`**（否则误放烟花，已回归过一次）
11. **cron 入口脚本别动**：`hermes_watchdog` / `nas_daily_report` / `docker_prune` / `ql_push_poller` / `ql_task_push`（都在 `scripts/` 根）
12. **用户红线：不要主动重建「危险确认审批闸门」**（用户明确否决过，三端已清除；`approvals.mode: 'off'` 是用户接受的现状）
13. **改完要验证再汇报**：用户对"改完不查就报好"零容忍
14. **公开仓文档一律脱敏**（`qingliao-ios` 是 **public**，默认分支即推上去的分支）：
    · 文档里只写占位符 —— `192.168.x.x`、`<NAS-IP>`、`<SSH 用户>`；
    · 真实 IP / 用户名 / 密码 / token 放本机 `/opt/data/scripts/LOCAL-CONTEXT.md`（**不在仓库内**，git 不跟踪）；
    · 推送前扫一遍：`grep -rnP '192\.168\.|ghp_|sk-|用户名的真实值' . --exclude-dir=.git`，命中就先去敏再提交；
    · NAS 密码永远不进仓库（只在 `/opt/data/.nas_cred`）。

## 4. 高频坑（都是踩过的）

| 坑 | 应对 |
|---|---|
| NAS 输出刷 `CryptographyDeprecation` | 用 `ql.py`（源头过滤） |
| 路径三视角搞混（挂载 / SFTP chroot / NAS 真实） | 用 `ql.py`，只写「本地挂载相对路径」 |
| CI 日志接口带 Authorization 会 401、签名 URL 会 404 | 已封装进 `ql_release/ci_logs.py`（走 `curl -sL`） |
| github push 偶发失败（Empty reply / 超时 / Auth failed） | 重试，**第 3-4 次常成功**；仍不行走 GitHub API 兜底 |
| CI 失败重发要同名 tag | `git push origin :refs/tags/vX` → 本地 `git tag -d` → 重打重推（旧 run 不受影响） |
| 大 view 的 body 会 type-check 超时 | 把子块抽成独立 `@ViewBuilder` / 独立 struct |
| 三元表达式两边类型不同 | 拆 `if/else`（`symbolEffect`、`foregroundStyle` 都踩过） |
| 语音「松手才出字」 | 实时出字需要 `reportingOptions: [.volatileResults, .fastResults]`（缺 `fastResults` 就攒到 finalize 才吐） |
| `nas_run.py` 用法 | `nas_run.py sh "<cmd>"`（多命令用 `;;` 分隔）；`put <local> <chroot视角目录>` |
| NAS 上 root 600 的文件（如 `backend/diag_api.py`）挂载读不了 | `ql nas read` 已自动回退 SSH；仍不行用 `scripts/ql_progress_push/fetch_b64.py` |
| 经 PTY 的 `cat` 有输出上限（11KB 文件只回来 428 字节） | `ql nas read` 已改 sed 分段读（>2KB 自动分段） |
| CI 报错一屏看不懂 | `ql diag ci [run]` 回显 error 行**并自动归因**（原因 + 最小修法） |
| PTY 里命令没输出 / 卡几百秒 | **哨兵必须双引号**（`echo "X$?"`）：单引号不展开 `$?` → 哨兵行变成字面值、正则永不匹配 → drain 白等 600 秒。命令**内部**的引号反过来用单引号 |
| 命令跑了却读不到结果 | `curl -w` 这类不带换行的输出会和 shell 提示符粘在同一行，被提示符过滤整行吞掉 → 格式串末尾加 `\n` |
| NAS 连不上时先证伪网络 | `ql_nas_diag/nas_conn_probe.py` 分段计时（TCP → banner → 认证 → exec）；**用户名是 `lxm20060513`，不是 `lxm`** |

## 5. 文件地图

| 位置 | 内容 |
|---|---|
| `/opt/data/scripts/ql.py` | **统一入口**（本文件描述的所有命令） |
| `/opt/data/scripts/_archive/` | 历史一次性脚本（107 个文件 / 15 个目录，见 `_archive/INDEX.md` 用途索引） |
| `/opt/data/scripts/ql_nas_diag/nas_conn_probe.py` | NAS 连不上时的分段探针（TCP/banner/认证/exec 逐步计时） |
| `/opt/data/scripts/ql_release/` | `watch_ci.py`（盯包）、`ci_logs.py`（CI 失败日志） |
| `/opt/data/scripts/ql_backend_hardening/` | 后端补丁与端到端验证脚本（含运行源快照） |
| `/opt/data/scripts/ql_repeat_diag/nas_run.py` | NAS 执行底层（PTY sudo），`ql.py` 复用 |
| `/opt/data/scripts/ql_progress_push/fetch_b64.py` | 取 NAS 运行源（base64 传输） |
| `/opt/data/qingliao_ios/HANDOFF.md` | 交接主文件（版本沿革 + 待办） |
| `/opt/data/qingliao_ios/qingliao/` | iOS 源码（`Core/` 逻辑、`Features/` 界面） |
| NAS `微信文件/轻聊web/backend/` | 后端源码（容器 `qingliao` 挂载） |
| NAS `微信文件/轻聊app/` | IPA + HANDOFF 镜像（用户取包处） |
