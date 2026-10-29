# Tests the class "badge" of a script widget: the text "CAM MIC" in white on
# a red fill, as high as the bar. With "blink", the widget changes between
# the fill and the text of the bar on the background of the bar. The text
# stays at the same place in the two phases. Run it with the environment of
# `kwm-test-badge` in tests.nix. Refer to src/kwm/widget_class.zig.
#
# The bar of config.def.zon has the text color #a1a1a1 and the background
# #0e1419. The critical color is #ff3333, the text of a badge #ffffff.
#
# Usage: kwm-test-badge
#
# With TEST_SCREENSHOT_DIR, the test writes badge-on.png and badge-off.png
# there: the screen in the two phases.
set -euo pipefail

TEST_NAME=badge

# config.def.zon with only a flashing badge at the right end.
TEST_KWM_CONFIG=$(python3 - "$TEST_DEFAULT_CONFIG" <<'PY'
import json
import re
import sys

line = '{"text": "CAM MIC", "class": ["critical", "badge", "blink"]}'
exec_ = "echo '" + line + "'; sleep infinity"
widget = ".{ .script = .{ .return_type = .json, .exec = " + json.dumps(exec_) + " } }"
config, count = re.subn(r"^        \.end = \.\{\n.*?^        \},\n",
                        lambda _: "        .end = .{ " + widget + " },\n",
                        open(sys.argv[1]).read(), count=1, flags=re.M | re.S)
if count != 1:
    sys.exit("kwm-test-badge: config.def.zon has no end widgets")
print(config, end="")
PY
)

# shellcheck source=test-lib.sh
source "$TEST_LIB"

# phase <png>: "on x0 x1 height white" for a red fill from the top of the
# screen (its columns, its rows, and the number of white pixels in it),
# "off x0 x1" for the text of the bar without red (the columns of the text
# at the right end), or "none".
phase() {
  python3 - "$1" <<'PY'
import sys
from PIL import Image
image = Image.open(sys.argv[1]).convert("RGB")
pixels = image.load()
width = image.size[0]
red, white = (0xff, 0x33, 0x33), (0xff, 0xff, 0xff)
fg = (0xa1, 0xa1, 0xa1)
xs = [x for x in range(max(0, width - 400), width) if pixels[x, 0] == red]
if xs:
    x0, x1 = min(xs), max(xs)
    height = 0
    while all(pixels[x, height] in (red, white) for x in (x0, x1)):
        height += 1
    count = sum(pixels[x, y] == white for x in range(x0, x1 + 1) for y in range(height))
    print("on", x0, x1, height, count)
    sys.exit()
xs = [x for x in range(max(0, width - 400), width) for y in range(0, 24) if pixels[x, y] == fg]
print("off", min(xs), max(xs)) if xs else print("none")
PY
}

on="" off=""
for _ in $(seq 50); do
  grim "$work/bar.png"
  result=$(phase "$work/bar.png")
  case $result in
    on\ *) on=$result; cp "$work/bar.png" "$work/on.png" ;;
    off\ *) off=$result; cp "$work/bar.png" "$work/off.png" ;;
  esac
  [ -n "$on" ] && [ -n "$off" ] && break
  sleep 0.07
done
if [ -n "${TEST_SCREENSHOT_DIR:-}" ]; then
  [ -f "$work/on.png" ] && cp "$work/on.png" "$TEST_SCREENSHOT_DIR/badge-on.png"
  [ -f "$work/off.png" ] && cp "$work/off.png" "$TEST_SCREENSHOT_DIR/badge-off.png"
fi

read -r _ fill0 fill1 height white <<<"${on:-on 0 0 0 0}"
read -r _ text0 text1 <<<"${off:-off 0 0}"
if [ -n "$on" ] && [ "$height" -ge 14 ] && [ "$white" -ge 40 ]; then
  echo "ok: the badge is white text on a red fill from the top of the bar ($on)"
else
  echo "FAIL: the badge is white text on a red fill from the top of the bar (${on:-no red fill})"
  failed=1
fi
if [ -n "$off" ]; then
  echo "ok: in the off phase, the text is in the color of the bar without the fill ($off)"
else
  echo "FAIL: in the off phase, the text is in the color of the bar without the fill (no phase without red)"
  failed=1
fi
if [ -n "$on" ] && [ -n "$off" ] && [ "$text0" -gt "$fill0" ] && [ "$text1" -lt "$fill1" ]; then
  echo "ok: the text of the off phase is inside the fill of the on phase, with a space at each side"
else
  echo "FAIL: the text of the off phase is inside the fill of the on phase, with a space at each side (fill $fill0-$fill1, text $text0-$text1)"
  failed=1
fi

if [ "$failed" -ne 0 ]; then
  echo "kwm-test-badge: the log of kwm:" >&2
  grep -E "widget|script" "$work/river.log" | tail -30 >&2 || true
  exit 1
fi
echo "kwm-test-badge: all tests passed"
