import Foundation

// MARK: - 模型显示名映射（单一真源）
//
// v4.0.86（瘦身②）：原本 SettingsModels 与 SettingsModelAgent 各抄一份
// opencodeNames / sensenovaNames（各 ~30 行，逐字同构；仅 opencodeNames 差一条
// deepseek-v4-flash-free——合并后以全量为准，显示名多一条不影响查询未命中时的
// 回退行为 `names[model] ?? model`）。
//
// ⚠️ 维护口径：新增模型 ID 时**只改这里**；两处 UI（模型设置页 / 智能体设置页）
// 都从本文件取。映射只影响「显示名」，模型拉取/请求用的仍是原始 ID，漏配一条
// 只会显示原始 ID，不会出错。

/// opencode 通道模型显示名（opencode / opencode-apple 两通道共用）
let opencodeModelNames: [String: String] = [
    "deepseek-v4-flash": "DeepSeek V4 Flash",
    "deepseek-v4-flash-free": "DeepSeek V4 Flash Free",
    "deepseek-v4-pro": "DeepSeek V4 Pro",
    "kimi-k3": "Kimi K3",
    "kimi-k2.7-code": "Kimi K2.7 Code",
    "kimi-k2.6": "Kimi K2.6",
    "kimi-k2.5": "Kimi K2.5",
    "glm-5.3": "GLM 5.3",
    "glm-5.2": "GLM 5.2",
    "glm-5.1": "GLM 5.1",
    "glm-5": "GLM 5",
    "qwen3.8-max": "Qwen3.8 Max",
    "qwen3.7-max": "Qwen3.7 Max",
    "qwen3.7-plus": "Qwen3.7 Plus",
    "qwen3.6-plus": "Qwen3.6 Plus",
    "qwen3.5-plus": "Qwen3.5 Plus",
    "minimax-m3": "MiniMax M3",
    "minimax-m2.7": "MiniMax M2.7",
    "minimax-m2.5": "MiniMax M2.5",
    "mimo-v2.5-pro": "MiMo V2.5 Pro",
    "mimo-v2.5": "MiMo V2.5",
    "mimo-v2-pro": "MiMo V2 Pro",
    "mimo-v2-omni": "MiMo V2 Omni",
    "gpt-5.6-luna": "GPT-5.6 Luna",
    "grok-4.5": "Grok 4.5",
]

/// SenseNova（商汤）模型显示名
let sensenovaModelNames: [String: String] = [
    "sensenova-6.8-flash-lite": "SenseNova 6.8 Flash Lite",
    "sensenova-6.7-flash-lite": "SenseNova 6.7 Flash Lite",
    "sensenova-u1-fast": "SenseNova U1 Fast",
    "deepseek-v4-flash": "DeepSeek V4 Flash",
    "glm-5.2": "GLM 5.2",
]
