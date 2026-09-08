#!/usr/bin/env bash
# ============================================================================
# MakeACopy 官方新版 → Android 9 适配脚本（GitHub Actions 版）
#
# 用法:
#   ./adapt.sh <官方tag> [--ci] [--skip-lint] [--allow-prerelease]
#
# 示例:
#   ./adapt.sh v4.6.1          # 本地运行（自动 clone 官方源码）
#   ./adapt.sh v4.6.1 --ci     # CI 运行（源码已 checkout 到 ./official）
#
# 环境变量:
#   KEYSTORE_B64        base64 编码的签名密钥（CI 用，来自 GitHub Secrets）
#   KEYSTORE_PASSWORD   密钥密码
#   KEYSTORE_ALIAS      密钥别名（默认 makeacopy）
#   OFFICIAL_SRC        官方源码目录（默认 ./official）
#   ALLOW_PRERELEASE=1  允许适配 rc/beta/alpha 预发布版本（默认拒绝）
#
# 产物: ./output/ 下的适配 APK、.sha256、上游 NOTICE
# ============================================================================
set -euo pipefail

TAG="${1:?用法: ./adapt.sh <官方tag> [--ci] [--skip-lint]}"
CI_MODE=0
SKIP_LINT=0
for arg in "$@"; do
  case "$arg" in
    --ci) CI_MODE=1 ;;
    --skip-lint) SKIP_LINT=1 ;;
    --allow-prerelease) export ALLOW_PRERELEASE=1 ;;
  esac
done

VERSION="${TAG#v}"
ROOT="$(cd "$(dirname "$0")" && pwd)"
SRC="${OFFICIAL_SRC:-$ROOT/official}"
OUT="$ROOT/output"
CACHE="$ROOT/cache"
KEYSTORE_FILE="$ROOT/keystore.jks"
ALIAS="${KEYSTORE_ALIAS:-makeacopy}"
PASS="${KEYSTORE_PASSWORD:-}"
OUT_APK="$OUT/MakeACopy-v${VERSION}-arm64-v8a-paddle-android9.apk"
BUILD_LOG="$ROOT/build.log"

info() { echo -e "\033[1;32m[INFO]\033[0m $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $*"; }
die()  { echo -e "\033[1;31m[FAIL]\033[0m $*" >&2; exit 1; }

# 带失败即退的下载（-f: 404 直接失败；-S: 保留错误信息）
download() {
  local url="$1" dest="$2"
  curl -fsSL --retry 3 --retry-delay 2 -o "$dest" "$url" || die "下载失败: $url"
  [ -s "$dest" ] || die "下载结果为空: $url"
}

mkdir -p "$OUT" "$CACHE"

# ---------- 0. 拒绝预发布版本（rc/beta/alpha 不是正式版）----------
if [[ "$TAG" =~ -(rc|beta|alpha|pre|dev|m)[0-9]* ]] && [ "${ALLOW_PRERELEASE:-0}" != "1" ]; then
  die "预发布版本 $TAG 默认不适配（正式版才跟进）；如确需适配请加 --allow-prerelease"
fi

# ---------- 1. 准备官方源码 ----------
if [ "$CI_MODE" = "1" ]; then
  [ -d "$SRC/app" ] || die "CI 模式要求官方源码已 checkout 到 $SRC"
  info "使用 CI 提供的官方源码: $SRC"
else
  if [ ! -d "$SRC/.git" ]; then
    info "克隆官方源码 (${TAG}) ..."
    git clone --depth 1 --branch "$TAG" https://github.com/egdels/makeacopy.git "$SRC"
  else
    cd "$SRC"
    git fetch --depth 1 origin tag "$TAG" 2>/dev/null || git fetch --depth 1 origin "$TAG"
    git checkout -f "$TAG"
    cd "$ROOT"
  fi
fi
cd "$SRC"

