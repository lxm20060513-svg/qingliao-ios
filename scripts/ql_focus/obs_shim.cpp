// v4.0.104：本机 Swift 6.0.3 工具链的 `libswiftObservation.so` 里有一个**未解析符号**
// `_ZN5swift9threading5fatalEPKcz`（swift::threading::fatal），而 libswiftCore.so 并未导出它
// —— 这是该工具链包自身的缺口，与本仓代码无关（`swiftc -parse` 查不出、只有真链接才炸）。
//
// 影响面：只有「本地直接编译带 @Observable 的类」才会踩到（iOS 侧走 Xcode 自带的 runtime，
// 完全不受影响）。为了让专注计时的状态机能在本地**真跑**（而不是靠人眼读代码），
// 这里补一个**行为等价**的实现：按原样打印格式串然后 abort —— 真实运行库的 fatal 也是这个语义。
// 只在运行库报告致命错误时被调用，绝不改变正常路径行为。
#include <cstdarg>
#include <cstdio>
#include <cstdlib>

namespace swift {
namespace threading {
void fatal(const char *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    std::vfprintf(stderr, fmt, args);
    va_end(args);
    std::fputc('\n', stderr);
    std::abort();
}
}  // namespace threading
}  // namespace swift
