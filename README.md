# MakeACopy Android 9 适配版 · 自动跟进

当官方 [egdels/makeacopy](https://github.com/egdels/makeacopy)（离线文档扫描 + PaddleOCR）发布新版本时，本仓库通过 GitHub Actions **自动检测 → 自动适配 → 自动发布** Android 9 兼容 APK（arm64-v8a）。

官方版最低要求 Android 10；本仓库产出的适配版可在 **Android 9（API 28）** 上安装使用。

## 为什么官方版不支持 Android 9

1. 官方 `minSdk = 29`（Android 10）
2. 官方代码中有 8 处直接调用 Android 10 专属 API（系统手势排除区、放大镜）
3. **核心原因**：官方自编译的 ONNX Runtime 库引用了 `android_get_device_api_level@LIBC_Q` 系统符号——该符号只在 Android 10+ 的 libc 中存在，Android 9 上库加载直接失败、应用打开即闪退。这是无法通过改代码解决的硬性不兼容，必须替换原生库。

## 适配内容（每次新版自动重做）

| 改动 | 方式 |
|------|------|
| `minSdk` 29 → 28 | 脚本自动修改 `app/build.gradle` |
| 8 处 API 29+ 调用加版本守卫 | 脚本自动打补丁（手势排除区 ×3、放大镜 ×1） |
| ONNX Runtime 替换为微软官方预编译版 | 自动探测官方锁定的 ORT 版本 → 从 Maven Central 下载配套 AAR |
| OpenCV 库 | 直接从官方新版 APK 提取（与官方字节一致） |
| 重新签名 | 使用本仓库 Secrets 中的密钥（`KEYSTORE_B64`） |

## 自动跟进机制

- **触发器**：每 6 小时轮询官方 GitHub Releases API（GitHub Actions 无法直接订阅他仓库的发布事件）
- **判断**：官方最新 tag > 本仓库 `LAST_ADAPTED_VERSION` 记录 → 开始适配
- **产物**：自动创建 Release，tag 形如 `v4.7.0-android9`，附件为适配版 APK
- **手动触发**：Actions → `Adapt MakeACopy for Android 9` → Run workflow，可填入 `force_tag` 强制适配指定版本

## 首次配置（只需一次）

1. 在 GitHub 新建仓库并推送本仓库内容（含 `.github/workflows/`）
2. 配置 3 个 Secrets（Settings → Secrets and variables → Actions）：

| Secret | 值 |
|--------|-----|
| `KEYSTORE_B64` | 签名密钥的 base64：`base64 -w0 keystore.jks` |
| `KEYSTORE_PASSWORD` | 密钥密码 |
| `KEYSTORE_ALIAS` | 密钥别名（默认 `makeacopy`） |

3. 确认 Actions 已启用（仓库创建后默认启用）

## 本地手动运行

```bash
# 需要 JDK 21 + Android SDK（build-tools 36）+ 本机密钥 keystore.jks
./adapt.sh v4.7.0
```

## 安装说明

- 适配版使用自签名（非官方签名）——**安装前需先卸载官方版**
- 安装后不会收到官方渠道的自动更新，以本仓库 Release 为准
- 与官方版的差异仅限上述 4 项，扫描/OCR/PDF 导出等功能完整保留

## 许可与致谢

- 上游项目 [egdels/makeacopy](https://github.com/egdels/makeacopy) 基于 Apache License 2.0，本仓库是对其构建流程的自动化改编，不包含上游应用源码
- ONNX Runtime © Microsoft，Apache License 2.0
- OpenCV © OpenCV team，Apache License 2.0
- 适配版 APK 为上游应用源码的衍生作品，依据上游许可分发
