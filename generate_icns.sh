ICON_SRC="crates/tillandsias-macos-tray/assets/icon.png"
ICONSET="icon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 64 128 256 512; do
  sips -z $size $size "$ICON_SRC" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  sips -z $((size*2)) $((size*2)) "$ICON_SRC" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "crates/tillandsias-macos-tray/assets/icon.icns"
rm -rf "$ICONSET"
