{
  description = "rarz - clean-room RAR archive toolkit";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    zig-overlay = {
      url = "github:mitchellh/zig-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, flake-utils, zig-overlay }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          config.allowUnfreePredicate = pkg:
            builtins.elem (nixpkgs.lib.getName pkg) [ "rar" "unrar" ];
        };
        zig = zig-overlay.packages.${system}."0.16.0";

        pname = "rarz";
        version = "0.1.0";

        isDarwin = pkgs.stdenv.isDarwin;

        zigDepsHash = "sha256-LVJqd/hSp1YI2XQqsFRXLfXomoM3SDP02ppmhr7D/Us=";

        zigDeps = pkgs.stdenv.mkDerivation {
          pname = "${pname}-zig-deps";
          inherit version;
          src = self;
          nativeBuildInputs = with pkgs; [ zig git cacert ]
            ++ pkgs.lib.optionals isDarwin [
              pkgs.darwin.cctools
              pkgs.apple-sdk
            ];
          outputHashMode = "recursive";
          outputHashAlgo = "sha256";
          outputHash = zigDepsHash;
          buildPhase = ''
            export HOME=$TMPDIR
            export ZIG_GLOBAL_CACHE_DIR=$out
            export SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt
            export GIT_SSL_CAINFO=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt
            zig build --fetch=all
          '';
          dontInstall = true;
          dontFixup = true;
        };

        rarz = pkgs.stdenv.mkDerivation {
          inherit pname version;
          src = self;

          nativeBuildInputs = [ zig ]
            ++ pkgs.lib.optionals isDarwin [
              pkgs.darwin.cctools
              pkgs.apple-sdk
            ];

          dontConfigure = true;
          dontFixup = true;

          buildPhase = ''
            export HOME="$TMPDIR"
            export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-cache
            mkdir -p $ZIG_GLOBAL_CACHE_DIR
            cp -r ${zigDeps}/* $ZIG_GLOBAL_CACHE_DIR/
            chmod -R u+w $ZIG_GLOBAL_CACHE_DIR
            zig build --prefix $out -Doptimize=ReleaseFast ${pkgs.lib.optionalString pkgs.stdenv.isLinux "-Dtarget=${pkgs.stdenv.hostPlatform.parsed.cpu.name}-linux-musl"}
          '';

          installPhase = ''
            mkdir -p $out/lib $out/include
            cp zig-out/lib/librarz.a $out/lib/ || true
            cp include/rarz.h $out/include/ || true
          '';
        };

        checks-package = pkgs.runCommand "${pname}-package-smoke" {
          nativeBuildInputs = [ pkgs.bash pkgs.coreutils pkgs.gnugrep ]
            ++ pkgs.lib.optionals pkgs.stdenv.isLinux [ pkgs.binutils ];
        } ''
          bash ${self}/tests/integration/package-smoke ${rarz}/bin/rarz
          mkdir -p $out
          echo "installed package execution passed" > $out/result
        '';

        checks-classifiers = pkgs.runCommand "${pname}-validation-outcomes" {
          nativeBuildInputs = [ pkgs.bash pkgs.coreutils pkgs.unrar ];
        } ''
          cd ${self}
          RARZ=${rarz}/bin/rarz bash tests/cli/test_validation_outcome.sh
          RARZ=${rarz}/bin/rarz bash tests/cli/test_required_cases.sh
          mkdir -p $out
          echo "validation outcome controls passed" > $out/result
        '';

        checks-test = pkgs.stdenv.mkDerivation {
          pname = "${pname}-tests";
          inherit version;
          src = self;

          nativeBuildInputs = [ zig ]
            ++ pkgs.lib.optionals isDarwin [
              pkgs.darwin.cctools
              pkgs.apple-sdk
            ];

          dontConfigure = true;
          dontFixup = true;

          buildPhase = ''
            export HOME="$TMPDIR"
            export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-cache
            mkdir -p $ZIG_GLOBAL_CACHE_DIR
            cp -r ${zigDeps}/* $ZIG_GLOBAL_CACHE_DIR/
            chmod -R u+w $ZIG_GLOBAL_CACHE_DIR
            # FLEET FLOOR — tests run ReleaseSafe (fleet finding 2026-07-01).
            # ReleaseFast compiles OUT the runtime safety checks (integer
            # overflow, bounds, illegal cast), so a green ReleaseFast suite
            # cannot observe UB — it passes *because* the check that would have
            # failed it is gone. rarz itself was the motivating case: three
            # real crashers sat behind a fully green ReleaseFast suite.
            #
            # Enforced HERE, not as a per-module `.optimize` in build.zig: Zig
            # honours per-module optimize, so pinning only the test module
            # would leave imported library code at ReleaseFast. The command
            # line flips the entire test compilation at once.
            #
            # Shipped artifact and benchmarks stay ReleaseFast.
            timeout 600 zig build test -Doptimize=ReleaseSafe || { echo "Tests failed"; exit 1; }
          '';

          installPhase = ''
            mkdir -p $out
            echo "tests passed" > $out/result
          '';
        };
      in {
        packages.default = rarz;

        checks.default = checks-test;
        checks.package-smoke = checks-package;
        checks.classifiers = checks-classifiers;

        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            zig
            unrar
            hyperfine
          ] ++ pkgs.lib.optionals (builtins.elem system [ "x86_64-linux" "x86_64-darwin" "aarch64-darwin" ]) [
            rar
          ];
        };
      }
    );
}
