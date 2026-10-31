# Tests the layout of the selected tag: the mark of the selected tag shows
# the layout, the pointer on the selected tag shows the menu of the layouts,
# a click on a line of the menu selects the layout, a click on the selected
# tag goes to the next layout at once, and a quick second press of Super+1
# on tag 1 goes to the next layout. The menu shows only when the pointer
# enters a selected tag, or at a click on a selected tag. A right click on
# the selected tag goes to the previous layout. Run it with the environment of
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

# config.def.zon with no delay for the tooltip, and 2 seconds for a second
# press of a tag key: the helpers of the test need about 800 milliseconds
# between a click and a key.
TEST_KWM_CONFIG=$(sed "s|^        .tooltip_delay = 500,|        .tooltip_delay = 0,|; s|^    .tag_repeat_cycle = 500,|    .tag_repeat_cycle = 2000,|" "$TEST_DEFAULT_CONFIG")
if ! grep -q "^        .tooltip_delay = 0," <<<"$TEST_KWM_CONFIG" ||
  ! grep -q "^    .tag_repeat_cycle = 2000," <<<"$TEST_KWM_CONFIG"; then
  echo "kwm-test-layout-menu: config.def.zon has no tooltip_delay or tag_repeat_cycle line" >&2
  exit 1
fi

# shellcheck source=test-lib.sh
source "$TEST_LIB"

start_input

open a
open b
expect_state a " tiled=1 " "window a is tiled"
expect_state b " tiled=1 " "window b is tiled"

# mark <png> [name]: the lengths of the runs of pixels of the mark in its top
# row, in its middle row and in its right column, for example "5 4 / 5 4 /
# 3 2 3" for two columns with three windows in the second column. The mark
# is in the cell of
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
def runs(points):
    result, n = [], 0
    for p in points + [None]:
        if p is not None and pixels[p] != bg:
            n += 1
        elif n:
            result.append(n)
            n = 0
    return " ".join(map(str, result))
def row(y):
    return runs([(x, y) for x in range(x0, x1 + 1)])
