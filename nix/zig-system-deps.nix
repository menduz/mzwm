# Gives the Zig dependencies of a package in the layout for
# `zig build --system <dir>`.
#
# zig.fetchDeps gives the package cache of Zig. Zig keeps each
# package in that cache as a <hash>.tar.gz archive. `--system` needs a
# <hash> directory for each package. This derivation unpacks each archive.
{
  runCommand,
  zig_0_16,
  zig ? zig_0_16,
}:
args:
runCommand "${args.pname}-${args.version}-zig-system-deps" { } ''
  mkdir $out
  for dep in ${zig.fetchDeps args}/*; do
    case "$dep" in
      *.tar.gz) tar -xzf "$dep" -C $out ;;
      *) ln -s "$dep" $out/ ;;
    esac
  done
  # Zig 0.17 can retain the archive's top-level directory in the cache.
  # --system expects the manifest directly under the package hash.
  for dep in $out/*; do
    if [ ! -f "$dep/build.zig.zon" ]; then
      for root in "$dep"/*; do
        if [ -f "$root/build.zig.zon" ]; then
          mv "$root" "$dep.root"
          rmdir "$dep"
          mv "$dep.root" "$dep"
          break
        fi
      done
    fi
  done
''
