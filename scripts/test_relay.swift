// Safari Relay 编解码 + 会话 uid 单元测试（Linux 本地预检用）
// 验证：base64url 往返、payload JSON 序列化、uid 稳定性

import Foundation

// MARK: - 被测逻辑（与 SafariRelay.swift 同步）

func base64urlEncode(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

func base64urlDecode(_ s: String) -> Data? {
    var b64 = s
        .replacingOccurrences(of: "-", with: "+")
        .replacingOccurrences(of: "_", with: "/")
    let rem = b64.count % 4
    if rem > 0 { b64 += String(repeating: "=", count: 4 - rem) }
    return Data(base64Encoded: b64)
}

func relayUid(for sessionId: String) -> String {
    var h: UInt32 = 2166136261
    for b in sessionId.utf8 {
        h ^= UInt32(b)
        h = h &* 16777619
    }
    return "u" + String(h, radix: 16)
}

// MARK: - 测试

var failures = 0
func check(_ cond: Bool, _ name: String) {
    if cond { print("✅ \(name)") } else { print("❌ \(name)"); failures += 1 }
}

// 1. base64url 往返（含 +/= 边界字符）
let original = Data("{\"m\":\"POST\",\"p\":\"/r/stream/start/u1a2b\",\"b\":\"{\\\"msg\\\":\\\"你好+/=\\\"}\"}".utf8)
let enc = base64urlEncode(original)
check(!enc.contains("+") && !enc.contains("/") && !enc.contains("="), "base64url 无 URL 不安全字符")
let dec = base64urlDecode(enc)
check(dec == original, "base64url 往返一致")

// 2. 空数据
let empty = Data()
check(base64urlDecode(base64urlEncode(empty)) == empty, "空数据往返")

// 3. 中文 payload
let cn = Data("{\"b\":\"你好，世界\"}".utf8)
check(base64urlDecode(base64urlEncode(cn)) == cn, "中文 payload 往返")

// 4. uid 稳定性（同输入同输出）
check(relayUid(for: "abc123") == relayUid(for: "abc123"), "uid 同输入稳定")
check(relayUid(for: "abc123") != relayUid(for: "abc124"), "uid 不同输入不同")
check(relayUid(for: "abc123").hasPrefix("u"), "uid 前缀 u")

// 5. relay payload JSON 结构
let payload: [String: Any] = ["m": "POST", "p": "/r/stream/start/u123", "b": "{\"x\":1}"]
let pd = try! JSONSerialization.data(withJSONObject: payload)
let parsed = try! JSONSerialization.jsonObject(with: pd) as! [String: Any]
check(parsed["m"] as? String == "POST", "payload method 字段")
check(parsed["p"] as? String == "/r/stream/start/u123", "payload path 字段")
check(parsed["b"] as? String == "{\"x\":1}", "payload body 字段")

// 6. relay 响应解析（模拟服务器 302 回跳内容）
let respJSON = "{\"s\":200,\"b\":\"{\\\"taskId\\\":\\\"t123\\\"}\"}"
let rd = base64urlDecode(base64urlEncode(Data(respJSON.utf8)))!
let rj = try! JSONSerialization.jsonObject(with: rd) as! [String: Any]
check(rj["s"] as? Int == 200, "响应 status 解析")
let inner = try! JSONSerialization.jsonObject(with: Data((rj["b"] as! String).utf8)) as! [String: Any]
check(inner["taskId"] as? String == "t123", "响应内嵌 taskId 解析")

// 7. URL 长度估算（4KB 限制）
let longBody = String(repeating: "x", count: 3000)
let bigPayload: [String: Any] = ["m": "POST", "p": "/r/x", "b": longBody]
let bigEnc = base64urlEncode(try! JSONSerialization.data(withJSONObject: bigPayload))
let urlLen = "https://example.com:16666/r?r=".count + bigEnc.count
print("ℹ️  3000 字节 body → relay URL 长度 \(urlLen)（限制 ~4096）")
check(urlLen < 4096, "3KB payload 在 URL 长度限制内")

if failures > 0 {
    print("\n❌ \(failures) 个测试失败")
    exit(1)
}
print("\n🎉 relay 编解码全部通过")
