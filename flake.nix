{
  description = "rarz - clean-room RAR archive toolkit";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          config.allowUnfreePredicate = pkg:
            builtins.elem (nixpkgs.lib.getName pkg) [ "rar" "unrar" ];
        };

        rarz = pkgs.stdenv.mkDerivation {
          pname = "rarz";
          version = "0.1.0";
          src = self;

          nativeBuildInputs = [ pkgs.zig ];

          dontConfigure = true;
          dontFixup = true;

          buildPhase = ''
            export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-cache
            zig build --cache-dir .zig-cache -Doptimize=ReleaseFast
          '';

          checkPhase = ''
            export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-cache
            zig build test --cache-dir .zig-cache
          '';
          doCheck = true;

          installPhase = ''
            mkdir -p $out/bin $out/lib $out/include
            cp zig-out/bin/rarz $out/bin/
            cp zig-out/lib/librarz.a $out/lib/
            cp include/rarz.h $out/include/
          '';
        };
      in {
        packages.default = rarz;

        checks.default = rarz.overrideAttrs (old: {
          doCheck = true;
        });

        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            zig
            rar
            unrar
          ];
        };
      }
    );
}