# ---------- 2. minSdk = 28 + versionName 加后缀 ----------
info "步骤 2/8: 设置 minSdk = 28、versionName 后缀 ..."
if grep -q 'minSdk = 29' app/build.gradle; then
  sed -i 's/minSdk = 29/minSdk = 28/' app/build.gradle
  info "minSdk 29 → 28"
elif grep -q 'minSdk = 28' app/build.gradle; then
  info "minSdk 已是 28"
else
  die "未找到 minSdk 配置，官方可能改写了构建配置，需人工介入"
fi
# versionName "x.y.z" → "x.y.z-android9"（幂等，不重复加后缀）
if grep -qE 'versionName "[0-9]+\.[0-9]+\.[0-9]+"' app/build.gradle; then
  sed -i -E 's/(versionName "[0-9]+\.[0-9]+\.[0-9]+)"/\1-android9"/' app/build.gradle
  info "versionName 已加 -android9 后缀: $(grep -E 'versionName ' app/build.gradle | head -1 | tr -d ' ')"
else
  warn "未匹配到 defaultConfig versionName，跳过后缀（请人工确认）"
fi

# ---------- 3. API 29 守卫补丁（硬断言命中数，禁止部分命中放行）----------
info "步骤 3/8: 应用 API 29 版本守卫补丁 ..."
GUARD_FILE="app/src/main/java/de/schliweb/makeacopy/ui/crop/TrapezoidSelectionView.java"
[ -f "$GUARD_FILE" ] || die "找不到 $GUARD_FILE，官方可能重构了该文件，请人工适配"

python3 - "$GUARD_FILE" <<'PYEOF'
import sys, re
path = sys.argv[1]
src = open(path, encoding='utf-8').read()
orig = src

# (规则名, 正则, 替换) —— 4 个补丁点共同保护 8 处 Android 10(API29) 调用：
#   setSystemGestureExclusionRects ×3
#   放大镜块内 Magnifier.Builder/setInitialZoom/setSize/setDefaultSourceToMagnifierOffset/build ×5
EXPECTED = 4
rules = [
    ("gesture-empty",
     r"if \(w <= 0 \|\| h <= 0\) \{\n(\s*)setSystemGestureExclusionRects\(java\.util\.Collections\.emptyList\(\)\);",
     r"if (w <= 0 || h <= 0) {\n\1if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {\n\1  setSystemGestureExclusionRects(java.util.Collections.emptyList());\n\1}"),
    ("gesture-rects-a",
     r"(\s*)setSystemGestureExclusionRects\(rects\);\n(\s*)lastExclusionRects = new java\.util\.ArrayList<>\(rects\);",
     r"\1if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {\n\1  setSystemGestureExclusionRects(rects);\n\1}\n\2lastExclusionRects = new java.util.ArrayList<>(rects);"),
    ("gesture-rects-b",
     r"(\s*)setSystemGestureExclusionRects\(rects\);\n(\s*)(// Keep a copy|lastExclusionRects)",
     r"\1if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {\n\1  setSystemGestureExclusionRects(rects);\n\1}\n\2\3"),
    ("magnifier",
     r"if \(magnifier == null && magnifierSourceView != null && magnifierEnabled\) \{\n(\s*)try \{",
     r"if (magnifier == null && magnifierSourceView != null && magnifierEnabled) {\n\1if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {\n\1  // Magnifier was added in API 29 (Android 10); unavailable on Android 9 and earlier.\n\1  return;\n\1}\n\1try {"),
]

matched, missed = [], []
for name, pat, repl in rules:
    new, n = re.subn(pat, repl, src, count=1)
    if n:
        src = new
        matched.append(name)
    else:
        missed.append(name)

if len(matched) == EXPECTED:
    open(path, 'w', encoding='utf-8').write(src)
    print(f'[INFO] 补丁应用完成（{EXPECTED}/{EXPECTED} 个补丁点）')
elif not matched and 'VERSION_CODES.Q' in orig:
    print('[INFO] 守卫均已存在（上游可能已自行修复），跳过')
