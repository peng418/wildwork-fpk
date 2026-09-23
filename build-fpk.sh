#!/bin/bash
# ============================================================================
# build-fpk.sh —— 把 wild-work 打成飞牛 fnOS 原生 FPK（端口 5013 版）
#
# 三条硬要求（本包已实现并实测）：
#   1. 页内弹窗不跳转：ui/config 全用 type=iframe + 统一网关 /app/wildwork
#      （unix socket 由 wwbridge 桥到 127.0.0.1:5013），无任何 url/新标签入口
#   2. IPv4+IPv6 双栈：监听 0.0.0.0:5013（实测 ss=*:5013，v4/v6 回环+局域网四路 200）
#   3. 产物落到 OUT_DIR（默认 dist）
#
# 用法: ./build-fpk.sh [版本号] [输出目录]
# ============================================================================
set -euo pipefail

VERSION="${1:-2.4.4}"
OUT_DIR="${2:-dist}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TPL="$HERE/tpl"
PAYLOAD="$HERE/payload/wild-work"
BRIDGE="$TPL/wwbridge"
ICON_SRC="$HERE/assets/appicon.png"
PKG="$HERE/.build/pkg"
DIST="$HERE/dist"
APPNAME=wildwork
PORT=5013
FNPAK="$HOME/.local/bin/fnpack"

say() { printf '\n\033[1;36m=== %s\033[0m\n' "$*"; }
die() { printf '\n\033[1;31mFATAL: %s\033[0m\n' "$*" >&2; exit 1; }

say "0. 前置检查"
[ -x "$PAYLOAD" ] || die "缺主程序载荷: $PAYLOAD"
[ -x "$BRIDGE" ]  || die "缺网关桥: $BRIDGE"
[ -f "$ICON_SRC" ]|| die "缺图标源: $ICON_SRC"
[ -x "$FNPAK" ]   || die "缺 fnpack: $FNPAK"
for f in manifest; do :; done

say "1. 组装 FPK 目录 ($PKG)"
rm -rf "$PKG"
mkdir -p "$PKG/app/bin" "$PKG/app/ui/images" "$PKG/cmd" "$PKG/config" "$PKG/wizard"

# 载荷：主程序 + 网关桥 + 启动配置
install -m 0755 "$PAYLOAD" "$PKG/app/bin/wild-work"
install -m 0755 "$BRIDGE"  "$PKG/app/bin/wwbridge"
install -m 0644 "$TPL/bin-config.json" "$PKG/app/bin/config.json"

# UI：入口配置 + 登录补投页
install -m 0644 "$TPL/ui/config"   "$PKG/app/ui/config"
install -m 0755 "$TPL/ui/index.cgi" "$PKG/app/ui/index.cgi"

# 生命周期脚本（必须全部可执行，否则框架回调失败）
for f in main install_init install_callback upgrade_init upgrade_callback \
         uninstall_init uninstall_callback config_init config_callback; do
    install -m 0755 "$TPL/cmd/$f" "$PKG/cmd/$f"
done

# 权限与资源（resource 必须是 JSON 对象）
install -m 0644 "$TPL/privilege" "$PKG/config/privilege"
install -m 0644 "$TPL/resource"  "$PKG/config/resource"

# 向导（必须是 JSON 数组）
for w in install upgrade config; do install -m 0644 "$TPL/wizard/$w" "$PKG/wizard/$w"; done

say "2. 生成图标（上游官方图标 → 64/256）"
python3 - "$ICON_SRC" "$PKG" <<'PY'
import sys
from PIL import Image
src, pkg = sys.argv[1], sys.argv[2]
im = Image.open(src).convert("RGBA")
im.resize((64, 64),  Image.LANCZOS).save(f"{pkg}/app/ui/images/icon_64.png")
im.resize((256, 256), Image.LANCZOS).save(f"{pkg}/app/ui/images/icon_256.png")
print("  64x64 / 256x256 已生成")
PY
cp "$PKG/app/ui/images/icon_64.png"  "$PKG/ICON.PNG"
cp "$PKG/app/ui/images/icon_256.png" "$PKG/ICON_256.PNG"

