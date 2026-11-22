# Pin kwm's compiler independently of the consumer's nixpkgs. Reuse the
# nixpkgs build hook and dependency fetcher with the official release binary.
{
  lib,
  stdenvNoCC,
  fetchurl,
  coreutils,
  zig_0_16,
}:
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "zig";
  version = "0.17.1";

  src = fetchurl {
    url = "https://ziglang.org/download/${finalAttrs.version}/zig-${stdenvNoCC.hostPlatform.system}-${finalAttrs.version}.tar.xz";
    sha256 =
      {
        x86_64-linux = "3581863e3cbcfd0fce0efc682ce7e9e93da96668a977791d356a26d2a7e9b17a";
        aarch64-linux = "a1546d5646eb184437918d6635ca6b762a0e889eac09cef720ee7a1ed3fe7795";
      }
      .${stdenvNoCC.hostPlatform.system};
  };

  inherit (zig_0_16) setupHook env;
  dontConfigure = true;
  dontBuild = true;
  dontStrip = true;

  # Native libc detection must also work inside the Nix build sandbox.
  postPatch = ''
    substituteInPlace lib/std/zig/system.zig \
      --replace-fail "/usr/bin/env" "${lib.getExe' coreutils "env"}"
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p "$out/bin" "$out/lib"
    cp zig "$out/bin/zig"
    cp -r lib "$out/lib/zig"
    runHook postInstall
  '';

  # `zig build` compiles its build runner (the maker) with LLVM on one core,
  # in about 80 seconds, and keeps it in the global cache. Each Nix build
  # starts with an empty global cache. Thus compile the maker here one time,
  # with the zig of $out (the cache key contains its lib directory). The setup
  # hook copies this cache into the global cache of each build. Zig does a
  # check of the contents of the files, thus the cache stays valid after Nix
  # changes their times.
  postFixup = ''
    mkdir "$TMPDIR/empty"
    echo 'pub fn build(_: *@import("std").Build) void {}' > "$TMPDIR/empty/build.zig"
    (
      cd "$TMPDIR/empty"
      HOME="$TMPDIR" ZIG_GLOBAL_CACHE_DIR="$out/share/zig-global-cache" "$out/bin/zig" build
    )
    rm -rf "$out/share/zig-global-cache/tmp"

    cat >> "$out/nix-support/setup-hook" <<EOF

    zigCopyGlobalCache() {
      if [ -n "\''${ZIG_GLOBAL_CACHE_DIR-}" ]; then
        cp -r "$out/share/zig-global-cache/." "\$ZIG_GLOBAL_CACHE_DIR"
        chmod -R u+w "\$ZIG_GLOBAL_CACHE_DIR"
      fi
    }
    postConfigureHooks+=(zigCopyGlobalCache)
    EOF
  '';

  passthru.fetchDeps =
    args:
    (zig_0_16.fetchDeps args).overrideAttrs {
      nativeBuildInputs = [ finalAttrs.finalPackage ];
    };

  meta = {
    description = "Zig compiler pinned for kwm";
    homepage = "https://ziglang.org/";
    license = lib.licenses.mit;
    mainProgram = "zig";
    platforms = [
      "x86_64-linux"
      "aarch64-linux"
    ];
  };
})
