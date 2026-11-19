# Super+= tiles one or two windows and floats larger workspaces. Check the
# selected workspace, client states, and frame positions for odd counts.
set -euo pipefail

TEST_NAME=flex
TEST_KWM_CONFIG=$(sed -E \
  -e 's/\.inner_gap = [0-9]+/\.inner_gap = 11/g' \
  -e 's/\.nmaster = 1/\.nmaster = 3/g' \
  -e 's/\.master_location = \.left/\.master_location = .top/g' \
  "$TEST_DEFAULT_CONFIG")
# shellcheck source=test-lib.sh
source "$TEST_LIB"
start_input

# Use an odd inner gap to check rounding as well as the space outside frames.
outer_gap=9
inner_gap=11

key() {
  wtype -s 100 -M logo -s 100 "$1" -s 100 -m logo
}

size() {
  sed -E 's/.* width=([0-9]+) height=([0-9]+)$/\1 \2/' "$work/$1.state"
}

# A different workspace must retain its tiled layout and geometry.
key 2
open hidden --decoration
expect_state hidden '^maximized=1 ' 'the other workspace starts tiled'
hidden_size=$(size hidden)
key 1
key '='

# Measure the work area on a fresh tiled workspace; its lone window is
# maximized and has no borders or title bar.
key 3
open a --decoration
expect_state a '^maximized=1 ' 'a lone tiled window fills the work area'
read -r area_width area_height <<<"$(size a)"

check_tiled() {
  key '='
  if [ "$#" = 1 ]; then
    expect_state "$1" "^maximized=1 .* tiled=1 .* width=$area_width height=$area_height$" \
      'Super+= tiles and maximizes the lone window'
  else
    local left_width=$(((area_width - 2 * outer_gap - inner_gap) / 2 - 4))
    local right_width=$((area_width - 2 * outer_gap - inner_gap - left_width - 8))
    for name in "$@"; do
      expect_state "$name" "^maximized=0 .* tiled=1 .* width=($left_width|$right_width) height=$((area_height - 2 * outer_gap - 4 - 19))$" \
        "Super+= tiles window $name in an equal half"
    done
    check_cells "$@"
  fi
}

check_flex() {
  key '='
  check_cells "$@"
}

check_cells() {
  sleep 0.5
  grim "$work/flex.png"
  if python3 - "$work" "$area_width" "$area_height" "$outer_gap" "$inner_gap" "$@" <<'PY'
import collections
import pathlib
import re
import sys
from PIL import Image

work = pathlib.Path(sys.argv[1])
width, height = map(int, sys.argv[2:4])
outer, gap = map(int, sys.argv[4:6])
names = sys.argv[6:]
count = len(names)
border, title = 2, 19
image = Image.open(work / "flex.png").convert("RGB")
bar = image.height - height
pixels = image.load()
columns = min(count, 2)
left_count = (count + 1) // 2
expected = []
usable_width = width - 2 * outer - gap * (columns - 1)
for col in range(columns):
    rows = left_count if col == 0 else count - left_count
    x = outer + usable_width * col // columns + col * gap
    right = outer + usable_width * (col + 1) // columns + col * gap
    usable_height = height - 2 * outer - gap * (rows - 1)
    intervals = []
    for row in range(rows):
        y = outer + usable_height * row // rows + row * gap
        bottom = outer + usable_height * (row + 1) // rows + row * gap
        expected.append((right - x - 2 * border, bottom - y - 2 * border - title))
        intervals.append((bar + y + border + title, bar + bottom - border))
    # The client content must occupy exactly these rows: its title and
    # borders fit inside its cell, without covering a neighbor or the bar.
    mid = (x + right) // 2
    actual_y = [y for y in range(bar, image.height) if pixels[mid, y] == (64, 96, 128)]
    expected_y = [y for start, end in intervals for y in range(start, end)]
    assert actual_y == expected_y, f"column {col}: contents do not fill their cells"
    for start, _ in intervals:
        actual_x = [px for px in range(x, right) if pixels[px, start] == (64, 96, 128)]
        assert actual_x == list(range(x + border, right - border)), f"column {col}: wrong width"

actual = []
for name in names:
    state = (work / f"{name}.state").read_text()
    assert state.startswith("maximized=0 "), state
    actual.append(tuple(map(int, re.search(r"width=(\d+) height=(\d+)", state).groups())))
assert collections.Counter(actual) == collections.Counter(expected), (actual, expected)
print(f"ok: {count} windows share the same outer and inner padding, including borders and titles")
PY
  then
    :
  else
    failed=1
  fi
}

# The lone window must stop floating and fill the work area without a frame.
wtype -s 100 -M logo -M shift -k space -m shift -m logo
expect_state a ' tiled=0 ' 'the lone window starts individually floating'
check_tiled a
# Repeated maximize requests and repeated presses keep the full size.
kill -USR1 "${client[a]}"
check_tiled a

open b --decoration
expect_state b 'decoration=server ' 'the second window is ready'
# An adjusted master count and ratio must not survive equalization.
wtype -s 100 -M logo -M shift h -m shift -m logo
key l
check_tiled a b

open c --decoration
expect_state c ' activated=1 ' 'the third window has focus'
# Include a window with its own floating flag, as well as the float layout.
wtype -s 100 -M logo -M shift -k space -m shift -m logo
expect_state c ' tiled=0 ' 'the third window is individually floating'
check_flex a b c

wtype -s 100 -M logo -M shift f -m shift -m logo
sleep 0.5
check_flex a b c

open d --decoration
expect_state d 'decoration=server ' 'the fourth window is ready'
check_flex a b c d
before=$(size a)
open e --decoration
expect_state e 'decoration=server ' 'the fifth window is ready'
if [ "$(size a)" = "$before" ]; then
  echo 'ok: opening a window keeps the existing floating arrangement'
else
  echo 'FAIL: opening a window rearranged existing windows'
  failed=1
fi
check_flex a b c d e
check_flex a b c d e

# Return from a floating layout with an individually floating window to tile.
close e
close d
close b
sleep 0.5
check_tiled a c
close a
sleep 0.5
check_tiled c
# Fullscreen must also end when a lone window is tiled and maximized.
wtype -s 100 -M logo -M shift f -m shift -m logo
sleep 0.5
check_tiled c

key 2
expect_state hidden '^maximized=1 .* tiled=1 ' 'the other workspace keeps its tiled layout'
if [ "$(size hidden)" != "$hidden_size" ]; then
  echo 'FAIL: flex changed the other workspace geometry'
  failed=1
fi

if [ "$failed" -ne 0 ] || grep -q panic "$work/river.log"; then
  tail -80 "$work/river.log" >&2
  exit 1
fi
echo 'kwm-test-flex: all tests passed'
