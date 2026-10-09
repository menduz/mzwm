# Tests the tooltip of a widget with click commands: the tooltip is below the
# pointer, thus the pointer goes straight down from the widget into the
# tooltip, and a click on a line runs its command. Run it with the
# environment of `kwm-test-tooltip` in tests.nix. Refer to
# src/kwm/tooltip_place.zig.
#
# Usage: kwm-test-tooltip
set -euo pipefail

TEST_NAME=tooltip

# config.def.zon with one widget in the center of the bar: a script with a
# tooltip of two lines. A click on a line makes the file clicked-<line> in
# XDG_RUNTIME_DIR. The widget is wide, thus x 640 (the center of the output)
# is on it. The tooltip shows at once.
TEST_KWM_CONFIG=$(python3 - "$TEST_DEFAULT_CONFIG" <<'PY'
import json
import re
import sys

line = json.dumps({
    "text": "X" * 40,
    "tooltip": "line one\nline two",
    "tooltip_on_click": [
        'touch "$XDG_RUNTIME_DIR/clicked-1"',
        'touch "$XDG_RUNTIME_DIR/clicked-2"',
    ],
})
script = f"printf '%s\\n' '{line}'; sleep 1000"
config = open(sys.argv[1]).read()
# A ZON string has the escapes of a JSON string.
widget = f"            .{{ .script = .{{ .exec = {json.dumps(script)}, .interval = 0, .return_type = .json }} }},\n"
config, count = re.subn(r"(        \.center = \.\{\n).*?(        \},\n)", lambda m: m[1] + widget + m[2],
                        config, count=1, flags=re.S)
if count != 1:
    sys.exit("kwm-test-tooltip: config.def.zon has no center widgets")
delay = "        .tooltip_delay = 500,\n"
if delay not in config:
    sys.exit("kwm-test-tooltip: config.def.zon has no tooltip_delay line")
print(config.replace(delay, "        .tooltip_delay = 0,\n", 1), end="")
PY
)

# shellcheck source=test-lib.sh
source "$TEST_LIB"

start_input
sleep 1

# The pointer on the widget. The tooltip shows at once.
input move 640 8
input move 641 8
sleep 1
grim "$work/hover.png"

# The rows of the tooltip at x 636, below the bar (y 20): the pixels that
# are not black. The cursor is at the right of x 641, thus not at x 636.
# Without the fix, the tooltip is at the right of the cursor, and x 636 has
# no tooltip.
read -r top bottom <<<"$(python3 - "$work/hover.png" <<'PY'
import sys
from PIL import Image
image = Image.open(sys.argv[1]).convert("RGB")
rows = [y for y in range(20, 200) if image.getpixel((636, y)) != (0, 0, 0)]
print(rows[0], rows[-1]) if rows else print("none none")
PY
)"
if [ "$top" = none ]; then
  echo "FAIL: the tooltip is below the pointer (no tooltip at x 636)"
  failed=1
else
  echo "ok: the tooltip is below the pointer (rows $top to $bottom)"
  # Straight down to the first line: a quarter of the tooltip.
  target=$((top + (bottom - top) / 4))
  for y in $(seq 12 4 "$target") "$target"; do
    input move 641 "$y"
  done
  sleep 0.5
fi
input press
input release

for _ in $(seq 20); do
  [ -e "$XDG_RUNTIME_DIR/clicked-1" ] && break
  sleep 0.1
done
if [ -e "$XDG_RUNTIME_DIR/clicked-1" ]; then
  echo "ok: the pointer goes straight down into the tooltip, and a click runs the command of the line"
else
  echo "FAIL: the pointer goes straight down into the tooltip, and a click runs the command of the line ($(ls "$XDG_RUNTIME_DIR" | grep clicked || echo 'no command ran'))"
  failed=1
fi

if [ "$failed" -ne 0 ]; then
  echo "kwm-test-tooltip: the log of kwm:" >&2
  grep -E "tooltip" "$work/river.log" | tail -20 >&2 || true
  exit 1
fi
echo "kwm-test-tooltip: all tests passed"
