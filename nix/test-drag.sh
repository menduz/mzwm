# Tests a drag of a window by its title bar. Run it with the environment of
# `kwm-test-drag` in tests.nix. Refer to src/kwm/drag.zig.
#
# - A tiled window stays tiled until the pointer goes farther than 32 pixels
#   (drag.float_distance). Then it floats, with its size in the layout.
# - A floating window that the pointer releases at most 8 pixels from the
#   left edge (drag.tile_edge) becomes the master window. At the right edge,
#   it goes to the top of the stack. While the pointer holds the window at
#   such an edge, the other windows show their places after the drop, and a
#   placeholder shows the place of the window.
# - When the stack has windows, a new master window adds one master window.
# - When a master window closes and the master area has more than one
#   window, the master area gets one window less (src/kwm/nmaster.zig).
#
# config.def.zon has the tile layout with the master area at the left, one
# master window, and new windows at the top (the master window).
#
# Usage: kwm-test-drag
#
# With TEST_SCREENSHOT_DIR, the test writes drag-preview.png there: the
# screen while the pointer holds a window at the right edge.
set -euo pipefail

TEST_NAME=drag

# config.def.zon with a green outline for the placeholder of the drop
# preview: the border of the focused window has the color of the default.
TEST_KWM_CONFIG=$(sed 's/\.outline = 0xf29718ff,/.outline = 0x00ff00ff,/' "$TEST_DEFAULT_CONFIG")
grep -q '\.outline = 0x00ff00ff,' <<<"$TEST_KWM_CONFIG"

# shellcheck source=test-lib.sh
source "$TEST_LIB"

# field <name> <field>: a value of the state line of a window.
field() {
  sed -E "s/.* $2=([^ ]+).*/\1/" "$work/$1.state"
}

