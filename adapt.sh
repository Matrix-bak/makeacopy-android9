#!/usr/bin/env bash
# ============================================================================
# MakeACopy 官方新版 → Android 9 适配脚本（GitHub Actions 版）
#
# 用法:
#   ./adapt.sh <官方tag> [--ci] [--skip-lint]
#
# 示例:
#   ./adapt.sh v4.7.0          # 本地运行（自动 clone 官方源码）
#   ./adapt.sh v4.7.0 --ci     # CI 运行（源码已 checkout 到 ./official）
#
# 环境变量:
#   KEYSTORE_B64        base64 编码的签名密钥（CI 用，来自 GitHub Secrets）
#   KEYSTORE_PASSWORD   密钥密码
#   KEYSTORE_ALIAS      密钥别名（默认 makeacopy）
#   OFFICIAL_SRC        官方源码目录（默认 ./official）
#
# 产物: ./output/MakeACopy-v<版本>-arm64-v8a-paddle-android9.apk
# ============================================================================
set -euo pipefail

TAG="${1:?用法: ./adapt.sh <官方tag> [--ci] [--skip-lint]}"
CI_MODE=0
SKIP_LINT=0
for arg in "$@"; do
  case "$arg" in
    --ci) CI_MODE=1 ;;
    --skip-lint) SKIP_LINT=1 ;;
  esac
done

VERSION="${TAG#v}"
ROOT="$(cd "$(dirname "$0")" && pwd)"
SRC="${OFFICIAL_SRC:-$ROOT/official}"
OUT="$ROOT/output"
KEYSTORE_FILE="$ROOT/keystore.jks"
ALIAS="${KEYSTORE_ALIAS:-makeacopy}"
PASS="${KEYSTORE_PASSWORD:-}"
OUT_APK="$OUT/MakeACopy-v${VERSION}-arm64-v8a-paddle-android9.apk"

info() { echo -e "\033[1;32m[INFO]\033[0m $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $*"; }
die()  { echo -e "\033[1;31m[FAIL]\033[0m $*" >&2; exit 1; }

mkdir -p "$OUT"

# ---------- 1. 准备官方源码 ----------
if [ "$CI_MODE" = "1" ]; then
  [ -d "$SRC/app" ] || die "CI 模式要求官方源码已 checkout 到 $SRC"
  info "使用 CI 提供的官方源码: $SRC"
else
  if [ ! -d "$SRC/.git" ]; then
    info "克隆官方源码 (${TAG}) ..."
    git clone --depth 1 --branch "$TAG" https://github.com/egdels/makeacopy.git "$SRC"
  else
    cd "$SRC" && git fetch --depth 1 origin tag "$TAG" 2>/dev/null || git fetch --depth 1 origin "$TAG"
    git checkout -f "$TAG"
    cd "$ROOT"
  fi
fi
cd "$SRC"

# ---------- 2. minSdk = 28 ----------
info "步骤 2/8: 设置 minSdk = 28 ..."
if grep -q 'minSdk = 29' app/build.gradle; then
  sed -i 's/minSdk = 29/minSdk = 28/' app/build.gradle
  info "minSdk 29 → 28"
elif grep -q 'minSdk = 28' app/build.gradle; then
  info "minSdk 已是 28"
else
  die "未找到 minSdk 配置，官方可能改写了构建配置，需人工介入"
fi

# ---------- 3. API 29 守卫补丁 ----------
info "步骤 3/8: 应用 API 29 版本守卫补丁 ..."
GUARD_FILE="app/src/main/java/de/schliweb/makeacopy/ui/crop/TrapezoidSelectionView.java"
[ -f "$GUARD_FILE" ] || die "找不到 $GUARD_FILE，官方可能重构了该文件，请人工适配"

python3 - "$GUARD_FILE" <<'PYEOF'
import sys, re
path = sys.argv[1]
src = open(path, encoding='utf-8').read()
orig = src
fixes = 0

def sub_once(pattern, repl, s):
    global fixes
    new, n = re.subn(pattern, repl, s, count=1)
    if n:
        fixes += 1
    return new

