# TODO

## SwiftTerm 中文历史日志重排

维护约定：只使用 SwiftTerm 官方发布版本，不维护本地补丁或 fork。

- [x] 2026-10-16 检查上游：[#727](https://github.com/migueldeicaza/SwiftTerm/pull/727) 已于 2026-10-01 合并，修正宽字符历史重排时误用全局缓冲区计算当前折行组长度的问题，包含在官方 [v1.99.0](https://github.com/migueldeicaza/SwiftTerm/releases/tag/v1.99.0) 中。
- [x] 用相同的 200 行中文日志、连续缩放和跨窗口移动用例做对照：修复前有 5 处内容变化，官方 1.99.0 通过。macOS 和 iOS / iPadOS 统一固定到官方 1.99.0。
- [x] 将中文历史重排和真实 SSH 跨窗口回归恢复为默认运行，保留对真实空格和异常 NUL 单元格的严格检查。
- [x] 2026-10-16 使用 Xcode 26.6 内置 Swift 6.3.3 的初步验证：macOS 全量 330 项（2 项可选测试跳过）；iPhone 和 iPad 各 39 项模型 / 输入测试、2 项 SSH 终端 UI 测试通过，并检查中文日志缩放后的渲染截图。
- [x] 2026-10-16 使用官方 Swift 6.4.1 编译器、Swift 6 语言模式重新验收：macOS 330 项（2 项可选测试跳过），iPhone 和 iPad 各 39 项模型 / 输入测试、2 项 SSH 终端 UI 测试均通过。已核对 macOS 编译产物及 iOS 构建命令中的实际编译器版本，项目代码和 SwiftTerm 均使用 6.4.1 编译、Swift 6 语言模式。`.swift-version` 记录 6.4.1，包清单最低工具版本不能代替实际编译器选择。
- [ ] 每月手动检查一次 [官方发布](https://github.com/migueldeicaza/SwiftTerm/releases)，并在每次升级依赖时重新运行以下回归；记录检查日期、版本和结果。下次计划复查：2026-11-16。当前中文重排问题已通过官方版本解决；后续关注是否回退及新版本兼容性。

回归验收：

```sh
# 选择项目验收使用的官方编译器，再核对实际版本。
export TOOLCHAINS='org.swift.641202610071a com.apple.dt.toolchain.XcodeDefault'
xcrun swift --version

# 无 SSH 连接：中文长日志、连续缩放与跨窗口移动，逐行比较原文。
swift test --filter TerminalScrollbackResizeTests

# 真实 SSH：拆出标签、连续缩放、移回原窗口与远端 PTY 尺寸。
# 需要 Docker 测试服务。
swift test --filter WorkspaceTransferTests/test_scrolled_chinese_ssh_logs_survive_tear_off_live_resize_and_drop_back_into_original_window

# 分别在 iPhone 和 iPad 模拟器运行；将 name 改成对应设备名称。
SWIFT_EXEC_MANIFEST="$(xcrun --toolchain com.apple.dt.toolchain.XcodeDefault --find swiftc)" \
xcodebuild -project Termes.xcodeproj -scheme TermesMobile \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:TermesMobileTests test
```

移动端需覆盖中文与英文混排、横竖屏 / 窄窗口、键盘显示和隐藏、字体切换、历史滚动与粘贴。升级后执行 macOS 全量测试，并用可选的本机 SSH UI fixture 检查终端输入、旋转和新输出提醒。
