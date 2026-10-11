# Tests the overlay of the Super key: Super down alone shows a band at the
# bottom of the output after the delay, with the key bindings of
# `kwm bindings`. Super up removes it. A key binding before the delay stops
# it. Run it with the environment of `kwm-test-overlay` in tests.nix. Refer
# to src/kwm/overlay.zig and super_hold.zig.
#
# With TEST_SCREENSHOT set, the test copies the screenshot of the band to
# that file.
#
# Usage: kwm-test-overlay
set -euo pipefail

TEST_NAME=overlay

# config.def.zon with the overlay on, a delay of 1 second, fixed colors,
# a font with a bold face, and a description for Super+Return.
TEST_KWM_CONFIG=$(python3 - "$TEST_DEFAULT_CONFIG" <<'PY'
import sys
config = open(sys.argv[1]).read()
replacements = [
    ("    .overlay = .{\n        .enabled = false,\n        .command = .{ \"kwm\", \"-c\", \"{config}\", \"bindings\" },\n        .delay = 2000,\n",
     "    .overlay = .{\n        .enabled = true,\n        .command = .{ \"kwm\", \"-c\", \"{config}\", \"bindings\" },\n        .delay = 1000,\n"),
    ('        .font = "monospace:size=10",\n', '        .font = "DejaVu Sans Mono:size=9",\n'),
    ("        .gtk_colors = .{\n            .fg = \"tooltip_text_color\",\n            .bg = \"tooltip_color\",\n            .accent = \"active_color_1\",\n        },\n",
     "        .gtk_colors = null,\n"),
    ('.{ .keysym = "Return", .modifiers = .{ .mod4 = true }, ',
     '.{ .keysym = "Return", .modifiers = .{ .mod4 = true }, .description = "open a terminal", '),
]
for old, new in replacements:
    if old not in config:
        sys.exit(f"kwm-test-overlay: config.def.zon has no {old!r}")
    config = config.replace(old, new, 1)
print(config, end="")
PY
)

# shellcheck source=test-lib.sh
source "$TEST_LIB"

# The colors of the overlay in config.def.zon.
export BG="255,255,225" FG="0,0,0" ACCENT="0,0,128"

# band <png>: the first row of the band from the bottom edge, and the count
# of pixels in the accent color (the chords). "none" without the band.
band() {
  python3 - "$1" <<'PY'
import os
import sys
from PIL import Image
image = Image.open(sys.argv[1]).convert("RGB")
w, h = image.size
bg = tuple(int(c) for c in os.environ["BG"].split(","))
fg = tuple(int(c) for c in os.environ["FG"].split(","))
accent = tuple(int(c) for c in os.environ["ACCENT"].split(","))
# The band touches the left, the right and the bottom edge.
if image.getpixel((0, h - 1)) != bg or image.getpixel((w - 1, h - 1)) != bg:
    print("none 0")
    sys.exit()
top = h - 1
while top > 0 and image.getpixel((0, top - 1)) == bg:
    top -= 1
# The line at the top of the band has the text color.
line = top - 1 if image.getpixel((0, top - 1)) == fg else -1
count = sum(1 for y in range(top, h) for x in range(w) if image.getpixel((x, y)) == accent)
print(line, count)
PY
}

start_input
sleep 1

SUPER=125
J=36

# Super down alone. Before the delay, there is no band.
input key $SUPER down
sleep 0.4
grim "$work/early.png"
read -r line _ <<<"$(band "$work/early.png")"
if [ "$line" = none ]; then
  echo "ok: no band before the delay"
else
  echo "FAIL: a band before the delay (top line $line)"
  failed=1
fi

# After the delay: the band, with the chords in the accent color.
sleep 1.1
grim "$work/shown.png"
read -r line count <<<"$(band "$work/shown.png")"
if [ "$line" = none ] || [ "$line" -lt 0 ]; then
  echo "FAIL: no band at the bottom after the delay ($line)"
  failed=1
else
  echo "ok: the band is at the bottom, from row $line"
  if [ "$count" -gt 0 ]; then
    echo "ok: the chords have the accent color ($count pixels)"
  else
    echo "FAIL: no pixel in the accent color"
    failed=1
  fi
fi
if [ -n "${TEST_SCREENSHOT:-}" ]; then
  cp "$work/shown.png" "$TEST_SCREENSHOT"
fi

# Super up removes the band.
input key $SUPER up
sleep 0.5
grim "$work/released.png"
read -r line _ <<<"$(band "$work/released.png")"
if [ "$line" = none ]; then
  echo "ok: Super up removes the band"
else
  echo "FAIL: the band stays after Super up"
  failed=1
fi

# A binding (Super+J) before the delay: no band, also after the delay.
input key $SUPER down
input key $J down
input key $J up
sleep 1.5
grim "$work/binding.png"
read -r line _ <<<"$(band "$work/binding.png")"
if [ "$line" = none ]; then
  echo "ok: a binding before the delay stops the band"
else
  echo "FAIL: a band after a binding"
  failed=1
fi
input key $SUPER up

# The command of the band stopped.
if pgrep -f "kwm -c .* bindings" >/dev/null; then
  echo "FAIL: the command of the overlay runs"
  failed=1
else
  echo "ok: the command of the overlay stopped"
fi

if [ "$failed" -ne 0 ]; then
  grep -E "overlay|modifiers_update" "$work/river.log" | tail -20 >&2 || true
fi
exit "$failed"
