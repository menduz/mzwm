# Tests the deck layout: the main window at the left, and the stack as an
# accordion at the right. The window of the stack with the last focus is open
# (its title bar and its contents), and the other windows show only their
# title bars, in the order of the stack. A click on a title bar or the focus
# keys open a window; the pointer over a title bar does not. Alt+Return swaps
# the open window and the main window. Run it with the environment of
# `kwm-test-deck` in tests.nix. Refer to src/kwm/layout/accordion.zig.
#
# Without a GTK theme, the caption of the focused window is a gradient from
# #000080, and the caption of another window is #808080. The windows of
# test-client.py are #406080.
#
# Usage: kwm-test-deck
set -euo pipefail

TEST_NAME=deck

# config.def.zon with the deck layout (one master, the border of 2 pixels).
TEST_KWM_CONFIG=$(sed "s|^    .default_layout = .tile,|    .default_layout = .deck,|" "$TEST_DEFAULT_CONFIG")
if ! grep -q "^    .default_layout = .deck," <<<"$TEST_KWM_CONFIG"; then
  echo "kwm-test-deck: config.def.zon has no default_layout line" >&2
  exit 1
fi
# A title bar (19) and the border (2).
title=19
border=2

# shellcheck source=test-lib.sh
source "$TEST_LIB"

field() {
  sed -E "s/.* $2=([^ ]+).*/\1/" "$work/$1.state"
}

# focused: the name of the window with the focus.
focused() {
  grep -l " activated=1 " "$work"/?.state 2>/dev/null | head -n 1 | sed -E 's|.*/(.)\.state|\1|'
}

start_input

# One window in the stack: it fills the stack area. The main window is wider.
open a --decoration
open b --decoration
expect_state b " tiled=1 .*decoration=server " "the second window is tiled"
expect_state a " tiled=1 .*decoration=server " "the first window is tiled"
if [ "$(field a width)" -lt "$(field b width)" ]; then single=a; else single=b; fi
width=$(field "$single" width)
height=$(field "$single" height)
main_width=$(field "$([ "$single" = a ] && echo b || echo a)" width)

# Three windows in the stack: all of them have the size of the open window.
open c --decoration
open d --decoration
# Two borders share one row next to the open window.
stack_height=$((height - 2 * (title + border) - (border - 1)))
sleep 1
stack=()
for name in a b c d; do
  grep -qs " width=$width height=$stack_height$" "$work/$name.state" && stack+=("$name")
done
if [ "${#stack[@]}" = 3 ]; then
  echo "ok: the stack has three windows of the size of the open window"
else
  echo "FAIL: the stack has three windows (stack: ${stack[*]}; size ${width}x$stack_height)"
  for name in a b c d; do echo "  $name: $(cat "$work/$name.state")"; done
  failed=1
fi

# check_accordion <png> <description>: the stack area (after x=700) shows
# three title bars, and the contents of one window only, right below the
# focused title bar when a window of the stack has the focus.
check_accordion() {
  local captions focused_caption contents
  captions=$({
    python3 "$TEST_CAPTIONS" "$1" 700 808080
    python3 "$TEST_CAPTIONS" "$1" 700 000080 1084d0 "$width"
  } | sort -n -k2 | wc -l)
  focused_caption=$(python3 "$TEST_CAPTIONS" "$1" 700 000080 1084d0 "$width" | head -n 1)
  contents=$(python3 "$TEST_CAPTIONS" "$1" 700 406080)
  local ok=1
  [ "$captions" = 3 ] || ok=0
  [ "$(wc -l <<<"$contents")" = 1 ] || ok=0
  if [ -n "$focused_caption" ]; then
    read -r _ caption_y _ <<<"$focused_caption"
    read -r _ contents_y _ <<<"$contents"
    [ "$contents_y" = $((caption_y + title)) ] || ok=0
  fi
  if [ "$ok" = 1 ]; then
    echo "ok: $2"
  else
    echo "FAIL: $2 (captions: $captions, focused caption: $focused_caption, contents: $(tr '\n' ';' <<<"$contents"))"
    failed=1
  fi
}

grim "$work/deck.png"
check_accordion "$work/deck.png" "the stack is an accordion: one open window, two title bars"

# The stack ends where the main window ends: the lowest row of the border of
# config.def.zon (#f29718 or #34373a, not black) at the left and at the right.
bottoms=$(python3 - "$work/deck.png" <<'PY'
import sys
from PIL import Image
image = Image.open(sys.argv[1]).convert("RGB")
pixels = image.load()
width, height = image.size
def lowest(x0, x1):
    for y in range(height - 1, -1, -1):
        if any(pixels[x, y] != (0, 0, 0) for x in range(x0, x1)):
            return y
print(lowest(0, 640), lowest(720, width))
PY
)
read -r main_bottom stack_bottom <<<"$bottoms"
if [ "$main_bottom" = "$stack_bottom" ]; then
  echo "ok: the stack ends at the bottom of the main window"
else
  echo "FAIL: the stack ends at the bottom of the main window (main: $main_bottom, stack: $stack_bottom)"
  failed=1
fi

# The pointer over a collapsed title bar does not focus it.
mapfile -t gray < <(python3 "$TEST_CAPTIONS" "$work/deck.png" 700 808080)
read -r gray_x gray_y _ <<<"${gray[0]:-0 0 0}"
before=$(focused)
input move $((gray_x + 60)) $((gray_y + 9))
input move $((gray_x + 80)) $((gray_y + 9))
sleep 1
if [ "$(focused)" = "$before" ]; then
  echo "ok: the pointer over a collapsed title bar does not focus it"
else
  echo "FAIL: the pointer over a collapsed title bar does not focus it (focus: $before, then $(focused))"
  failed=1
fi

# A click on the title bar opens the window.
input press
input release
sleep 1
clicked=$(focused)
if [ "$clicked" != "$before" ]; then
  echo "ok: a click on a collapsed title bar focuses the window"
else
  echo "FAIL: a click on a collapsed title bar focuses the window (focus: $clicked)"
  failed=1
fi
grim "$work/deck2.png"
check_accordion "$work/deck2.png" "the window of the click is open"

# Super+J moves the focus. A window of the stack with the focus is open.
wtype -s 200 -M logo -s 100 j -s 100 -m logo
sleep 1
grim "$work/deck3.png"
check_accordion "$work/deck3.png" "after Super+J, the window of the stack with the focus is open"

# Alt+Return swaps the open window and the main window: a click opens a
# collapsed window, then Alt+Return.
mapfile -t gray < <(python3 "$TEST_CAPTIONS" "$work/deck3.png" 700 808080)
read -r gray_x gray_y _ <<<"${gray[0]:-0 0 0}"
input move $((gray_x + 60)) $((gray_y + 9))
input press
input release
sleep 0.5
open_window=$(focused)
wtype -s 200 -M alt -s 100 -k Return -s 100 -m alt
expect_state "$open_window" " width=$main_width " "Alt+Return makes the open window the main window"

if [ "$failed" -ne 0 ]; then
  echo "kwm-test-deck: the log of kwm:" >&2
  grep -E "deck|focus window" "$work/river.log" | tail -20 >&2 || true
  exit 1
fi
echo "kwm-test-deck: all tests passed"
