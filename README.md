# MakeACopy Android 9 适配版 · 自动跟进

当官方 [egdels/makeacopy](https://github.com/egdels/makeacopy)（离线文档扫描 + PaddleOCR）发布**正式新版**时，本仓库通过 GitHub Actions **自动检测 → 自动适配 → 自动发布** Android 9 兼容 APK。

官方版最低要求 Android 10；本仓库产出的适配版可在 **Android 9（API 28）** 上安装使用。

> **ABI 限制：只构建 `arm64-v8a`**（绝大多数 2017 年后的手机）。32 位 ARM（armeabi-v7a）、x86 模拟器均无法安装。

## 为什么官方版不支持 Android 9

1. 官方 `minSdk = 29`（Android 10）
2. 官方代码中有 **8 处** Android 10 专属 API 调用，集中在 `TrapezoidSelectionView.java`，脚本通过 **4 个补丁点**为它们加版本守卫（系统手势排除区 ×3 处调用、放大镜块内 ×5 个方法）
3. **核心原因**：官方自编译（minimal_build）的 ONNX Runtime 库引用了 `android_get_device_api_level@LIBC_Q` 版本化符号——该符号只在 Android 10+ 的 libc 中存在，Android 9 上库加载直接失败、应用打开即闪退。这是无法通过改 Java 代码解决的硬性不兼容，必须替换原生库。

## 适配内容（每次新版自动重做）

| 改动 | 方式 |
|------|------|
| `minSdk` 29 → 28 | 脚本自动修改 `app/build.gradle` |
| 8 处 API 29+ 调用加版本守卫 | 4 个补丁点，**命中数硬断言**（部分命中直接失败，不放行残缺补丁） |
| 全项目 NewApi lint 闸门 | 不只看单个文件：任何文件出现未加守卫的高版本 API 调用即终止，防止上游重构后漏网 |
| ONNX Runtime 替换为微软官方预编译**完整版** | 自动探测官方锁定版本 → 从 Maven Central 下载 AAR（**sha1 校验**）。完整版比官方 minimal_build 体积大约 20MB，换取全算子覆盖、避免缺算子运行期崩溃 |
| OpenCV 库 | 直接从官方新版 APK 提取（与官方字节一致） |
| 全部原生库符号扫描 | APK 内每个 `.so` 都检查 `@LIBC_Q` 及以上版本化符号，一个不漏 |
| `versionName` 加 `-android9` 后缀 | 便于与官方版区分（不改 applicationId，不影响数据） |
| 重新签名 | 使用本仓库 Secrets 中的密钥；同时产出 `.sha256` |

## 自动跟进机制

- **触发器**：每 6 小时轮询官方 GitHub Releases（经 `gh api` 认证调用，避免匿名限流；`/releases/latest` 天然只返回正式版，rc/beta/alpha 预发布版一律跳过）
- **判断**：官方最新 tag **逐段数字比较**且**新于** `LAST_ADAPTED_VERSION` 才适配；标记只进不退
- **产物**：自动创建/更新 Release，tag 形如 `v4.7.0-android9`，附件为 APK + sha256 + NOTICE；重跑幂等（覆盖同名资产）
- **手动触发**：Actions → `Adapt MakeACopy for Android 9` → Run workflow，可填 `force_tag` 强制适配某个正式 tag
- **失败告警**：任何一步失败（最常见是上游重构导致补丁未命中）会自动开一个 issue 提醒人工介入，并上传完整构建日志
- **防 60 天自动禁用**：GitHub 会在仓库连续 60 天无活动后禁用所有定时工作流；`Keepalive` 工作流每周提交一次时间戳，保证轮询永不被停。**首次部署后需手动 Run 一次 Keepalive 启动循环**

## 首次配置（只需一次）

1. 在 GitHub 新建仓库并推送本仓库内容（含 `.github/workflows/`）
2. 生成签名密钥（JDK 自带 keytool）：

```bash
keytool -genkeypair -v -keystore makeacopy-android9.jks \
  -keyalg RSA -keysize 2048 -validity 10000 \
  -alias makeacopy \
  -dname "CN=MakeACopy Android9 Build, O=Personal, C=KW"
# 按提示设置密钥口令，下面称为 <你的密码>
```

3. 配置 3 个 Secrets（Settings → Secrets and variables → Actions）：

| Secret | 值 |
|--------|-----|
| `KEYSTORE_B64` | 签名密钥的 base64：Linux 用 `base64 -w0 makeacopy-android9.jks`；**macOS 用 `base64 -i makeacopy-android9.jks \| tr -d '\n'`** |
| `KEYSTORE_PASSWORD` | 上一步设置的 `<你的密码>` |
| `KEYSTORE_ALIAS` | `makeacopy` |

4. Actions → Keepalive → Run workflow 一次（启动保活循环）
5. 妥善离线备份 `makeacopy-android9.jks`：**丢了它，以后所有版本都无法与已安装版本覆盖升级**

## 本地手动运行

需要 JDK 21 + Android SDK（build-tools 任意较新版本，脚本自动探测）。

```bash
# Linux
./adapt.sh v4.6.1
# macOS：脚本使用 GNU sed 的 -i 语法，请先 brew install gnu-sed 并确保 PATH 中 sed 为 gsed，
# 或直接使用 GitHub Actions（推荐）
```

## 安装说明

- 适配版使用自签名（非官方签名）——**安装前需先卸载官方版**；同一适配密钥签名的各版本之间可互相覆盖升级
- 安装后不会收到官方渠道的自动更新，以本仓库 Release 为准
- 下载后可用随附 `.sha256` 校验：`sha256sum -c MakeACopy-*.apk.sha256`
- 与官方版的功能差异仅限上述适配项，扫描/OCR/PDF 导出等功能完整保留
- **建议每次大版本升级后在 Android 9 真机完整冒烟一次**（扫描 → OCR → 导出 PDF），这是脚本静态验证替代不了的

## 许可与致谢

- 上游项目 [egdels/makeacopy](https://github.com/egdels/makeacopy) 基于 Apache License 2.0，本仓库是对其构建流程的自动化改编，不包含上游应用源码；上游 `NOTICE`（含第三方组件声明）随每个 Release 一并分发
- ONNX Runtime © Microsoft，Apache License 2.0
- OpenCV © OpenCV team，Apache License 2.0
- 适配版 APK 为上游应用源码的衍生作品，依据上游许可分发