# captions <png> <rrggbb> [<rrggbb> <width>]: each caption of the color, one
# line "x y rows" for each, from the top. A caption is a run of rows with a
# horizontal run of at least 50 pixels of the color. With a second color, the caption is a
# gradient from the first color to the second one over <width> pixels (the
# caption of the focused window).
captions() {
  python3 - "$@" <<'PY'
import sys
from PIL import Image
image = Image.open(sys.argv[1]).convert("RGB")
def rgb(hex_color):
    return tuple(int(hex_color[i:i + 2], 16) for i in (0, 2, 4))
def gradient(a, b, x, span):
    return tuple(ca + ((cb - ca) * x + span // 2) // span for ca, cb in zip(a, b))
if len(sys.argv) > 3:
    start, end, span = rgb(sys.argv[2]), rgb(sys.argv[3]), int(sys.argv[4]) - 1
    wanted = {gradient(start, end, x, span) for x in range(span + 1)}
else:
    wanted = {rgb(sys.argv[2])}
pixels = image.load()
width, height = image.size
# The longest horizontal run of the color in a row, as (left, length). A
# border of another window can have the color too, thus the run is the
# caption, not the leftmost pixel.
def longest(y):
    best, start = (0, 0), None
    for x in range(width + 1):
        if x < width and pixels[x, y] in wanted:
            if start is None:
                start = x
        elif start is not None:
            if x - start > best[1]:
                best = (start, x - start)
            start = None
    return best
# A caption is a run of rows whose runs of 50 pixels or more overlap. The
# title text cuts some rows: the caption starts at the smallest left end.
runs = []
group = None
for y in range(height + 1):
    left, length = longest(y) if y < height else (0, 0)
    if length >= 50 and group is not None and left < group[1] and left + length > group[0]:
        group = [min(group[0], left), max(group[1], left + length), group[2]]
        continue
    if group is not None and y - group[2] >= 10:
        runs.append((group[0], group[2], y - group[2]))
    group = [left, left + length, y] if length >= 50 else None
for run in runs:
    print(*run)
PY
}

# focused_caption <name>: the caption of the focused window <name>, as
# "x y".
focused_caption() {
  grim "$work/shot.png"
  captions "$work/shot.png" 000080 1084d0 "$(field "$1" width)" | head -1 | cut -d' ' -f1,2
}

start_input

open a --decoration
expect_state a "^maximized=1 " "a fills the output"
open b --decoration
expect_state a "^maximized=0 .* tiled=1 " "a goes to the stack"
# Wait until the layout gives b its place: b is the wider window.
for _ in $(seq 50); do
  [ "$(field b width)" -gt "$(field a width)" ] 2>/dev/null && break
  sleep 0.1
done
expect_state b " tiled=1 .*decoration=server width=$(field b width) " "b is the master window"
expect_state a " tiled=1 .*decoration=server width=$(field a width) " "a is in the stack"
master_width=$(field b width)
stack_width=$(field a width)
if [ "$master_width" -gt "$stack_width" ]; then
  echo "ok: the master window is wider than the stack ($master_width, $stack_width)"
else
  echo "FAIL: the master window is wider than the stack ($master_width, $stack_width)"
  failed=1
fi

read -r bx by <<<"$(focused_caption b)"
input move $((bx + 40)) $((by + 9))
input press
input release
expect_state b " tiled=1 .* width=$master_width " "a click on the title bar keeps the window tiled"

# Not farther than 32 pixels: the window stays in its place.
input press
input move $((bx + 60)) $((by + 9))
input move $((bx + 60)) $((by + 30))
expect_state b " tiled=1 .* width=$master_width " "a move of 30 pixels keeps the window tiled"

input move $((bx + 340)) $((by + 209))
expect_state b " tiled=0 .* width=$master_width " \
  "a move of more than 32 pixels makes the window floating, with its size"
expect_state a "^maximized=1 " "the other window is alone in the layout"
input release
expect_state b " tiled=0 .* width=$master_width " "a release far from the edges keeps the window floating"

# green_pixels <png>: the number of pixels of the outline of the
# placeholder.
green_pixels() {
  python3 - "$1" <<'PY'
import sys
from PIL import Image
print(list(Image.open(sys.argv[1]).convert("RGB").getdata()).count((0, 255, 0)))
PY
}

# The right edge: the top of the stack. While the pointer holds the window
# there, the other window shows its place after the drop, and the
# placeholder shows the place of the window.
read -r bx by <<<"$(focused_caption b)"
input move $((bx + 40)) $((by + 9))
input press
input move 1276 360
expect_state a " tiled=1 .* width=$master_width " "at the edge, the other window shows its place after the drop"
expect_state b " tiled=0 .* width=$master_width " "at the edge, the window stays floating until the release"
grim "$work/preview.png"
# TEST_SCREENSHOT_DIR keeps the screenshot of the preview.
if [ -n "${TEST_SCREENSHOT_DIR:-}" ]; then
  cp "$work/preview.png" "$TEST_SCREENSHOT_DIR/drag-preview.png"
fi
preview_green=$(green_pixels "$work/preview.png")
# The outline of 2 pixels around the place of a window in the stack.
if [ "$preview_green" -gt $((2 * 2 * 600)) ]; then
  echo "ok: the placeholder shows the place of the window ($preview_green pixels)"
else
  echo "FAIL: the placeholder shows the place of the window ($preview_green pixels)"
  failed=1
fi
# Away from the edge, the preview stops.
input move 700 360
expect_state a "^maximized=1 " "away from the edge, the other window takes its place again"
grim "$work/no-preview.png"
if [ "$(green_pixels "$work/no-preview.png")" = 0 ]; then
  echo "ok: away from the edge, no placeholder"
else
  echo "FAIL: away from the edge, no placeholder ($(green_pixels "$work/no-preview.png") pixels)"
  failed=1
fi
input move 1276 360
expect_state a " tiled=1 .* width=$master_width " "back at the edge, the preview shows again"
input release
expect_state b " tiled=1 .* width=$stack_width " "a release at the right edge puts the window in the stack"
expect_state a " tiled=1 .* width=$master_width " "the other window is the master window"
grim "$work/dropped.png"
if [ "$(green_pixels "$work/dropped.png")" = 0 ]; then
  echo "ok: after the drop, no placeholder"
else
  echo "FAIL: after the drop, no placeholder ($(green_pixels "$work/dropped.png") pixels)"
  failed=1
fi

# The left edge: the master window. The tiled window floats on the way.
read -r bx by <<<"$(focused_caption b)"
input move $((bx + 40)) $((by + 9))
input press
input move 3 360
input release
expect_state b " tiled=1 .* width=$master_width " "a release at the left edge makes the window the master window"
expect_state a " tiled=1 .* width=$stack_width " "the other window goes to the stack"

# Three windows: c is the master window, b and a are in the stack. a goes to
# the left edge. The stack has a window, thus the master area gets two
# windows: c stays a master window.
open c --decoration
expect_state c " tiled=1 .* width=$master_width " "c is the master window"
expect_state b " tiled=1 .* width=$stack_width " "b is in the stack"
stack_height=$(field a height)
# a is the window at the bottom of the stack, with the caption of a window
# without focus.
grim "$work/shot.png"
read -r ax ay _ <<<"$(captions "$work/shot.png" 808080 | sort -k2 -n | tail -1)"
input move $((ax + 40)) $((ay + 9))
input press
input move 3 500
input release
expect_state a " tiled=1 .* width=$master_width " "a release at the left edge makes a master window"
expect_state c " tiled=1 .* width=$master_width " "the master window stays a master window"
expect_state b " tiled=1 .* width=$stack_width " "the other window is in the stack"
if [ "$(field b height)" -gt "$stack_height" ]; then
  echo "ok: the window alone in the stack is higher ($(field b height) > $stack_height)"
else
  echo "FAIL: the window alone in the stack is higher ($(field b height), $stack_height)"
  failed=1
fi

# A master window closes, and the master area has two windows: the master
# area gets one window less. Without this, b goes into the master area.
master_height=$(field c height)
close a
expect_state c " tiled=1 .* width=$master_width height=$(field b height)$" \
  "after a master window closes, c is alone in the master area"
expect_state b " tiled=1 .* width=$stack_width " "the stack keeps its window"
if [ "$(field c height)" -gt "$master_height" ]; then
  echo "ok: the master window takes the height of the output"
else
  echo "FAIL: the master window takes the height of the output ($(field c height), $master_height)"
  failed=1
fi

# The only master window closes: the stack window is alone.
open d --decoration
expect_state d " tiled=1 .* width=$master_width " "d is the master window"
close d
expect_state c " tiled=1 .* width=$master_width " "c is the master window again"
expect_state b " tiled=1 .* width=$stack_width " "one master window: b stays in the stack"

# nmaster above the other tiled windows: Super+Shift+H makes c and b two
# master windows in one column. c floats, and b is alone. A drop at an edge
# still gives c the side of the edge (src/kwm/nmaster.zig, for_drop).
more_masters() {
  input key 125 down
  input key 42 down
  input key 35 down
  input key 35 up
  input key 42 up
  input key 125 up
}
# drag_out_to <x> <y>: drag the focused window c by its title bar to x, y.
drag_out_to() {
  read -r cx cy <<<"$(focused_caption c)"
  input move $((cx + 40)) $((cy + 9))
  input press
  input move "$1" "$2"
  input release
}
more_masters
expect_state b " tiled=1 .* width=1262 " "with two master windows and no stack, the column is as wide as the output"
drag_out_to 1276 360
expect_state c " tiled=1 .* width=$stack_width " "with a larger nmaster, a drop at the right edge puts the window in the stack"
expect_state b " tiled=1 .* width=$master_width " "the other window is the master window"
more_masters
expect_state b " tiled=1 .* width=1262 " "again two master windows in one column"
drag_out_to 3 360
expect_state c " tiled=1 .* width=$master_width " "with a larger nmaster, a drop at the left edge makes the window the master window"
expect_state b " tiled=1 .* width=$stack_width " "the other window goes to the stack"

if [ "$failed" -ne 0 ]; then
  echo "kwm-test-drag: the log of kwm:" >&2
  grep -E "drop|floating|op (begin|end|delta|release)" "$work/river.log" | tail -60 >&2 || true
  exit 1
fi
echo "kwm-test-drag: all tests passed"