print(row(y0), "/", row((y0 + y1) // 2), "/", runs([(x1, y) for y in range(y0, y1 + 1)]))
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
    echo "FAIL: the mark of tag 1 shows the $2 layout (top row / middle row / right column: $got, expected: $1)"
    failed=1
  fi
}

# mark_log: expect_layout looks only at the lines of the log after this
# point.
log_start=1
mark_log() {
  log_start=$(($(wc -l <"$work/river.log") + 1))
}

# expect_layout <layout> <description>: kwm sets the layout.
expect_layout() {
  for _ in $(seq 20); do
    if tail -n "+$log_start" "$work/river.log" | grep -q "set layout to $1"; then
      echo "ok: $2"
      return
    fi
    sleep 0.1
  done
  echo "FAIL: $2 (no \"set layout to $1\" in the log)"
  failed=1
}

# The font of the bar is Terminus of 12 pixels: the mark has 10 pixels. The
# windows of the stack of the tile mark have 3, 2 and 3 pixels.
expect_mark "5 4 / 5 4 / 3 2 3" tile

# menu_box <png>: "left top right bottom" of the menu below the bar, or
# "none none none none". The menu has the background of the bar, the windows
# and the gaps below the bar have other colors. grim also shows the cursor.
menu_box() {
  python3 - "$1" <<'PY'
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
}

# expect_menu <yes|no> <description>
expect_menu() {
  local box
  for _ in $(seq 10); do
    grim "$work/menu-check.png"
    box=$(menu_box "$work/menu-check.png")
    if { [ "$1" = yes ] && [[ $box != none* ]]; } || { [ "$1" = no ] && [[ $box == none* ]]; }; then
      echo "ok: $2"
      return
    fi
    sleep 0.2
  done
  echo "FAIL: $2 (menu: $box)"
  failed=1
}

# The pointer on tag 1. The menu shows at once, below the pointer.
input move 9 6
input move 9 7
sleep 1
grim "$work/hover.png"
read -r left top right bottom <<<"$(menu_box "$work/hover.png")"
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
  mark_log
  input press
  input release
  expect_layout monocle "a click on a line of the menu selects the layout"
  expect_mark "10 / 10 / 10" monocle
fi

# A click on the selected tag goes to the next layout at once, also a second
# click one second later. grim shows the cursor: the pointer goes away from
# the mark before expect_mark.
input move 9 7
mark_log
input press
input release
expect_layout tile "a click on the selected tag goes to the next layout"
input move 300 400
expect_mark "5 4 / 5 4 / 3 2 3" tile
input move 9 7
sleep 1
mark_log
input press
input release
expect_layout centered_master "a second click one second later goes to the next layout"
input move 300 400
expect_mark "2 4 2 / 2 4 2 / 10" centered_master

# Away from the bar. A single press of Super+1 on tag 1 does not change the
# layout.
input move 300 400
sleep 2.5
mark_log
wtype -s 200 -M logo -s 100 1 -s 100 -m logo
sleep 1
if tail -n "+$log_start" "$work/river.log" | grep -q "set layout to"; then
  echo "FAIL: a single press of Super+1 on tag 1 does not change the layout"
  failed=1
else
  echo "ok: a single press of Super+1 on tag 1 does not change the layout"
fi
expect_mark "2 4 2 / 2 4 2 / 10" centered_master

# double: two presses of Super+1, 150 milliseconds between them, more than
# tag_repeat_cycle after the last press.
double() {
  sleep 2.5
  mark_log
  wtype -s 200 -M logo -s 100 1 -s 150 1 -s 100 -m logo
}

double
expect_layout float "a quick second press of Super+1 goes to the float layout"
# The float mark: the title bar of the window behind; in the middle row, the
# left line of the window behind and the title bar of the front window; the
# right line of the front window.
expect_mark "7 / 1 7 / 7" float
double
expect_layout monocle "a quick second press of Super+1 goes to the monocle layout"
expect_mark "10 / 10 / 10" monocle
double
expect_layout tile "a quick second press of Super+1 goes from the last layout to the first layout"
expect_mark "5 4 / 5 4 / 3 2 3" tile

# Tag 2 does not show. The pointer enters tag 2 (x 20 to 39), and a click
# shows tag 2. The pointer did not enter a selected tag: no menu, also after
# a small move in the tag.
# One press of Super+2 right after the click is not a second press: only
# the key bindings count for tag_repeat_cycle.
input move 300 400
sleep 0.5
input move 30 7
mark_log
input press
input release
wtype -s 200 -M logo -s 100 2 -s 100 -m logo
sleep 0.5
if tail -n "+$log_start" "$work/river.log" | grep -q "set layout to"; then
  echo "FAIL: one press of Super+2 after a click on tag 2 changes no layout"
  failed=1
else
  echo "ok: one press of Super+2 after a click on tag 2 changes no layout"
fi
input move 31 7
sleep 0.5
expect_menu no "a click that selects a tag does not show the menu"
mark_log
input press
input release
expect_layout centered_master "a click on the shown tag 2 goes to the next layout"
expect_menu yes "a second click in the same place shows the menu"
input move 300 400
sleep 0.6
expect_menu no "the menu goes away when the pointer leaves the tag"
input move 30 7
expect_menu yes "the pointer that comes back shows the menu"
mark_log
input press right
input release right
expect_layout tile "a right click on the shown tag goes to the previous layout"

# The menu shows on tag 2. Super+1 unselects tag 2, and the pointer does not
# move: the menu goes away.
expect_menu yes "the menu shows after the right click"
wtype -s 200 -M logo -s 100 1 -s 100 -m logo
sleep 0.5
expect_menu no "the menu goes away when a key unselects the tag, without a move of the pointer"

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
