# Builds kwm, a window manager for river 0.4 and later. kwm is DWM-like, with
# tags and a tile layout. Upstream is https://github.com/kewuaa/kwm.
#
# `kwmSource` and `version` are for a flake that has kwm as an input, for
# example:
#
#   pkgs.callPackage "${inputs.kwm}/nix" { kwmSource = inputs.kwm; }
#
# The flake of kwm gives the package also in an overlay: nix/overlays.nix.
#
# Without them, the recipe builds the files of this repository. (callPackage
# gives the packages with the names of the arguments, and nixpkgs has a package
# "src".)
#
# Options:
#   - withBackground: kwm draws a solid background in the color of the
#     desktop. It covers the layer-shell surfaces on the bottom layer, for
#     example a wallpaper. Default: false.
#
# After a change of the Zig dependencies in build.zig.zon, the hash below
# changes. Then the build fails and shows the new hash. Put that hash below.
{
  lib,
  callPackage,
  stdenv,
  zig_0_16,
  pkg-config,
  wayland,
  wayland-protocols,
  wayland-scanner,
  libxkbcommon,
  fcft,
  pixman,
  systemdLibs,
  libspng,
  resvg,
  libghostty-vt,
  kwmSource ? ../.,
  version ? "0-unstable",
  withBackground ? false,
}:
let
  zigSystemDeps = callPackage ./zig-system-deps.nix { };

  # The files of the build. The screenshots and the Nix files are not part of
  # it, so a new screenshot does not build kwm again.
  source = builtins.path {
    name = "kwm-source";
    path = kwmSource;
    filter =
      path: type:
      !(builtins.elem (baseNameOf path) [
        ".git"
        ".zig-cache"
        "zig-out"
        "zig-pkg"
        "result"
        "nix"
        "screenshots"
        "flake.nix"
        "flake.lock"
      ]);
  };
in
stdenv.mkDerivation (finalAttrs: {
  pname = "kwm";
  inherit version;
  src = source;

  deps = zigSystemDeps {
    inherit (finalAttrs) pname version src;
    # fcft and pixman are lazy dependencies. Only the bar uses them.
    fetchAll = true;
    hash = "sha256-Lz/Wcy40rxN81n/mBj4YJVbyGOolHzSFZMs93T1h0oQ=";
  };

  strictDeps = true;

  nativeBuildInputs = [
    pkg-config
    wayland-scanner
    zig_0_16
  ];

  buildInputs = [
    fcft
    libxkbcommon
    pixman
    # sd-bus for the tray, and the icons of the tray.
    systemdLibs
    libspng
    resvg
    # The terminal of the overlay.
    libghostty-vt
    wayland
    # build.zig asks pkg-config for the protocol directory of wayland-scanner.
    wayland-scanner
    wayland-protocols
  ];

  zigBuildFlags = [
    "--system"
    "${finalAttrs.deps}"
    "-Dversion-string=${finalAttrs.version}"
    # A solid background covers the layer-shell surfaces on the bottom layer,
    # for example a wallpaper.
    "-Dbackground=${lib.boolToString withBackground}"
    # kwm starts kwim to apply the input rules of the kwm configuration.
    "-Dkwim=true"
    # The tray in the bar (StatusNotifierItem).
    "-Dtray=true"
    # The overlay of the Super key.
    "-Doverlay=true"
  ];

  # `zig build test`, with the dependencies of the build. Without --system,
  # zig tries to download them.
  doCheck = true;
  zigCheckFlags = finalAttrs.zigBuildFlags;

  meta = {
    description = "DWM-like dynamic tiling window manager for river";
    homepage = "https://github.com/kewuaa/kwm";
    license = lib.licenses.gpl3Only;
    mainProgram = "kwm";
    platforms = lib.platforms.linux;
  };
})
