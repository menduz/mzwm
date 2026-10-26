# Tests the gauge widget: two vertical bars (memory and CPU) at the right end
# of the bar. The CPU bar has a column of one pixel for each core, or more
# if there are fewer cores than the pixels of a glyph. Run it with the environment of `kwm-test-gauge` in tests.nix.
# Refer to src/kwm/gauge.zig.
#
# The bar of config.def.zon has the text color #a1a1a1, the tray icons of 16
# pixels, and the background #0e1419. The border is the text color at 35% on
# the background (#414549), the inactive color of the symbolic icons. The
# fill of a bar is the text color at 80% (#818181), or the warning or
# critical color.
#
# Usage: kwm-test-gauge
#
# With TEST_SCREENSHOT_DIR, the test writes gauge.png there: the screen with
# the gauge.
set -euo pipefail

TEST_NAME=gauge

# config.def.zon with only a gauge of the default values at the right end.
TEST_KWM_CONFIG=$(python3 - "$TEST_DEFAULT_CONFIG" <<'PY'
import re
import sys

config, count = re.subn(r"^        \.end = \.\{\n.*?^        \},\n",
                        "        .end = .{ .{ .gauge = .{} } },\n",
                        open(sys.argv[1]).read(), count=1, flags=re.M | re.S)
if count != 1:
    sys.exit("kwm-test-gauge: config.def.zon has no end widgets")
print(config, end="")
PY
)

# shellcheck source=test-lib.sh
source "$TEST_LIB"

# gauge <png>: the shape of the gauge at the right end of the bar, as
# "x0 x1 x2 top" (the three border columns and the top row), or "none".
# Then a line for each bar: "ok" when each column of its inside has the
# background above and the fill below.
shape() {
  python3 - "$1" <<'PY'
import sys
from PIL import Image
image = Image.open(sys.argv[1]).convert("RGB")
pixels = image.load()
width = image.size[0]
fg, bg = (0x41, 0x45, 0x49), (0x0e, 0x14, 0x19)
fills = {(0x81, 0x81, 0x81), (0xff, 0xb3, 0x54), (0xff, 0x33, 0x33)}
# A border column: 16 pixels of the border color, from the top row. The
# three border columns that are nearest to the right end.
columns = []
for x in range(width - 1, max(0, width - 400), -1):
    for top in range(0, 8):
        if all(pixels[x, top + dy] == fg for dy in range(16)) and pixels[x, top + 16] != fg:
            columns.insert(0, (x, top))
            break
    if len(columns) == 3:
        break
if len(columns) != 3 or len({t for _, t in columns}) != 1:
    print("none", columns)
    sys.exit()
(x0, top), (x1, _), (x2, _) = columns
print(x0, x1, x2, top)
for a, b in ((x0, x1), (x1, x2)):
    good = all(pixels[x, top] == fg and pixels[x, top + 15] == fg for x in range(a, b + 1))
    for x in range(a + 1, b):
        column = [pixels[x, top + 1 + dy] for dy in range(14)]
        # Background, then fill: no background below a fill pixel.
        seen_fill = False
        for c in column:
            if c in fills:
                seen_fill = True
            elif c == bg:
                good = good and not seen_fill
            else:
                good = False
    print("ok" if good else "bad")
PY
}

result=""
for _ in $(seq 25); do
  grim "$work/bar.png"
  result=$(shape "$work/bar.png")
  [ "${result%% *}" != none ] && break
  sleep 0.2
done
read -r x0 x1 x2 top <<<"$(head -1 <<<"$result")"
# TEST_SCREENSHOT_DIR keeps the screenshot of the bar.
if [ -n "${TEST_SCREENSHOT_DIR:-}" ]; then
  cp "$work/bar.png" "$TEST_SCREENSHOT_DIR/gauge.png"
fi
# Terminus at 9 points has glyphs of 6 pixels. The CPU bar has a pixel for
# each core of /proc/stat (as kwm reads them), but not fewer than 6.
cores=$(grep -c '^cpu[0-9]' /proc/stat)
cpu_width=$((cores > 6 ? cores : 6))
if [ "$x0" != none ] && [ $((x1 - x0 - 1)) = 6 ]; then
  echo "ok: the memory bar is a glyph wide"
else
  echo "FAIL: the memory bar is a glyph wide (inside: $((x1 - x0 - 1)))"
  failed=1
fi
if [ "$x0" != none ] && [ $((x2 - x1 - 1)) = "$cpu_width" ]; then
  echo "ok: the CPU bar has a column for each of the $cores cores, and is a glyph wide or more"
else
  echo "FAIL: the CPU bar has a column for each of the $cores cores, and is a glyph wide or more (inside: $((x2 - x1 - 1)), expected $cpu_width)"
  failed=1
fi
if [ "$(sed -n 2,3p <<<"$result" | tr '\n' ' ')" = "ok ok " ]; then
  echo "ok: each bar has the border, the background above and the fill below"
else
  echo "FAIL: each bar has the border, the background above and the fill below ($result)"
  failed=1
fi

if [ "$failed" -ne 0 ]; then
  echo "kwm-test-gauge: the log of kwm:" >&2
  grep -E "widget|gauge" "$work/river.log" | tail -30 >&2 || true
  exit 1
fi
echo "kwm-test-gauge: all tests passed"
