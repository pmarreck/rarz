{ pkgs }:
# The pinned Linux RAR 7.23 binary crashes after ELF rewriting. Execute the
# original producer with the pinned loader instead; this is test tooling only.
if !pkgs.stdenv.hostPlatform.isLinux then pkgs.rar else
pkgs.runCommand "rar-test-producer-${pkgs.rar.version}" {
  pname = "rar";
  nativeBuildInputs = [ pkgs.gnutar pkgs.gzip pkgs.makeWrapper ];
  meta.license = pkgs.rar.meta.license;
} ''
  tar -xzf ${pkgs.rar.src}
  mkdir -p "$out/bin" "$out/libexec" "$out/share/doc/rar"
  install -m755 rar/rar "$out/libexec/rar"
  install -m644 rar/license.txt rar/acknow.txt "$out/share/doc/rar/"
  makeWrapper ${pkgs.stdenv.cc.bintools.dynamicLinker} "$out/bin/rar" \
    --add-flags "--library-path ${pkgs.lib.makeLibraryPath [ pkgs.stdenv.cc.cc ]} $out/libexec/rar"
  cmp rar/rar "$out/libexec/rar"
  export HOME="$TMPDIR/home"
  mkdir -p "$HOME"
  "$out/bin/rar" > help.log 2>&1
  printf 'producer round-trip\n' > input
  "$out/bin/rar" a -m0 -idq probe.rar input > create.log 2>&1
  ${pkgs.unrar}/bin/unrar p -p- -inul probe.rar > restored
  cmp input restored
''
