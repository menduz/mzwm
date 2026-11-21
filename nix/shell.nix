# The development shell. `nix develop` gives the commands that build kwm and
# take the screenshots.
{
  callPackage,
  mkShell,
  kwmZig ? callPackage ./zig.nix { },
  pkg-config,
  nixfmt-rfc-style,
  screenshot,
  update-screenshots,
}:
mkShell {
  packages = [
    kwmZig
    pkg-config
    nixfmt-rfc-style
    screenshot
    update-screenshots
  ];

  shellHook = ''
    cat <<'TEXT'
    kwm

      nix build                 build kwm
      nix build .#screenshots   take the screenshots in the sandbox
      update-screenshots        take them and copy them to screenshots/
      kwm-screenshot <dir>      the screenshot script, outside the sandbox
      nix fmt                   format the Nix files
    TEXT
  '';
}
