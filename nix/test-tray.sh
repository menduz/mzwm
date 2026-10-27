# Tests the collapsed tray (tray.collapse): the bar shows only the items with
# a symbolic icon and the items that need attention, and all items while the
# pointer is on the tray. Run it with the environment of `kwm-test-tray` in
# tests.nix. Refer to src/kwm/tray_collapse.zig.
#
# The items of test-tray.py have the icons of a small hicolor theme in the
# home of the test: a symbolic square (drawn in the color of the text,
# #a1a1a1), a red square and a green square.
#
# Usage: kwm-test-tray
set -euo pipefail

TEST_NAME=tray

# config.def.zon with the collapsed tray and the hicolor icon theme.
TEST_KWM_CONFIG=$(sed -e 's/\.collapse = false,/.collapse = true,/' \
  -e 's/\.icon_theme = "Adwaita",/.icon_theme = "hicolor",/' "$TEST_DEFAULT_CONFIG")
grep -q '\.collapse = true,' <<<"$TEST_KWM_CONFIG"

# shellcheck source=test-lib.sh
source "$TEST_LIB"

icons=$HOME/.local/share/icons/hicolor
mkdir -p "$icons/scalable/apps"
cat >"$icons/index.theme" <<'EOF'
[Icon Theme]
Name=Hicolor
Directories=scalable/apps

[scalable/apps]
Size=16
MinSize=1
MaxSize=512
Type=Scalable
EOF
square_svg() {
  printf '<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16"><rect width="16" height="16" fill="#%s"/></svg>\n' "$1"
}
square_svg 000000 >"$icons/scalable/apps/netsym-symbolic.svg"
square_svg ff0000 >"$icons/scalable/apps/colorapp.svg"
square_svg 00ff00 >"$icons/scalable/apps/attn.svg"
square_svg 0000ff >"$icons/scalable/apps/blue.svg"

mkfifo "$work/tray"
python3 "$TEST_TRAY" "$work/tray" netsym:netsym:Active colorapp:colorapp:Active attn:attn:Active &
pids+=("$!")
exec {tray_fd}>"$work/tray"

start_input