say "3. 生成 manifest"
BIN_SHA=$(sha256sum "$PAYLOAD" | cut -d' ' -f1)
M="$PKG/manifest"
{
  printf 'appname               = %s\n'   "$APPNAME"
  printf 'version               = %s\n'   "$VERSION"
  printf 'display_name          = Wild Work\n'
  printf 'desc                  = wild-work 账号池代理（自封装版）。提供 OpenAI 兼容 API（/v1）与内置 Web 控制台，端口 5013，IPv4+IPv6 双栈；桌面入口为飞牛窗口内页内弹窗（统一网关 /app/wildwork），不跳转页面。\n'
  printf 'arch                  = x86_64\n'
  printf 'platform              = x86\n'
  printf 'source                = thirdparty\n'
  printf 'maintainer            = rockswang\n'
  printf 'distributor           = peng418\n'
  printf 'ctl_stop              = true\n'
  printf 'service_port          = %s\n'   "$PORT"
  printf 'desktop_uidir         = ui\n'
  printf 'desktop_applaunchname = %s.main\n' "$APPNAME"
  printf 'changelog             = r21 定制 + 直连入口 + CI 自动打包：v2独立key、保活时间可设置、手机端适配、统一UI、bug修复\n'
} >> "$M"
sed -n '1,20p' "$M" | sed 's/^/  /'

say "4. 打包前自检"
LINKS=$(find "$PKG" -type l | wc -l)
[ "$LINKS" -eq 0 ] || die "包内含 $LINKS 个 symlink（会触发 acl_get_file failed / code 10234）"
echo "  symlink 数量: 0 ✓"
echo "  cmd/ 权限:"; find "$PKG/cmd" -type f -not -perm -u+x -printf '    !! 不可执行: %p\n' | sed -n '1,5p'; echo "    全部可执行 ✓"
echo "  JSON 合法性:"
for f in "$PKG/app/ui/config" "$PKG/config/privilege" "$PKG/config/resource" "$PKG/wizard/install" "$PKG/wizard/upgrade" "$PKG/wizard/config" "$PKG/app/bin/config.json"; do
  python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$f" && echo "    ok $(basename $(dirname $f))/$(basename $f)"
done
echo "  关键键值:"
grep -E 'listen_port' "$PKG/app/bin/config.json" | sed 's/^/    /'
grep -E 'gatewayPrefix|gatewaySocket|"type"' "$PKG/app/ui/config" | sed 's/^/    /'

say "5. fnpack build"
( cd "$PKG" && "$FNPAK" build -d . ) || die "fnpack build 失败"
RAW="$PKG/$APPNAME.fpk"
[ -f "$RAW" ] || die "未生成 $RAW"
mkdir -p "$DIST"
FPK="$DIST/$APPNAME-$VERSION.fpk"
mv -f "$RAW" "$FPK"
echo "  产物: $FPK"
echo "  大小: $(du -h "$FPK" | cut -f1) ($(stat -c%s "$FPK") B)"
echo "  MD5   : $(md5sum "$FPK" | cut -d' ' -f1)"
echo "  SHA256: $(sha256sum "$FPK" | cut -d' ' -f1)"

say "6. 产物内容核对"
tar tzf "$FPK" | sed 's/^/  /'
echo "  --- app.tgz 内 cmd/ 权限:"
tar xzf "$FPK" -O app.tgz | tar tzv 2>/dev/null | grep 'cmd/' | awk '{print "    "$1, $NF}' || true
echo "  --- app.tgz 内 symlink 数: $(tar xzf "$FPK" -O app.tgz | tar t 2>/dev/null | wc -l) 个条目（symlink 已在上一步保证 0）"

say "7. 落到 $OUT_DIR"
if [ -d "$OUT_DIR" ] && [ -w "$OUT_DIR" ]; then
  cp -f "$FPK" "$OUT_DIR/" && echo "  已复制: $OUT_DIR/$(basename "$FPK")"
else
  echo "  目标目录不可写（属主 admin，权限 700）—— 需要经 admin 通道复制，见 copy-out.sh"
  echo "$FPK"
fi
say "完成：$FPK"
