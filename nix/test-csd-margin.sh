# Tests the margin of a tiled window with client side decorations
# (border.csd_margin) with the raised border of 3 pixels and a margin of 2.
# Without the outline, the window takes the pixel of the outline: the margin
# is 1 pixel. With the outline, the margin is 2 pixels. Run it with the
# environment of `kwm-test-csd-margin` in tests.nix. Refer to
# src/kwm/decoration.zig.
#
# A window of test-client.py without --decoration has no xdg-decoration,
# thus it draws its own frame. With --decoration, kwm gives it server side
# decorations, and it has no margin.
#
# Usage: kwm-test-csd-margin
set -euo pipefail

TEST_NAME=csd-margin

# config_with <outline>: config.def.zon with the raised border of 3 pixels,
# a margin of 2, the outline <outline>, and Super+F11 for reload_config.
config_with() {
  python3 - "$TEST_DEFAULT_CONFIG" "$1" <<'PY'
import sys
text = open(sys.argv[1]).read()
changes = [
    ("        .width = 2,\n", "        .width = 3,\n"),
    ("        .csd_margin = 0,\n", "        .csd_margin = 2,\n"),
    ("        .style = .flat,\n", "        .style = .raised,\n"),
    ("            .outline = .all,\n", f"            .outline = .{sys.argv[2]},\n"),
    ("        .key = .{\n", "        .key = .{\n"
        '            .{ .keysym = "F11", .modifiers = .{ .mod4 = true }, '
        ".event = .{ .click = .{ .pressed = .reload_config } } },\n"),
]
for old, new in changes:
    if text.count(old) != 1:
        sys.exit(f"kwm-test-csd-margin: config.def.zon has not one line {old.strip()!r}")
    text = text.replace(old, new)
print(text, end="")
PY
}
TEST_KWM_CONFIG=$(config_with none)

# shellcheck source=test-lib.sh
source "$TEST_LIB"

field() {
  sed -E "s/.* $2=([^ ]+).*/\1/" "$work/$1.state"
}

# The widths of the two places of the tile layout: two windows with server
# side decorations.
open a --decoration
expect_state a " decoration=server " "the first window has server side decorations"
open b --decoration
expect_state b " decoration=server " "the second window has server side decorations"
sleep 1
widths=$(printf '%s\n' "$(field a width)" "$(field b width)" | sort -n | tr '\n' ' ')
close a
close b

# expect_margin <margin> <description>: the two windows with client side
# decorations are 2 * <margin> pixels narrower than their places.
expect_margin() {
  local got=
  for _ in $(seq 30); do
    got=$(printf '%s\n' "$(field c width)" "$(field d width)" | sort -n | tr '\n' ' ')
    read -r small large <<<"$widths"
    [ "$got" = "$((small - 2 * $1)) $((large - 2 * $1)) " ] && break
    sleep 0.2
  done
  if [ "$got" = "$((small - 2 * $1)) $((large - 2 * $1)) " ]; then
    echo "ok: $2"
  else
    echo "FAIL: $2 (places: $widths; windows: $got)"
    failed=1
  fi
}

open c
expect_state c " decoration=none " "the first window draws its own frame"
open d
expect_state d " decoration=none " "the second window draws its own frame"
expect_margin 1 "without the outline, the window takes the pixel of the outline"

# The outline again, after a reload of the configuration.
config_with csd >"$XDG_CONFIG_HOME/kwm/config.zon"
wtype -s 200 -M logo -s 100 -k F11 -s 100 -m logo
expect_margin 2 "with the outline, the margin keeps the pixel of the outline"

if [ "$failed" -ne 0 ]; then
  echo "kwm-test-csd-margin: the log of kwm:" >&2
  grep -E "config|margin|dimensions" "$work/river.log" | tail -20 >&2 || true
  exit 1
fi
echo "kwm-test-csd-margin: all tests passed"
