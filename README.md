# 常醒 · KeepingYouAwake 中文版

基于 [newmarcel/KeepingYouAwake](https://github.com/newmarcel/KeepingYouAwake) 的 MIT 开源分支，让 MacBook 在熄屏、合盖且不连接外接显示器时继续运行。保留上游作者及许可证信息。

## 功能

- 完善简体中文界面、通知和菜单栏提示，增加明确的 `zh-Hans` 语言资源。
- 打开应用后默认保持运行，允许屏幕按系统设置自动熄灭；不自动修改登录项。
- 右键菜单栏图标 → **保持运行并熄屏**，立即关闭显示器，后台任务继续运行。
- 右键菜单栏图标 → **开启合盖持续运行…**，通过 macOS 管理员授权启用合盖运行，不需要外接显示器。
- **关闭合盖持续运行** 或退出应用后，恢复启用前的系统睡眠设置。左键点击图标可停止/恢复普通保持运行。

## 安装与使用

下载本仓库 Releases 中的 `Changxing-1.7.0-macOS.zip`，解压后将 `Changxing.app` 放到“应用程序”并打开。应用在菜单栏显示图标。

这是本地 ad-hoc 签名构建，尚未使用 Developer ID 签名和 Apple 公证。若 macOS 首次阻止打开，请到“系统设置 → 隐私与安全性”选择“仍要打开”；不要关闭 Gatekeeper。

开启合盖模式时在 macOS 原生授权窗口输入管理员凭据。看到菜单中“关闭合盖持续运行”及勾选状态后再合盖。该模式不会在下次打开应用时自动开启，每次会话均单独授权。切换保持运行时长会保留当前合盖会话；定时结束时同步恢复系统睡眠。

普通保持运行使用 `caffeinate -i`，只阻止空闲睡眠，不阻止用户主动选择“睡眠”。熄屏会作用于所有已连接显示器。

## 合盖模式与恢复

合盖模式使用 macOS 的全局 `pmset disablesleep` 设置；该选项没有出现在公开 `pmset` 手册中，未来系统兼容性需要重新验证，不能当作 Apple 承诺的应用 API。

独立的临时管理员进程负责恢复：检测应用 PID 与进程启动时间、应用心跳和停止信号。退出、崩溃或心跳超时会恢复睡眠；电池供电且电量不高于 10% 时也会结束合盖模式。没有安装 LaunchDaemon、sudoers 规则或永久提权组件。若恢复失败，菜单会显示“重试恢复系统睡眠…”，由你主动再次授权重试，不会把失败显示为已关闭。

如果其他工具已经禁用系统睡眠，常醒不会接管或改写它。合盖模式运行期间不要同时用其他工具更改同一全局设置。

紧急恢复方法：在终端运行 `sudo pmset disablesleep 0`，然后用 `pmset -g` 检查 `SleepDisabled` 为 `0`。此命令仅用于确认没有其他工具需要禁睡时。

## 从源码构建

需要 macOS 12+、可编译 C23 / Swift Tools 6.1 的 Xcode；本分支在 Xcode 27.2 / macOS 27.2 构建。合盖功能仅用于非沙盒的本地分发版本。

```bash
./Scripts/build-local.sh
```

产物在 `dist/`。所有 Swift Package 依赖都在仓库内，已移除上游 Sparkle 自动更新依赖，避免中文分支被上游版本覆盖。Bundle ID 为 `com.webfooo.Changxing`，URL Scheme 为 `changxing`，与上游应用隔离。

```bash
python3 Scripts/test-clamshell-session.py
./Scripts/test-sleep-wake-timer.sh

xcodebuild test -workspace KeepingYouAwake.xcworkspace -scheme KeepingYouAwake \
  -destination 'platform=macOS' -derivedDataPath build \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
  OTHER_CODE_SIGN_FLAGS=--timestamp=none
```

## 验证状态

合盖和电源恢复逻辑包含不修改系统电源状态的模拟测试。构建、原有单元测试与界面检查结果见发布说明；**真实合盖、不接外屏的持续运行仍需在目标 MacBook 上验收**，不能用模拟测试代替硬件验收。

## 许可证与上游

MIT，见 [LICENSE](LICENSE)。上游说明保存于 [README.upstream.md](README.upstream.md)。中文分支由 fanaruto 维护，未经上游作者背书。