else:
    print(f'[FAIL] 补丁仅命中 {len(matched)}/{EXPECTED}：已命中 {matched}，未命中 {missed}', file=sys.stderr)
    print('[FAIL] 上游源码结构已变化，禁止带残缺补丁继续构建，请人工适配', file=sys.stderr)
    sys.exit(1)
PYEOF

# ---------- 4. 替换 ONNX Runtime + OpenCV 库 ----------
info "步骤 4/8: 替换 ORT/OpenCV 原生库 ..."
# 4a. 探测官方锁定的 ORT 版本（用 POSIX ERE，兼容 macOS BSD grep）
ORT_VER="$(grep -oE 'onnxruntime-[0-9]+\.[0-9]+\.[0-9]+\.jar' scripts/build_onnxruntime_android.sh | head -1 | sed 's/onnxruntime-//;s/\.jar//')"
[ -n "$ORT_VER" ] || die "无法探测 ORT 版本"
info "官方锁定 ORT: ${ORT_VER}"

# 4b. 微软官方 ORT AAR → classes.jar + arm64 .so（含 sha1 完整性校验）
ORT_BASE="https://repo1.maven.org/maven2/com/microsoft/onnxruntime/onnxruntime-android/${ORT_VER}"
AAR="$CACHE/onnxruntime-android-${ORT_VER}.aar"
if [ ! -f "$AAR" ]; then
  download "$ORT_BASE/onnxruntime-android-${ORT_VER}.aar" "$AAR"
fi
download "$ORT_BASE/onnxruntime-android-${ORT_VER}.aar.sha1" "$CACHE/ort.sha1"
WANT_SHA="$(tr -d ' \n\r\t' < "$CACHE/ort.sha1")"
GOT_SHA="$(sha1sum "$AAR" | awk '{print $1}')"
[ "$WANT_SHA" = "$GOT_SHA" ] || die "ORT AAR sha1 不符（期望 $WANT_SHA 实际 $GOT_SHA），文件可能被截断"
info "ORT AAR sha1 校验通过"

AAR_DIR="$CACHE/ort-${ORT_VER}"
rm -rf "$AAR_DIR" && mkdir -p "$AAR_DIR"
unzip -o -q "$AAR" -d "$AAR_DIR" "classes.jar" "jni/arm64-v8a/*" \
  || die "ORT AAR 解压失败（${ORT_VER}），检查 Maven 上是否存在该版本"
[ -f "$AAR_DIR/classes.jar" ] || die "ORT AAR 内缺少 classes.jar"
[ -f "$AAR_DIR/jni/arm64-v8a/libonnxruntime.so" ] || die "ORT AAR 内缺少 arm64-v8a 原生库"
mkdir -p app/libs app/src/main/jniLibs/arm64-v8a
cp -f "$AAR_DIR/classes.jar" "app/libs/onnxruntime-${ORT_VER}.jar"
cp -f "$AAR_DIR/jni/arm64-v8a/libonnxruntime.so" "$AAR_DIR/jni/arm64-v8a/libonnxruntime4j_jni.so" app/src/main/jniLibs/arm64-v8a/
info "ORT 官方库已就位（完整版，体积大于官方 minimal_build，换取全算子覆盖）"

# 4c. 官方新版 APK → OpenCV 库
OFFICIAL_APK="$CACHE/official-${TAG}-arm64-paddle.apk"
if [ ! -f "$OFFICIAL_APK" ]; then
  download "https://github.com/egdels/makeacopy/releases/download/${TAG}/MakeACopy-v${VERSION}-arm64-v8a-paddle-release.apk" "$OFFICIAL_APK"
fi
OCV_DIR="$CACHE/opencv-${TAG}"
rm -rf "$OCV_DIR" && mkdir -p "$OCV_DIR"
( cd "$OCV_DIR" && unzip -o -q "$OFFICIAL_APK" "lib/arm64-v8a/libopencv*.so" ) \
  || die "从官方 APK 提取 OpenCV 失败，检查 release 资产名是否变化"