src = sub_once(
    r"if \(w <= 0 \|\| h <= 0\) \{\n(\s*)setSystemGestureExclusionRects\(java\.util\.Collections\.emptyList\(\)\);",
    r"if (w <= 0 || h <= 0) {\n\1if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {\n\1  setSystemGestureExclusionRects(java.util.Collections.emptyList());\n\1}",
    src)

src = sub_once(
    r"(\s*)setSystemGestureExclusionRects\(rects\);\n(\s*)lastExclusionRects = new java\.util\.ArrayList<>\(rects\);",
    r"\1if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {\n\1  setSystemGestureExclusionRects(rects);\n\1}\n\2lastExclusionRects = new java.util.ArrayList<>(rects);",
    src)

src = sub_once(
    r"(\s*)setSystemGestureExclusionRects\(rects\);\n(\s*)(// Keep a copy|lastExclusionRects)",
    r"\1if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {\n\1  setSystemGestureExclusionRects(rects);\n\1}\n\2\3",
    src)

src = sub_once(
    r"if \(magnifier == null && magnifierSourceView != null && magnifierEnabled\) \{\n(\s*)try \{",
    r"if (magnifier == null && magnifierSourceView != null && magnifierEnabled) {\n\1if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {\n\1  // Magnifier was added in API 29 (Android 10); unavailable on Android 9 and earlier.\n\1  return;\n\1}\n\1try {",
    src)

if fixes == 0 and orig == src:
    if 'VERSION_CODES.Q' in src:
        print('[INFO] 守卫已存在，跳过')
    else:
        import sys as _sys
        print('[FAIL] 补丁未能匹配，官方可能重构了该文件，请人工适配', file=_sys.stderr)
        _sys.exit(1)
elif orig != src:
    open(path, 'w', encoding='utf-8').write(src)
    print(f'[INFO] 补丁应用完成（{fixes} 处）')
PYEOF

# ---------- 4. 替换 ONNX Runtime + OpenCV 库 ----------
info "步骤 4/8: 替换 ORT/OpenCV 原生库 ..."
# 4a. 探测官方锁定的 ORT 版本
ORT_VER="$(grep -oP 'onnxruntime-\d+\.\d+\.\d+\.jar' scripts/build_onnxruntime_android.sh | head -1 | sed 's/onnxruntime-//;s/\.jar//')"
[ -n "$ORT_VER" ] || die "无法探测 ORT 版本"
info "官方锁定 ORT: ${ORT_VER}"

# 4b. 官方 ORT AAR → classes.jar + arm64 .so
AAR="$ROOT/cache/onnxruntime-android-${ORT_VER}.aar"
if [ ! -f "$AAR" ]; then
  mkdir -p "$ROOT/cache"
  curl -sL -o "$AAR" "https://repo1.maven.org/maven2/com/microsoft/onnxruntime/onnxruntime-android/${ORT_VER}/onnxruntime-android-${ORT_VER}.aar"
fi
[ -s "$AAR" ] || die "ORT AAR 下载失败"
AAR_DIR="$ROOT/cache/ort-${ORT_VER}"
rm -rf "$AAR_DIR" && mkdir -p "$AAR_DIR"
unzip -o -q "$AAR" -d "$AAR_DIR" "classes.jar" "jni/arm64-v8a/*"
mkdir -p app/libs app/src/main/jniLibs/arm64-v8a
cp -f "$AAR_DIR/classes.jar" "app/libs/onnxruntime-${ORT_VER}.jar"
cp -f "$AAR_DIR/jni/arm64-v8a/libonnxruntime.so" "$AAR_DIR/jni/arm64-v8a/libonnxruntime4j_jni.so" app/src/main/jniLibs/arm64-v8a/
info "ORT 官方库已就位"

# 4c. 官方新版 APK → OpenCV 库
OFFICIAL_APK="$ROOT/cache/official-${TAG}-arm64-paddle.apk"
if [ ! -f "$OFFICIAL_APK" ]; then
  curl -sL -o "$OFFICIAL_APK" "https://github.com/egdels/makeacopy/releases/download/${TAG}/MakeACopy-v${VERSION}-arm64-v8a-paddle-release.apk"
