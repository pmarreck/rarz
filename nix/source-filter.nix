# Relative path and filesystem type for the compilation source boundary.
path: type:
  builtins.elem path [ "build.zig" "build.zig.zon" "LICENSE" "tests/microbench.zig" "tests/diagnose_crc.zig" ]
  || (type == "directory" && builtins.elem path [ "" "src" "include" "tests" "tests/fixtures" ])
  || builtins.match "(src|include|tests/fixtures)/.*" path != null
