# Takes a screenshot of kwm: river with the headless backend of wlroots, kwm
# with config.def.zon, three terminals and three tray items. Run it with the
# environment of `kwm-screenshot` in screenshots.nix.
#
# Usage: kwm-screenshot <output directory> [<preset>]
#
# The presets, each one in <preset>.png:
#
#   kwm                     config.def.zon (the default border)
#   title-bar-flat-<theme>  the flat border of 1 pixel: an outline, without
#                           the 3D edges
#   title-bar-raised-<theme>
#                           the raised border of 3 pixels, without the outline
#   maximized-light         one terminal, that fills the output: it has no
#                           title bar, and the bar shows its title
#
# <theme> is dark (win-classic-dark) or light (win-classic-standard, the
# Windows Standard scheme). The bar takes its colors from the theme. A title
# bar preset also has a floating terminal.
set -euo pipefail

out=${1:?usage: kwm-screenshot <output directory> [<preset>]}
preset=${2:-kwm}
mkdir -p "$out"

case $preset in
  kwm) border=default theme= ;;
  title-bar-flat-dark) border=flat theme=win-classic-dark ;;
  title-bar-flat-light) border=flat theme=win-classic-standard ;;
  title-bar-raised-dark) border=raised theme=win-classic-dark ;;
  title-bar-raised-light) border=raised theme=win-classic-standard ;;
  maximized-light) border=raised theme=win-classic-standard ;;
  *)
    echo "kwm-screenshot: unknown preset: $preset" >&2
    exit 1
    ;;
esac

work=$(mktemp -d)
pids=()
cleanup() {
  for pid in "${pids[@]}"; do
    kill "$pid" 2>/dev/null || true
  done
  wait 2>/dev/null || true
  rm -rf "$work"
}
trap cleanup EXIT

# No setting of a desktop session comes in, so a run outside the sandbox gives
# the same pixels. For example kwm reads GTK_THEME for the raised borders.
unset GTK_THEME GTK2_RC_FILES XCURSOR_THEME XCURSOR_SIZE XCURSOR_PATH \
  DISPLAY WAYLAND_DISPLAY XDG_CURRENT_DESKTOP XDG_SESSION_TYPE XDG_DATA_HOME \
  XDG_STATE_HOME XDG_CACHE_HOME LD_PRELOAD LD_LIBRARY_PATH FAKETIME

# A home that holds no setting of the user. kwm reads config.def.zon.
export HOME=$work/home
export XDG_CONFIG_HOME=$work/config
export XDG_RUNTIME_DIR=$work/run
mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR"

# config.def.zon with other values in some lines: a rule that puts the
# window "OtherTag" on tag 3, and the border of the preset.
mkdir -p "$XDG_CONFIG_HOME/kwm"
python3 - "$DEFAULT_CONFIG" "$border" "$theme" >"$XDG_CONFIG_HOME/kwm/config.zon" <<'PY'
import sys

config = open(sys.argv[1]).read()
rules = "    .window_rules = .{\n"
changes = [(rules, rules + '        .{ .title = .{ .str = "OtherTag" }, .tag = 4 },\n')]
changes += {
    "default": [],
    "flat": [("        .width = 2,\n", "        .width = 1,\n")],
    "raised": [
        ("        .width = 2,\n", "        .width = 3,\n"),
        ("        .style = .flat,\n", "        .style = .raised,\n"),
        ("            .outline = .all,\n", "            .outline = .none,\n"),
    ],
}[sys.argv[2]]
# With a GTK theme, the bar takes its colors from xfwm4/themerc of the theme,
# and the title has the colors of a title bar.
if sys.argv[3]:
    changes.append(("        .gtk_colors = null,\n", "        .gtk_colors = .{},\n"))
    changes.append(("            .caption = false,\n", "            .caption = true,\n"))
for old, new in changes:
    if config.count(old) != 1:
        sys.exit(f"kwm-screenshot: config.def.zon has not one line {old.strip()!r}")
    config = config.replace(old, new)
print(config, end="")
PY

