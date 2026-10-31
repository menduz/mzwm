# Tests the layout of the selected tag: the mark of the selected tag shows
# the layout, the pointer on the selected tag shows the menu of the layouts,
# a click on a line of the menu selects the layout, and a quick second press
# of Super+1 on tag 1 goes to the next layout. Run it with the environment of
# `kwm-test-layout-menu` in tests.nix. Refer to src/kwm/tag_mark.zig and
# src/kwm/layout_cycle.zig.
#
# Usage: kwm-test-layout-menu
#
# With TEST_SCREENSHOT_DIR, the test writes there the mark of each layout
# (mark-<layout>.png, 8 times larger) and the menu (menu.png, 4 times
# larger).
set -euo pipefail

TEST_NAME=layout-menu

# config.def.zon with no delay for the tooltip.
TEST_KWM_CONFIG=$(sed "s|^        .tooltip_delay = 500,|        .tooltip_delay = 0,|" "$TEST_DEFAULT_CONFIG")
if ! grep -q "^        .tooltip_delay = 0," <<<"$TEST_KWM_CONFIG"; then
  echo "kwm-test-layout-menu: config.def.zon has no tooltip_delay line" >&2
  exit 1
fi

# shellcheck source=test-lib.sh
source "$TEST_LIB"

start_input

open a
open b
expect_state a " tiled=1 " "window a is tiled"
expect_state b " tiled=1 " "window b is tiled"

# mark <png> [name]: the widths of the runs of pixels of the mark in its
# middle row, for example "5 4" for two columns. The mark is in the cell of
# tag 1, at the left end of the bar. With a name and TEST_SCREENSHOT_DIR,
# also write the mark 8 times larger.
mark() {
  python3 - "$1" "${2:-}" "${TEST_SCREENSHOT_DIR:-}" <<'PY'
import sys
from PIL import Image
image = Image.open(sys.argv[1]).convert("RGB")
pixels = image.load()
bg = pixels[0, 0]
# The rows of the bar: the screen below the bar has other colors.
bar = next(y for y in range(image.size[1]) if pixels[0, y] != bg)
points = [(x, y) for x in range(0, 18) for y in range(0, bar) if pixels[x, y] != bg]
if not points:
    print("none")
    sys.exit()
x0, x1 = min(p[0] for p in points), max(p[0] for p in points)
y0, y1 = min(p[1] for p in points), max(p[1] for p in points)
row = (y0 + y1) // 2
runs, n = [], 0
for x in range(x0, x1 + 2):
    if x <= x1 and pixels[x, row] != bg:
        n += 1
    elif n:
        runs.append(n)
        n = 0
print(" ".join(map(str, runs)))
name, out = sys.argv[2], sys.argv[3]
if name and out:
    crop = image.crop((0, 0, 20, y1 + 3))
    crop.resize((crop.width * 8, crop.height * 8), Image.NEAREST).save(f"{out}/mark-{name}.png")
PY
}

# expect_mark <runs> <layout>: the mark of tag 1 shows the layout.
expect_mark() {
  local got=none
  for _ in $(seq 20); do
    grim "$work/bar.png"
    got=$(mark "$work/bar.png" "$2")
    [ "$got" = "$1" ] && break
    sleep 0.1
  done
  if [ "$got" = "$1" ]; then
    echo "ok: the mark of tag 1 shows the $2 layout ($got)"
  else
    echo "FAIL: the mark of tag 1 shows the $2 layout (middle row: $got, expected: $1)"
    failed=1
  fi
}

# expect_layout <layout> <description>: kwm sets the layout.
expect_layout() {
  for _ in $(seq 20); do
    if grep -q "set layout to $1" "$work/river.log"; then
      echo "ok: $2"
      return
    fi
    sleep 0.1
  done
  echo "FAIL: $2 (no \"set layout to $1\" in the log)"
  failed=1
}

# The font of the bar is Terminus of 12 pixels: the mark has 10 pixels.
expect_mark "5 4" tile

# The pointer on tag 1. The menu shows at once, below the pointer. The menu
# has the background of the bar, the windows and the gaps below the bar have
# other colors. grim also shows the cursor.
input move 9 6
input move 9 7
sleep 1
grim "$work/hover.png"
read -r left top right bottom <<<"$(python3 - "$work/hover.png" <<'PY'
import sys
from PIL import Image
image = Image.open(sys.argv[1]).convert("RGB")
pixels = image.load()
bg = pixels[0, 0]
width, height = image.size
bar = next(y for y in range(height) if pixels[0, y] != bg)
points = [(x, y) for x in range(0, 400) for y in range(bar, 300) if pixels[x, y] == bg]
if points:
    print(min(p[0] for p in points), min(p[1] for p in points),
          max(p[0] for p in points), max(p[1] for p in points))
else:
    print("none none none none")
PY
)"
if [ "$top" = none ]; then
  echo "FAIL: the pointer on the selected tag shows the menu of the layouts"
  failed=1
else
  echo "ok: the pointer on the selected tag shows the menu of the layouts ($left,$top to $right,$bottom)"
  # The menu has 4 lines: tile, centered master, float and monocle. Go
  # straight down to the middle of line 4.
  target=$((top + (bottom - top) * 7 / 8))
  x=$((left + 10))
  for y in $(seq 11 4 "$target") "$target"; do
    input move "$x" "$y"
  done
  sleep 0.5
  if [ -n "${TEST_SCREENSHOT_DIR:-}" ]; then
    grim "$work/menu.png"
    python3 - "$work/menu.png" "$TEST_SCREENSHOT_DIR/menu.png" "$right" "$bottom" <<'PY'
import sys
from PIL import Image
image = Image.open(sys.argv[1]).convert("RGB")
crop = image.crop((0, 0, int(sys.argv[3]) + 4, int(sys.argv[4]) + 4))
crop.resize((crop.width * 4, crop.height * 4), Image.NEAREST).save(sys.argv[2])
PY
  fi
  input press
  input release
  expect_layout monocle "a click on a line of the menu selects the layout"
  expect_mark "10" monocle
fi

# Away from the bar. A single press of Super+1 on tag 1 does not change the
# layout.
input move 300 400
sleep 1
wtype -s 200 -M logo -s 100 1 -s 100 -m logo
sleep 1
expect_mark "10" monocle

# double: two presses of Super+1, 150 milliseconds between them.
double() {
  sleep 1
  wtype -s 200 -M logo -s 100 1 -s 150 1 -s 100 -m logo
}

double
expect_layout tile "a quick second press of Super+1 goes from the last layout to the first layout"
expect_mark "5 4" tile
double
expect_layout centered_master "a quick second press of Super+1 goes to the centered master layout"
expect_mark "2 4 2" centered_master
double
expect_layout float "a quick second press of Super+1 goes to the float layout"
# The middle row of the float mark: the left line of the window behind,
# and the title bar of the front window.
expect_mark "1 7" float

if grep -q "panic" "$work/river.log"; then
  echo "FAIL: kwm runs ($(grep -m1 panic "$work/river.log"))"
  failed=1
fi

if [ "$failed" -ne 0 ]; then
  echo "kwm-test-layout-menu: the log of kwm:" >&2
  grep -E "tooltip|layout" "$work/river.log" | tail -30 >&2 || true
  exit 1
fi
echo "kwm-test-layout-menu: all tests passed"
