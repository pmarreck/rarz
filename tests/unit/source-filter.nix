keep:
let
  requiredFiles = [
    "build.zig" "build.zig.zon" "LICENSE" "src/lib/root.zig"
    "src/future/new.zig" "include/rarz.h" "include/future/new.h"
    "tests/fixtures/archive.rar" "tests/fixtures/nested/future.bin"
    "tests/microbench.zig" "tests/diagnose_crc.zig"
  ];
  requiredDirectories = [ "" "src" "include" "tests" "tests/fixtures" ];
  excluded = [
    "PLAN.md" "README.md" "docs/future/new.md" ".dirtree-state"
    "tests/cli/new.sh" "tests/fixtures_large/archive.rar" "tests/fixtures-old/a.rar"
    "src-old/root.zig" "include-old/header.h" "other/src/file.zig"
    "build.zig.backup" "flake.nix" "flake.lock" "nix/source-filter.nix"
    "bin/linux-amd64/rarz" ".git/config"
  ];
  declaredPaths = builtins.concatMap (part: if builtins.isList part then part else [])
    (builtins.split ''b[.]path[(]"([^"]+)"[)]'' (builtins.readFile ../../build.zig));
in
  builtins.all (path: keep path "regular") requiredFiles
  && builtins.all (path: keep path "directory") requiredDirectories
  && builtins.all (path: !(keep path "regular") && !(keep path "directory")) excluded
  && !(keep "tests" "regular")
  && builtins.all (path: keep path "regular" || keep path "directory") declaredPaths
