# 验证记录

日期：2026-11-04（Asia/Shanghai）。环境：macOS 27.2、Xcode 27.2。

- Release 构建通过；arm64 / x86_64，最低部署目标 macOS 12。
- Xcode 原有 37 项 XCTest 通过。
- `Scripts/test-sleep-wake-timer.sh`：3 项真实 caffeinate -i 集成测试通过，启用 AddressSanitizer；覆盖自然到期、停止后子进程回收、立即重启的回调隔离。
- `Scripts/test-clamshell-session.py`：15 项无管理员权限的 fake pmset 回归通过，覆盖恢复、异常、低电量、外部修改、并行锁和嵌入脚本一致性。
- 原生界面已检查通用、高级、电池、关于页的中文显示；默认允许屏幕熄灭，未自动设置登录项。
- 实际启动应用后观察到归属于应用 PID 的 PreventUserIdleSystemSleep 断言；未出现由本应用创建的显示器防睡眠断言。
- 复审并修复切换时长与合盖会话异步恢复之间的竞态，定时结束会恢复合盖睡眠。
- `git diff --check`、plist 校验和 ad-hoc 签名校验通过。

## 尚待硬件验收

本次没有请求管理员授权、没有修改这台 Mac 的 `SleepDisabled`，没有实际合盖验收。模拟测试不能证明特定 MacBook / macOS 组合合盖后会持续运行。

在目标 MacBook 上从菜单开启合盖模式并自行完成管理员授权后，可断开外屏、合盖数分钟，再核对后台任务及菜单状态；关闭模式后应回到 `SleepDisabled 0`。该选项来自 macOS 的全局 pmset 设置，不是公开承诺稳定的应用 API。

该构建采用 ad-hoc 签名，未使用 Developer ID，也未 Apple 公证。
