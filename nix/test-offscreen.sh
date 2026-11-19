# Floating windows can cross each output edge without changing size, including
# after a client commits new dimensions. At least one pixel of the client stays
# on the output. Explicit snap actions still align their frames with the work
# area. Run with the environment of tests.nix.
set -euo pipefail

TEST_NAME=offscreen
TEST_KWM_CONFIG=$(python3 - "$TEST_DEFAULT_CONFIG" <<'PY'
import sys
text = open(sys.argv[1]).read().replace(".default_layout = .tile,", ".default_layout = .float,")
bindings = []
def bind(key, action, shift=False):
    modifiers = ".mod4 = true" + (", .shift = true" if shift else "")
    bindings.append(f'            .{{ .keysym = "{key}", .modifiers = .{{ {modifiers} }}, '
                    f'.event = .{{ .click = .{{ .pressed = {action} }} }} }},\n')
for key, axis, step in [("F1", "horizontal", -100), ("F2", "horizontal", 100),
                        ("F3", "vertical", -100), ("F4", "vertical", 100)]:
    bind(key, f".{{ .move = .{{ .step = .{{ .{axis} = {step} }} }} }}")
for key, edge in zip(["F5", "F6", "F7", "F8"], ["left", "right", "top", "bottom"]):
    bind(key, f".{{ .snap = .{{ .edge = .{edge} }} }}")
for key, axis in [("F9", "horizontal"), ("F10", "vertical")]:
    for shift, step in [(False, 40), (True, -40)]:
        bind(key, f".{{ .resize = .{{ .step = .{{ .{axis} = {step} }} }} }}", shift)
bind("F12", ".{ .switch_layout = .{ .layout = .tile } }")
text = text.replace("        .key = .{\n", "        .key = .{\n" + "".join(bindings))
print(text, end="")
PY
)

# shellcheck source=test-lib.sh
source "$TEST_LIB"
start_input

active=a
open "$active" --decoration
expect_state "$active" 'decoration=server width=300 height=200$' 'the floating window starts at its natural size'
grim "$work/initial.png"
read -r home_x home_y bar_height < <(python3 - "$work/initial.png" <<'PY'
import sys
from PIL import Image
image = Image.open(sys.argv[1]).convert("RGB")
pixels = image.load()
points = [(x, y) for y in range(image.height) for x in range(image.width) if pixels[x, y] == (64, 96, 128)]
bar = next(y for y in range(image.height) if pixels[0, y] != pixels[0, 0])
print(min(x for x, y in points), min(y for x, y in points), bar)
PY
)
x=$home_x y=$home_y width=300 height=200

key() {
  if [ "${2:-}" = shift ]; then
    wtype -s 100 -M logo -M shift -k "$1" -m shift -m logo
  else
    wtype -s 100 -M logo -k "$1" -m logo
  fi
}

# Drag by the title bar or with Super from the center of the client. The
# pointer stays on the output, away from the zones that tile a dropped window.
drag_to() {
  local grab_y=$((height / 2))
  if [ "${3:-}" = title ]; then grab_y=-10; fi
  input move $((x + width / 2)) $((y + grab_y))
  if [ "${3:-}" != title ]; then input key 125 down; fi
  input press
  input move $(($1 + width / 2)) $(($2 + grab_y))
  input release
  if [ "${3:-}" != title ]; then input key 125 up; fi
  x=$1 y=$2
}

# Check the actual client size and visible content rectangle after the move
# has settled. Clipping must not move the window back or shrink its buffer.
check_box() {
  expect_state "$active" " width=$width height=$height$" "$1: size is preserved"
  grim "$work/window.png"
  if python3 - "$work/window.png" "$x" "$y" "$width" "$height" "$bar_height" <<'PY'
import sys
from PIL import Image
image = Image.open(sys.argv[1]).convert("RGB")
x, y, width, height, bar = map(int, sys.argv[2:])
mask = Image.new("1", image.size)
pixels = image.load()
mask.putdata([pixels[px, py] == (64, 96, 128) for py in range(image.height) for px in range(image.width)])
expected = (max(0, x), max(bar, y), min(image.width, x + width), min(image.height, y + height))
actual = mask.getbbox()
# Absolute virtual-pointer coordinates and movement deltas round to logical
# pixels separately. A one-pixel difference is possible after a drag.
assert actual is not None and all(abs(a - b) <= 1 for a, b in zip(actual, expected)), \
    f"visible client rectangle: {actual}, expected {expected} (within one pixel)"
PY
  then
    echo "ok: $1: the visible part stays at the requested position"
  else
    failed=1
  fi
}

drag_to -100 "$home_y" title
check_box 'drag beyond the left edge'
key F1
x=$((x - 100))
check_box 'keyboard move farther beyond the left edge'
# The last column of the client stays on the output.
key F1
x=$((1 - width))
check_box 'a move without overlap stops at one pixel on the left'
key F2
key F2
x=$((x + 200))
drag_to "$home_x" "$home_y"
check_box 'move back onscreen restores the full window'

drag_to "$home_x" $((bar_height - 70))
check_box 'drag beyond the top edge'
drag_to "$home_x" "$home_y"

drag_to 1080 "$home_y"
check_box 'drag beyond the right edge'
# These configures exercise the dimensions callback while the window is
# outside: it must not clamp the new size to the remaining onscreen space.
key F9
x=$((x - 20)) width=340
key F10
y=$((y - 20)) height=240
check_box 'resize and client commit while partly offscreen'
key F9 shift
x=$((x + 20)) width=300
key F10 shift
y=$((y + 20)) height=200
drag_to "$home_x" "$home_y"

drag_to "$home_x" 570
check_box 'drag beyond the bottom edge'
key F4
y=$((y + 100))
check_box 'keyboard move farther beyond the bottom edge'
# The first row of the client stays on the output.
key F4
y=719
check_box 'a move without overlap stops at one pixel at the bottom'
key F3
key F3
y=$((y - 200))
drag_to "$home_x" "$home_y"

# The border is 2 pixels; the floating title bar is 19 pixels high.
key F5
x=2
check_box 'explicit snap left'
key F6
x=$((1280 - width - 2))
check_box 'explicit snap right'
key F7
y=$((bar_height + 2 + 19))
check_box 'explicit snap top'
key F8
y=$((720 - height - 2))
check_box 'explicit snap bottom'
drag_to "$home_x" "$home_y"

# The same behavior for an individually floating window in the tile layout.
close "$active"
key F12
active=b
open "$active" --decoration --fixed
expect_state "$active" ' tiled=0 .*width=300 height=200$' 'the window floats in a tiled workspace'
x=$home_x y=$home_y
drag_to -100 "$home_y"
check_box 'individual floating window beyond the left edge'
drag_to "$home_x" "$home_y"
drag_to 1080 "$home_y"
check_box 'individual floating window beyond the right edge'

# A smaller mode of the output: the window goes back until the first column
# of the client is on the output. Its size stays.
wlr-randr --output HEADLESS-1 --custom-mode 800x600
x=799
check_box 'a smaller output keeps one pixel of the window'

if [ "$failed" -ne 0 ] || grep -q panic "$work/river.log"; then
  tail -80 "$work/river.log" >&2
  exit 1
fi
echo 'kwm-test-offscreen: all tests passed'
