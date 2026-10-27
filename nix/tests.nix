# The tests of kwm. They run kwm in river with the headless backend of
# wlroots.
#
# `kwm-test-<name>` runs test-<name>.sh, and `checks.<name>` runs it in the
# sandbox (`nix flake check`). test-lib.sh holds the shared part.
{
  runCommand,
  writeShellApplication,
  makeFontsConf,
  kwm,
  river,
  dbus,
  python3,
  coreutils,
  findutils,
  gnugrep,
  wtype,
  wlrctl,
  grim,
  procps,
  wayland-scanner,
  pkg-config,
  wlr-protocols,
  wayland-protocols,
  wlroots,
  terminus_font,
  dejavu_fonts,
}:
let
  python = python3.withPackages (ps: [
    ps.pywayland
    ps.pillow
    ps.dbus-next
  ]);

  # The pywayland modules of the virtual input protocols, for test-input.py,
  # and of wlr-layer-shell, for test-layer.py. wayland.xml is necessary for
  # the types of the core protocol, xdg-shell.xml for wlr-layer-shell.
  # pywayland-scanner finds the directory of wayland.xml with pkg-config.
  protocols =
    runCommand "kwm-test-protocols"
      {
        nativeBuildInputs = [
          python
          pkg-config
          wayland-scanner
        ];
      }
      ''
        mkdir -p $out/kwm_test_protocols
        touch $out/kwm_test_protocols/__init__.py
        pywayland-scanner -o $out/kwm_test_protocols -i \
          ${wayland-scanner}/share/wayland/wayland.xml \
          ${wlr-protocols}/share/wlr-protocols/unstable/wlr-virtual-pointer-unstable-v1.xml \
          ${wlr-protocols}/share/wlr-protocols/unstable/wlr-layer-shell-unstable-v1.xml \
          ${wayland-protocols}/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml \
          ${wlroots.src}/protocol/virtual-keyboard-unstable-v1.xml
      '';

  # kwm with the solid background, for the tests of the desktop color. The
  # package of the flake has no background. The tests of the package ran
  # already.
  kwmWithBackground = kwm.overrideAttrs (old: {
    zigBuildFlags = map (
      flag: if flag == "-Dbackground=false" then "-Dbackground=true" else flag
    ) old.zigBuildFlags;
    doCheck = false;
  });

  # The command kwm-test-<name> runs test-<name>.sh in the environment of the
  # tests, with the kwm package `kwmPackage`.
  mkTestWith =
    kwmPackage: name:
    writeShellApplication {
      name = "kwm-test-${name}";
      runtimeInputs = [
        kwmPackage
        river
        dbus
        python
        coreutils
        findutils
        gnugrep
        wtype
        wlrctl
        grim
        procps
      ];
      text = ''
        # The fonts of the bar in config.def.zon.
        export FONTCONFIG_FILE=${
          makeFontsConf {
            fontDirectories = [
              terminus_font
              dejavu_fonts
            ];
          }
        }
        export DBUS_SESSION_CONF=${dbus}/share/dbus-1/session.conf
        export TEST_CLIENT=${./test-client.py}
        export TEST_LIB=${./test-lib.sh}
        export TEST_INPUT=${./test-input.py}
        export TEST_LAYER=${./test-layer.py}
        export TEST_PORTAL=${./test-portal.py}
        export TEST_CAPTIONS=${./test-captions.py}
        export TEST_TRAY=${./test-tray.py}
        export TEST_DEFAULT_CONFIG=${../config.def.zon}
        export PYTHONPATH=${protocols}
        exec bash ${./. + "/test-${name}.sh"} "$@"
      '';
    };

  mkTest = mkTestWith kwm;

  # A check runs the test in the sandbox (`nix flake check`).
  mkCheck =
    name: description:
    runCommand "kwm-test-${name}"
      {
        nativeBuildInputs = [ tests.${name} ];
        meta.description = description;
      }
      ''
        kwm-test-${name}
        touch "$out"
      '';

  tests = {
    maximize = mkTest "maximize";
    focus = mkTest "focus";
    bar = mkTest "bar";
    title-bar = mkTest "title-bar";
    drag = mkTest "drag";
    tray = mkTest "tray";
    gauge = mkTest "gauge";
    # The test of the theme also looks at the desktop color.
    theme = mkTestWith kwmWithBackground "theme";
    deck = mkTest "deck";
    csd-margin = mkTest "csd-margin";
    tooltip = mkTest "tooltip";
    overlay = mkTest "overlay";
  };
in
tests
// {

  checks = {
    maximize = mkCheck "maximize" "The maximized state of the windows of kwm";
    focus = mkCheck "focus" "The keyboard focus of the windows of kwm";
    bar = mkCheck "bar" "A change of the status of the bar needs no manage sequence";
    title-bar = mkCheck "title-bar" "The title bar of a window with server side decorations";
    gauge = mkCheck "gauge" "The gauge widget draws two bars with one border between them, and a column for each core";
    tray = mkCheck "tray" "The collapsed tray shows the symbolic items, the items that need attention, and all items under the pointer";
    drag = mkCheck "drag" "A drag of a window by its title bar makes it floating, and an edge of the output makes it tiled";
    theme = mkCheck "theme" "kwm follows the GTK theme of the settings portal, also for the desktop color";
    deck = mkCheck "deck" "The stack of the deck layout is an accordion";
    csd-margin = mkCheck "csd-margin" "The margin of a window with client side decorations";
    tooltip = mkCheck "tooltip" "The pointer goes straight down into a tooltip with click commands";
    overlay = mkCheck "overlay" "Super down alone shows the band of the key bindings";
  };
}