fi
[ -s "$OFFICIAL_APK" ] || die "官方 APK 下载失败，检查 release 资源名"
mkdir -p "$ROOT/cache/opencv-${TAG}" && cd "$ROOT/cache/opencv-${TAG}"
unzip -o -q "$OFFICIAL_APK" "lib/arm64-v8a/libopencv*.so"
cd "$SRC"
cp -f "$ROOT"/cache/opencv-${TAG}/lib/arm64-v8a/libopencv*.so app/src/main/jniLibs/arm64-v8a/
info "OpenCV 库已从官方 ${TAG} APK 提取"

# ---------- 5. Gradle 构建 ----------
info "步骤 5/8: Gradle 构建 ..."
# CI 环境下 sdkmanager 已在 PATH，这里确保 licenses 已接受
if command -v sdkmanager >/dev/null 2>&1; then
  yes | sdkmanager --licenses >/dev/null 2>&1 || true
fi
./gradlew :app:assemblePaddleRelease -PABIS=arm64-v8a --console=plain 2>&1 | tail -5 || die "构建失败"

UNSIGNED="app/build/outputs/apk/paddle/release/app-paddle-arm64-v8a-release-unsigned.apk"
[ -f "$UNSIGNED" ] || die "未找到构建产物"

# ---------- 6. lint 校验 ----------
if [ "$SKIP_LINT" = "1" ]; then
  warn "已跳过 lint"
else
  info "步骤 6/8: lint 检查 ..."
  ./gradlew :app:lintPaddleRelease --console=plain >/dev/null 2>&1 || true
  LINT_REPORT="app/build/intermediates/lint_intermediate_text_report/paddleRelease/lintReportPaddleRelease/lint-results-paddleRelease.txt"
  if [ -f "$LINT_REPORT" ]; then
    ERRORS="$(grep -c 'Error:' "$LINT_REPORT" || true)"
    if [ "$ERRORS" != "0" ]; then
      warn "lint 发现 ${ERRORS} 个错误，需人工修复："
      grep -B1 'Error:' "$LINT_REPORT" | grep -E '\.java:' | head -20
      die "lint 存在错误，已停止"
    fi
    info "lint 0 错误 ✓"
  fi
fi

# ---------- 7. 签名 ----------
info "步骤 7/8: 签名 ..."
BT="$(dirname "$(command -v zipalign 2>/dev/null || true)")"
if [ -z "${BT:-}" ] || [ ! -x "$BT/zipalign" ]; then
  BT="${ANDROID_HOME:-}/build-tools/36.0.0"
fi
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
info "签名完成: $OUT_APK"

# ---------- 8. 验证 ----------
info "步骤 8/8: 验证 ..."
"$BT/apksigner" verify --verbose "$OUT_APK" | grep -q "Verified using v3" || die "签名验证失败"
BADGING="$("$BT/aapt" dump badging "$OUT_APK" | grep -E '^package|sdkVersion|native-code')"
echo "$BADGING"
echo "$BADGING" | grep -q "sdkVersion:'28'" || die "minSdk 不是 28"
echo "$BADGING" | grep -q "arm64-v8a" || die "ABI 错误"
unzip -p "$OUT_APK" lib/arm64-v8a/libonnxruntime.so > "$ROOT/.check-ort.so"
if readelf -sW "$ROOT/.check-ort.so" | grep -q "android_get_device_api_level"; then
  rm -f "$ROOT/.check-ort.so"
  die "ORT 库仍引用 Android 10 专属符号，适配失败！"
fi
rm -f "$ROOT/.check-ort.so"
info "ORT 库无 Android 10 专属符号 ✓"

echo ""
echo "==================== 适配完成 ===================="
echo "  产物: $OUT_APK"
echo "  版本: v${VERSION} (minSdk 28 / arm64-v8a)"
echo "=================================================="
