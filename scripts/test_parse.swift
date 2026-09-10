import Foundation

// StreamHTTPClient.parseResponse 的独立副本（Linux 无 CFStream，逻辑一致）
func parseResponse(_ data: Data) -> (Data, Int) {
    guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else {
        return (data, 0)
    }
    let headerPart = data[..<headerEnd.lowerBound]
    let bodyPart = data[headerEnd.upperBound...]
    let headerText = String(data: headerPart, encoding: .utf8) ?? ""
    var code = 0
    if let firstLine = headerText.split(separator: "\r\n").first {
        let parts = firstLine.split(separator: " ")
        if parts.count >= 2 {
            code = Int(parts[1]) ?? 0
        }
    }
    return (Data(bodyPart), code)
}

var failures = 0
func check(_ name: String, _ cond: Bool) {
    print("\(cond ? "✅" : "❌") \(name)")
    if !cond { failures += 1 }
}

// 测试 1: 完整 POST 登录响应（lucky 实测 200 + Content-Length 130）
let postResp = Data("HTTP/1.1 200 OK\r\nAccess-Control-Allow-Headers: Content-Type\r\nContent-Length: 130\r\nContent-Type: application/json\r\n\r\n{\"ok\":true,\"token\":\"e51288d47e22c4e0c900f239407cc7cbc1a65ecaa5df3155\",\"expiresAt\":1786933276.4,\"username\":\"qingliao\"}".utf8)
let (body1, code1) = parseResponse(postResp)
check("POST 响应状态码=200", code1 == 200)
check("POST body 含 token 字段", String(data: body1, encoding: .utf8)?.contains("e51288d47e22c4e0c900f239407cc7cbc1a65ecaa5df3155") == true)
check("POST body 可解析为 JSON", (try? JSONSerialization.jsonObject(with: body1)) != nil)

// 测试 2: GET 401 响应（测试连接）
let getResp = Data("HTTP/1.1 401 Unauthorized\r\nContent-Length: 35\r\n\r\n{\"ok\":false,\"error\":\"unauthorized\"}".utf8)
let (_, code2) = parseResponse(getResp)
check("GET 响应状态码=401", code2 == 401)

// 测试 3: 无 \r\n\r\n 的残缺数据（超时/分块场景）
let partial = Data("HTTP/1.1 200 OK\r\nContent-Len".utf8)
let (_, code3) = parseResponse(partial)
check("残缺数据状态码=0", code3 == 0)

// 测试 4: headers 与 body 分块拼接后解析（模拟多次 receiveMessage）
let h = Data("HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\n".utf8)
let b = Data("ping".utf8)
let (body4, code4) = parseResponse(h + b)
check("分块拼接 body=ping", String(data: body4, encoding: .utf8) == "ping" && code4 == 200)

print(failures == 0 ? "\n🎉 全部通过" : "\n❌ \(failures) 个失败")
exit(failures == 0 ? 0 : 1)
