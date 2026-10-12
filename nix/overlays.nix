# The overlays of kwm. flake.nix gives them as `overlays`.
#
# `default` adds the package kwm.
{ self }:
{
  default = final: _prev: {
    kwm = final.callPackage ./. {
      version = "0-unstable-${self.lastModifiedDate or "dirty"}";
    };
  };
}
