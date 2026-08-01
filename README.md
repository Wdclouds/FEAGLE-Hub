# FEAGLEwxbot Android Kit

FEAGLEwxbot Android Kit 是
[FEAGLEwxbot Bridge](https://github.com/Wdclouds/FEAGLEwxbot-bridge)
的 Android 设备准备与诊断工具。

它面向零基础用户，目标是把下面的过程变成可检查、可恢复的逐步向导：

```text
ADB → 设备与 Root 检查 → 微信版本与签名检查
    → Agent 安装 → Hook 状态检查 → Bridge 配对 → 全链路测试
```

> [!IMPORTANT]
> 当前仓库已迁入 Android Agent、8.0.70 Hook 适配器、Windows 构建/安装/状态
> 检查入口和 Bridge 一次性配对。完整的分段全链路测试仍在建设中。

## 当前支持基线

已经验证的首期设备组合：

| 项目 | 基线 |
| --- | --- |
| 设备 | Samsung Galaxy Tab A8 `SM-X200` |
| Android | 14 |
| Root 管理 | Magisk 30.7 |
| 注入环境 | Zygisk + LSPosed/Vector |
| 微信 | `8.0.70` |
| 电脑端 | Windows 10/11 |

其他设备可以参与后续适配，但当前应显示为“未经验证”，不能向新手承诺兼容。

## 微信 APK 安全规则

本仓库：

- 不托管或重新分发微信 APK。
- 不把第三方下载站写成“微信官方下载”。
- 不在哈希与签名未确认时提供自动下载。
- 不允许工具在验证完成前引导用户登录账号。

微信官方当前版本入口：

- [腾讯微信产品页面](https://www.tencent.com/zh-cn/products/weixin-wechat/)
- [Google Play 上的微信](https://play.google.com/store/apps/details?id=com.tencent.mm)

这些官方入口不保证仍提供项目所需的历史版本 `8.0.70`。历史安装包的下载来源、
文件 SHA-256 和签名证书指纹必须经过独立验证后，才能发布到工具清单。目前已经
从验证设备取得参考指纹，但尚未发布与其完全匹配的下载来源。

当前记录了一个第三方候选页面：

- [APKMirror：WeChat 8.0.70 / 3060 / arm64-v8a](https://www.apkmirror.com/apk/wechat/wechat/wechat-8-0-70-release/wechat-8-0-70-android-apk-download/)

该页面公开的文件大小、文件哈希和签名证书指纹与参考设备一致，但安装助手尚未
独立下载并复验文件。因此它不是“微信官方下载”，也还不是自动安装源。

详见[微信 8.0.70 安装与验证](./docs/02-wechat-8070-install.md)。

## Windows 检查入口

第一次使用时，先在仓库目录一键准备工具：

```powershell
.\scripts\windows\feagle-android.ps1 bootstrap-tools `
  -AcceptAndroidSdkLicense
```

它会从微软与 Google 官方来源下载并校验 JDK 17、Android 命令行工具，
再安装 ADB 与固定版本的 Android Build Tools。全部文件只放在仓库的
`.tools` 目录，不需要管理员权限，也不永久修改系统环境变量。

执行前请阅读
[Android SDK License](https://developer.android.com/studio/terms)；
不添加 `-AcceptAndroidSdkLicense` 时，助手会停止，不会替用户接受许可。
也可以先使用 `bootstrap-tools -DryRun` 只查看计划。

详见 [Windows 工具链一键准备](./docs/03-windows-toolchain.md)。

连接已经由设备所有者开启 USB 调试的 Android 设备，然后运行：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\windows\feagle-android.ps1
```

也可以直接执行子命令：

```powershell
.\scripts\windows\feagle-android.ps1 bootstrap-tools -DryRun
.\scripts\windows\feagle-android.ps1 bootstrap-tools `
  -AcceptAndroidSdkLicense
.\scripts\windows\feagle-android.ps1 doctor
.\scripts\windows\feagle-android.ps1 verify-apk `
  -ApkPath C:\Downloads\wechat-8.0.70.apk
.\scripts\windows\feagle-android.ps1 install-wechat `
  -ApkPath C:\Downloads\wechat-8.0.70.apk `
  -ConfirmInstall
.\scripts\windows\feagle-android.ps1 verify-wechat
.\scripts\windows\feagle-android.ps1 build-agent
.\scripts\windows\feagle-android.ps1 install-agent `
  -ConfirmAgentInstall
.\scripts\windows\feagle-android.ps1 agent-status
.\scripts\windows\feagle-android.ps1 pair-agent `
  -ServerHost your-server.example.com `
  -BridgeEndpoint wss://bot.example.com/android
.\scripts\windows\feagle-android.ps1 source-status
```

如果 `adb.exe` 不在 `PATH`，可以指定路径：

```powershell
.\scripts\windows\feagle-android.ps1 doctor `
  -AdbPath C:\path\to\platform-tools\adb.exe
```

当前助手能够：

- 查找 ADB。
- 查找 JDK 和 Android SDK Build Tools。
- 检查设备是否连接并授权。
- 显示设备型号、Android 版本和 CPU ABI。
- 检查 `su` 是否可用。
- 检查 `com.tencent.mm` 是否安装。
- 检查微信版本是否为 `8.0.70`。
- 验证本地 APK 的大小、文件 SHA-256、腾讯签名、包名、版本和 ABI。
- 只在验证全部通过并显式确认后执行 ADB 安装。
- 遇到设备中的其他微信版本时停止，不自动卸载、降级或清数据。
- 从设备临时读取已安装 APK，完成后立即删除临时副本。
- 构建并检查 Android Agent APK。
- 在显式确认后原地安装或升级 Agent，不自动清数据。
- 检查 Agent、前台服务、通知兜底和最近 Hook 加载状态。
- 通过 SSH 生成 5 分钟单次配对码，重开 Agent 页面后安全预填到平板。
- 显示下载源与哈希是否已经发布。

当前助手不会：

- 解锁 Bootloader 或替用户 Root。
- 自动安装未经验证的微信 APK。
- 静默开启 Zygisk、模块作用域或系统敏感权限。
- 读取微信账号、联系人或消息正文。

## 文档

1. [设备与 Root 前置条件](./docs/01-device-requirements.md)
2. [微信 8.0.70 安装与验证](./docs/02-wechat-8070-install.md)
3. [Windows 工具链一键准备](./docs/03-windows-toolchain.md)
4. [Android Agent 构建、安装、配对与状态检查](./docs/04-agent-build-install.md)
5. [安全策略](./SECURITY.md)

## 路线图

- [x] 仓库骨架与安全边界
- [x] Windows ADB/设备/版本检查
- [x] 微信下载源校验清单
- [x] 从已验证设备确认文件哈希和签名证书指纹
- [x] Windows 本地 APK 验证与受控安装
- [ ] 发布经过验证的下载来源
- [x] 迁入 Android Agent 与 8.0.70 Hook 适配器
- [x] Windows 工具依赖自动准备
- [x] Android 模块基础状态检查
- [x] Bridge 一次性配对码
- [ ] 分段全链路测试
- [ ] 脱敏诊断包

## 许可证

仓库目前尚未选择开源许可证。在许可证确定前，请不要假定已经获得再分发或商业
使用授权。微信及其安装包不属于本项目。