# The GTK theme of the title bars and of the raised border.
if [ -n "$theme" ]; then
  export GTK_THEME=$theme
  export XDG_DATA_DIRS=$XDG_DATA_DIRS:$THEME_DATA_DIRS
fi

export TZ=UTC
export LANG=C.UTF-8

# One output of 1280x720 pixels, without a GPU and without input devices.
export WLR_BACKENDS=headless
export WLR_RENDERER=pixman
export WLR_HEADLESS_OUTPUTS=1
export WLR_LIBINPUT_NO_DEVICES=1

# The session bus of the tray.
dbus-daemon --config-file="$DBUS_SESSION_CONF" --fork \
  --print-address=3 --print-pid=4 3>"$work/bus-address" 4>"$work/bus-pid"
pids+=("$(cat "$work/bus-pid")")
DBUS_SESSION_BUS_ADDRESS=$(cat "$work/bus-address")
export DBUS_SESSION_BUS_ADDRESS

# kwm gets a fixed clock, and fixed values for the CPU, the memory and the disk.
# The clock starts at 12:00:00 and runs, but the bar shows only the minutes.
# The other programs have the real clock.
cat >"$work/kwm" <<KWM
#!/bin/sh
export LD_PRELOAD="$FAKETIME_LIB:$PRELOAD_LIB"
export FAKETIME="@2026-10-04 12:00:00"
export FAKETIME_DONT_FAKE_MONOTONIC=1
exec kwm
KWM
chmod +x "$work/kwm"

river -no-xwayland -c "$work/kwm" >"$work/river.log" 2>&1 &
pids+=("$!")

# river makes the socket of the Wayland display.
for _ in $(seq 100); do
  socket=$(find "$XDG_RUNTIME_DIR" -maxdepth 1 -name 'wayland-*' ! -name '*.lock' -print -quit)
  [ -n "$socket" ] && break
  sleep 0.1
done
if [ -z "${socket:-}" ]; then
  echo "kwm-screenshot: river did not start" >&2
  cat "$work/river.log" >&2
  exit 1
fi
WAYLAND_DISPLAY=$(basename "$socket")
export WAYLAND_DISPLAY
sleep 1

# Three tray items with the icons of Adwaita.
python3 "$TRAY_SCRIPT" audio-volume-high network-wireless-signal-excellent bluetooth-active &
pids+=("$!")

# Three terminals, or one for the maximized preset. Each one opens after the
# one before, so the tile layout always gives the same places. Before them,
# a terminal on tag 3: the bar shows tag 3 in the color of a tag with windows.
cat >"$work/foot.ini" <<FOOT
font=DejaVu Sans Mono:size=9
pad=6x6
[cursor]
blink=no
FOOT
terminal() {
  foot --config="$work/foot.ini" "${@:2}" sh -c "$1; exec sleep infinity" &
  pids+=("$!")
  sleep 1
}
terminal 'true' --title=OtherTag
if [ "$preset" = maximized-light ]; then
  # With smart_gaps, the one window fills the output. kwm gives it no title
  # bar, and the bar shows its title.
  terminal 'printf "%s\n" "the one window fills the output" "the bar shows its title"' --title=Maximized
else
  terminal 'kwm -h'
  terminal 'printf "%s\n" "tags 1-9" "layouts: tile, grid, monocle, deck," "  scroller, centered master, float" "widgets: gauge (memory, cpu), clock," "  battery, disk, scripts, tray"'
  terminal 'printf "%s\n" "Super+Return  terminal" "Super+Space   launcher" "Super+1..9    tags" "Super+J/K     focus" "Super+Q       close"'
fi

# A floating terminal: config.def.zon makes a window with this title floating.
if [ "$preset" != kwm ] && [ "$preset" != maximized-light ]; then
  terminal 'printf "%s\n" "a floating window" "with a title bar"' --title=FloatingTerminal --window-size-chars=40x6
fi

# The widgets update each second, and the tray reads the icons.
sleep 3

grim "$out/$preset.png"
echo "kwm-screenshot: wrote $out/$preset.png"
