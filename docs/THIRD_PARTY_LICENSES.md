# 第三方开源组件（署名与许可）

轻聊 App 内嵌以下第三方代码。按各自许可证要求保留版权声明。

---

## lersent001/orb —— AI 头像「siri 液态玻璃球」

- 项目：https://github.com/lersent001/orb （在线编辑器：https://lersent001.github.io/orb/）
- 用途：AI 头像渲染（思考中动画 / 静止态静态帧）
- 引入方式：使用该项目自带的 SwiftUI/Metal 导出器生成渲染器与着色器，轻聊侧仅做 4 处改造
- 涉及文件：
  - `qingliao/Features/Chat/LiquidOrbEffect.metal` —— Metal 着色器（本地修正 1 处：上游第 1855 行
    `discard_fragment()` 漏写 `metal::` 命名空间，MSL 编译报 undeclared identifier；全文其余均为 `metal::` 前缀）
  - `qingliao/Features/Chat/LiquidOrbAvatar.swift` —— SwiftUI + MetalKit 渲染器（导出后改造）
- 轻聊侧的 4 处改造：
  1. 删掉内嵌的 76KB Metal 源码字符串 → 改为编译期 `default.metallib`（CI 可提前发现着色器错误）
  2. `device` / `commandQueue` / 三条管线提取为进程级共享单例（原为每个渲染器各建一套）
  3. 静止态冻结（`isPaused` + 按需重绘）、思考态 30fps（原模板恒 60fps）
  4. 初始化失败不再 `preconditionFailure`（降级为退回脑形标，不让 App 崩溃）

```
MIT License

Copyright (c) 2026 LerSent001

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```