ls "$OCV_DIR"/lib/arm64-v8a/libopencv*.so >/dev/null 2>&1 || die "官方 APK 内未找到 libopencv*.so"
cp -f "$OCV_DIR"/lib/arm64-v8a/libopencv*.so app/src/main/jniLibs/arm64-v8a/
info "OpenCV 库已从官方 ${TAG} APK 提取"

# ---------- 5. Gradle 构建（日志 tee 留存，便于排错）----------
info "步骤 5/8: Gradle 构建 ..."
if command -v sdkmanager >/dev/null 2>&1; then
  yes | sdkmanager --licenses >/dev/null 2>&1 || true
fi
# pipefail 已开启：gradlew 失败时整条管道失败；完整日志写入 build.log
./gradlew :app:assemblePaddleRelease -PABIS=arm64-v8a --console=plain 2>&1 | tee "$BUILD_LOG" | tail -20 \
  || die "构建失败（完整日志见 build.log）"

UNSIGNED="app/build/outputs/apk/paddle/release/app-paddle-arm64-v8a-release-unsigned.apk"
[ -f "$UNSIGNED" ] || die "未找到构建产物"

# ---------- 6. NewApi 专属 lint 闸门（全项目兜底，不只看单个文件）----------
if [ "$SKIP_LINT" = "1" ]; then
  warn "已跳过 lint（不推荐：NewApi 是防止漏加版本守卫的核心闸门）"
else
  info "步骤 6/8: NewApi lint 闸门 ..."
  # lint 任务发现 fatal 级问题会非零退出，这里不让它直接中断，改由我们解析报告
  ./gradlew :app:lintPaddleRelease --console=plain 2>&1 | tee -a "$BUILD_LOG" | tail -10 || true

  mapfile -t REPORTS < <(find app/build -type f \( -name 'lint-results-*.txt' -o -name 'lint-results-*.xml' \) 2>/dev/null)
  [ "${#REPORTS[@]}" -gt 0 ] || die "未找到任何 lint 报告，闸门无法确认，禁止放行（请检查 AGP 报告路径是否变化）"

  NEWAPI_HITS=""
  for r in "${REPORTS[@]}"; do
    # 文本报告: [NewApi]；XML 报告: id="NewApi"
    H="$(grep -F -e '[NewApi]' -e 'id="NewApi"' "$r" 2>/dev/null || true)"
    [ -z "$H" ] || NEWAPI_HITS="${NEWAPI_HITS}"$'\n'"${H}"
  done
  if [ -n "$NEWAPI_HITS" ]; then
    echo "$NEWAPI_HITS" | head -30 >&2
    die "发现未加版本守卫的高版本 API 调用（NewApi），禁止在 Android 9 上发布，请补守卫"
  fi
  # 其它类型 lint 错误不阻断（上游可能有自己的历史 lint 债），仅计数提示
  OTHER="$(grep -h -c 'Error:' "${REPORTS[@]}" 2>/dev/null | awk '{s+=$1} END{print s+0}')"
  if [ "$OTHER" = "0" ]; then
    info "NewApi 闸门通过，无其它 lint 错误 ✓"
  else
    warn "NewApi 闸门通过；另有 ${OTHER} 条非 NewApi lint 问题，不阻断"
  fi
fi

# ---------- 7. 签名 ----------
info "步骤 7/8: 签名 ..."
# 动态定位 build-tools：优先 PATH，其次取 SDK 下最新版本目录（不写死版本号）
BT=""
if command -v zipalign >/dev/null 2>&1; then BT="$(dirname "$(command -v zipalign)")"; fi
if [ -z "$BT" ] || [ ! -x "$BT/zipalign" ]; then
  SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
  BT="$(find "$SDK" -mindepth 2 -maxdepth 2 -type d -path '*/build-tools/*' 2>/dev/null | sort -V | tail -1)"
fi
if [ -z "$BT" ] || [ ! -x "$BT/zipalign" ] || [ ! -x "$BT/apksigner" ]; then
  die "找不到 build-tools（zipalign/apksigner）"