# square <png> <rrggbb>: the left end of a square of 12 x 12 pixels of the
# color in the right part of the bar, or "none". Text has no such square.
square() {
  python3 - "$1" "$2" <<'PY'
import sys
from PIL import Image
image = Image.open(sys.argv[1]).convert("RGB")
color = tuple(int(sys.argv[2][i:i + 2], 16) for i in (0, 2, 4))
pixels = image.load()
width = image.size[0]
for x in range(width // 2, width - 11):
    for y in range(0, 10):
        if all(pixels[x + dx, y + dy] == color for dx in range(12) for dy in range(12)):
            print(x)
            sys.exit()
print("none")
PY
}

# box <png> <rrggbb> <x>: "<width> <height> <2 * middle y>" of the pixels of
# the color from 4 pixels before <x> to 20 pixels after it, or "none". The
# text can have the color of a symbolic icon: it is not in this area.
box() {
  python3 - "$1" "$2" "$3" <<'PY'
import sys
from PIL import Image
image = Image.open(sys.argv[1]).convert("RGB")
color = tuple(int(sys.argv[2][i:i + 2], 16) for i in (0, 2, 4))
start = int(sys.argv[3])
pixels = image.load()
width, height = image.size
points = [(x, y) for x in range(max(0, start - 4), min(width, start + 20)) for y in range(min(height, 40)) if pixels[x, y] == color]
if not points:
    print("none")
    sys.exit()
xs = [p[0] for p in points]
ys = [p[1] for p in points]
print(max(xs) - min(xs) + 1, max(ys) - min(ys) + 1, min(ys) + max(ys) + 1)
PY
}

# expect_tray <description> <symbolic> <red> <green>: each value is "yes" or
# "no": the bar shows that square, within 5 seconds.
expect_tray() {
  local got=""
  for _ in $(seq 25); do
    grim "$work/bar.png"
    local s r g
    s=$(square "$work/bar.png" a1a1a1)
    r=$(square "$work/bar.png" ff0000)
    g=$(square "$work/bar.png" 00ff00)
    got="symbolic $([ "$s" = none ] && echo no || echo yes) red $([ "$r" = none ] && echo no || echo yes) green $([ "$g" = none ] && echo no || echo yes)"
    if [ "$got" = "symbolic $2 red $3 green $4" ]; then
      echo "ok: $1"
      return
    fi
    sleep 0.2
  done
  echo "FAIL: $1 ($got)"
  failed=1
}

# expect_one <description>: the bar shows exactly one of the two colored
# squares, at the place of the symbolic item, within 5 seconds. A regular
# icon is 1 pixel larger on each side than the symbolic icon.
# shown_color is "red" or "green".
expect_one() {
  local r g
  for _ in $(seq 25); do
    grim "$work/bar.png"
    r=$(square "$work/bar.png" ff0000)
    g=$(square "$work/bar.png" 00ff00)
    if [ "$r" = "$((symbolic_x - 1))" ] && [ "$g" = none ]; then shown_color=red; echo "ok: $1"; return; fi
    if [ "$g" = "$((symbolic_x - 1))" ] && [ "$r" = none ]; then shown_color=green; echo "ok: $1"; return; fi
    sleep 0.2
  done
  echo "FAIL: $1 (red at $r, green at $g, not one of them at $((symbolic_x - 1)))"
  shown_color=none
  failed=1
}

expect_tray "collapsed, the bar shows only the symbolic item" yes no no
grim "$work/bar.png"
symbolic_x=$(square "$work/bar.png" a1a1a1)

input move $((symbolic_x + 6)) 8
expect_tray "the pointer on the tray shows all items" yes yes yes
grim "$work/bar.png"
if [ "$(square "$work/bar.png" a1a1a1)" = "$symbolic_x" ]; then
  echo "ok: the symbolic item stays under the pointer"
else
  echo "FAIL: the symbolic item stays under the pointer (at $(square "$work/bar.png" a1a1a1), not $symbolic_x)"
  failed=1
fi

# A regular icon is 16 pixels and a symbolic icon is 14 pixels (scale 1),
# on the same middle line.
symbolic_box=$(box "$work/bar.png" a1a1a1 "$symbolic_x")
red_box=$(box "$work/bar.png" ff0000 "$(square "$work/bar.png" ff0000)")
read -r _ _ symbolic_middle <<<"$symbolic_box"
read -r _ _ red_middle <<<"$red_box"
if [ "${symbolic_box% *}" = "14 14" ] && [ "${red_box% *}" = "16 16" ] && [ "$symbolic_middle" = "$red_middle" ]; then
  echo "ok: the symbolic icon is 2 pixels smaller, on the same middle line"
else
  echo "FAIL: the symbolic icon is 2 pixels smaller, on the same middle line (symbolic: $symbolic_box, regular: $red_box)"
  failed=1
fi

input move 640 400
expect_tray "the pointer away from the tray hides the items again" yes no no

echo "status attn NeedsAttention" >&"$tray_fd"
expect_tray "an item that needs attention shows while the tray is collapsed" yes no yes
echo "status attn Active" >&"$tray_fd"
expect_tray "after the attention, the item hides again" yes no no

# Without a symbolic item and without an item that needs attention, the bar
# shows the last item, in the place of the symbolic item, so the pointer has
# an item to go to.
echo "remove netsym" >&"$tray_fd"
expect_one "without a symbolic item, the bar shows only the last item"
last=$shown_color
input move $((symbolic_x + 6)) 8
expect_tray "the pointer on the last item shows all items" no yes yes
input move 640 400
expect_one "away from the tray, only the last item again"
if [ "$shown_color" = "$last" ]; then
  echo "ok: the same item stays the last item"
else
  echo "FAIL: the same item stays the last item ($shown_color, not $last)"
  failed=1
fi
# An item that needs attention is an item to go to: the tray collapses to it.
echo "status attn NeedsAttention" >&"$tray_fd"
expect_tray "with an item that needs attention, the tray shows only that item" no no yes
echo "status attn Active" >&"$tray_fd"
expect_one "after the attention, only the last item again"

# An item that needs attention, with a hidden item after it in the order
# (the items of the test have one program name, thus the order is by id:
# zz, colorapp, attn). The pointer on its icon shows all items, and the
# icon stays under the pointer: else a click goes to another item. The
# items that stay come at the right end of the order (shown_before).
echo "add sym2:netsym:Active" >&"$tray_fd"
echo "add zz:blue:NeedsAttention" >&"$tray_fd"
for _ in $(seq 25); do
  grim "$work/bar.png"
  blue_x=$(square "$work/bar.png" 0000ff)
  [ "$blue_x" != none ] && [ "$(square "$work/bar.png" ff0000)" = none ] && break
  sleep 0.2
done
input move $((blue_x + 6)) 8
expect_tray "the pointer on the item that needs attention shows all items" yes yes yes
grim "$work/bar.png"
if [ "$(square "$work/bar.png" 0000ff)" = "$blue_x" ]; then
  echo "ok: the item that needs attention stays under the pointer"
else
  echo "FAIL: the item that needs attention stays under the pointer (at $(square "$work/bar.png" 0000ff), not $blue_x)"
  failed=1
fi
input move 640 400

if [ "$failed" -ne 0 ]; then
  echo "kwm-test-tray: the log of kwm:" >&2
  grep -E "tray|icons" "$work/river.log" | tail -40 >&2 || true
  exit 1
fi
echo "kwm-test-tray: all tests passed"
