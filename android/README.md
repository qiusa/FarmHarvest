# 事项提醒 Android 客户端

原生 Android 客户端以 `FarmHarvestiOS/PhoneContentView.swift` 为功能基准，使用 Kotlin、Jetpack Compose 和 Gradle 构建。Android 与 iOS 使用同一份版本化 JSON 备份格式，支持跨平台手动合并/替换数据。

## 已实现的手机端功能

- 新建提醒：六种内置模板、自定义模板、分钟间隔、可选备注和预计提醒时间。
- 事项记录：待提醒/已到期/总计统计、逐秒倒计时和紧急程度颜色、完成/撤销、编辑、再次提醒、删除及清理已结束记录。
- 编辑记录：修改名称/备注；编辑、完成/撤销和删除单次提醒；按日期时间或“从现在起”调整；新增相对时间或指定时间的下一次提醒。
- 本地通知：到点通知与提前 2 分钟通知；启动、数据变更和设备重启后重排。Android 13+ 首次启动时请求通知权限；“数据”页显示通知/精确闹钟权限状态，并可跳转系统设置开启。可用精确闹钟权限时使用精确闹钟，否则回退到系统允许的省电闹钟。
- 数据：支持局域网共享目录和公网构建管理服务器两个备份通道，可复制备份地址、上传并从对应地址下载；支持本地 JSON 文件导入/导出，导入可合并或经确认后替换；兼容 iOS 导出的 ISO-8601 备份和旧版单次提醒格式。

## 构建安装包

需要 JDK 17 和 Android SDK Platform 35。首次构建会由 Gradle 下载 wrapper 与依赖。

```bash
cd android
./build-apk.sh
```

脚本运行单元测试，构建 Debug 与 Release 变体，并复制可直接安装的 Debug APK 到：

```text
dist/FarmHarvest-Android-debug.apk
```

Debug APK 由本机 Android Debug Keystore 签名，适合侧载安装和验收。没有配置发布密钥时，Release 变体会是未签名 APK；正式发布可通过 Gradle 参数配置私有 keystore（不要提交密钥）：

```bash
./gradlew assembleRelease \
  -PFARMHARVEST_STORE_FILE=/secure/path/release.jks \
  -PFARMHARVEST_STORE_PASSWORD='…' \
  -PFARMHARVEST_KEY_ALIAS='…' \
  -PFARMHARVEST_KEY_PASSWORD='…'
```

需要跑 Android 仪器测试时，先启动 Android 设备或模拟器，再执行：

```bash
./gradlew connectedDebugAndroidTest
```

## Android Studio

在 Android Studio 中打开此 `android/` 目录即可导入 Gradle 项目。应用 ID 为 `com.yixin.farmharvest.android`，最低支持 Android 8.0（API 26）。