fi
info "使用 build-tools: $BT"

if [ -n "${KEYSTORE_B64:-}" ]; then
  echo "$KEYSTORE_B64" | base64 -d > "$KEYSTORE_FILE"
  info "密钥已从环境变量解码"
fi
[ -f "$KEYSTORE_FILE" ] || die "缺少密钥文件 keystore.jks（或 KEYSTORE_B64）"
[ -n "$PASS" ] || die "缺少密钥密码（KEYSTORE_PASSWORD）"

"$BT/zipalign" -f -p 4 "$UNSIGNED" "$ROOT/app-aligned.apk"
"$BT/apksigner" sign --ks "$KEYSTORE_FILE" --ks-key-alias "$ALIAS" \
  --ks-pass "pass:$PASS" --key-pass "pass:$PASS" \
  --out "$OUT_APK" "$ROOT/app-aligned.apk"
rm -f "$ROOT/app-aligned.apk"
info "签名完成: $OUT_APK"

# ---------- 8. 验证（签名模拟 + 全 so 版本符号扫描 + 清单核验）----------
info "步骤 8/8: 验证 ..."
# 8a. 以 Android 9 (API 28) 的平台级别模拟签名校验，比 grep "v3" 更贴近真机
"$BT/apksigner" verify --min-sdk-version 28 --verbose "$OUT_APK" >/dev/null \
  || die "签名在 API 28 平台级别校验失败"
info "签名 API28 平台校验通过 ✓"

# 8b. 清单：包名 / minSdk=28 / 仅 arm64-v8a（aapt2 与 aapt 输出格式一致）
BADGING="$("$BT/aapt2" dump badging "$OUT_APK" | grep -E '^package|sdkVersion|native-code')"
echo "$BADGING"
echo "$BADGING" | grep -q "sdkVersion:'28'" || die "minSdk 不是 28"
echo "$BADGING" | grep -q "arm64-v8a" || die "ABI 错误"
if echo "$BADGING" | grep -qE 'native-code:.*(x86|armeabi)'; then
  die "混入了非 arm64-v8a 的 ABI"
fi
info "minSdk/ABI 核验通过 ✓"

# 8c. 对 APK 内【全部】so 扫描 Android 10+ 版本化 libc 符号（@LIBC_Q 及以上）
#     @LIBC_P(API28) 及以下安全；Q=29、R=30…… 一律拦截
SYM_BAD=0
while IFS= read -r so; do
  [ -z "$so" ] && continue
  unzip -p "$OUT_APK" "$so" > "$ROOT/.check.so"
  HIT="$(readelf -sW "$ROOT/.check.so" | grep -E '@LIB[A-Za-z]+_[Q-Z]([^A-Za-z]|$)' || true)"
  if [ -n "$HIT" ]; then
    echo "[FAIL] $so 引用 Android 10+ 版本化符号:" >&2
    echo "$HIT" >&2
    SYM_BAD=1
  fi
done < <(unzip -Z1 "$OUT_APK" 'lib/arm64-v8a/*.so')
rm -f "$ROOT/.check.so"
[ "$SYM_BAD" = 0 ] || die "存在引用 Android 10+ 符号的原生库，Android 9 必闪退"
info "全部原生库无 Android 10+ 版本化符号 ✓"

# 8d. 生成 sha256、携带上游 NOTICE（Apache-2.0 合规）
( cd "$OUT" && sha256sum "$(basename "$OUT_APK")" > "$(basename "$OUT_APK").sha256" )
info "sha256 已生成: $(basename "$OUT_APK").sha256"
if [ -f "$SRC/NOTICE" ]; then
  cp -f "$SRC/NOTICE" "$OUT/NOTICE"
  info "已携带上游 NOTICE 文件"
fi

echo ""
echo "==================== 适配完成 ===================="
echo "  产物: $OUT_APK"
echo "  版本: v${VERSION}-android9 (minSdk 28 / arm64-v8a)"
echo "=================================================="
