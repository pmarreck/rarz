{
  description = "rarz - clean-room RAR archive toolkit";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    corruption-reader.url = "git+ssh://git@github.com/pmarreck/corruption_reader.git?rev=21ee639537644c81ada3e780c19608817dda92ca";
    zig-overlay = {
      url = "github:mitchellh/zig-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, flake-utils, zig-overlay, corruption-reader }:
    flake-utils.lib.eachSystem [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" ] (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          config.allowUnfreePredicate = pkg:
            builtins.elem (nixpkgs.lib.getName pkg) [ "rar" "unrar" ];
        };
        zig = zig-overlay.packages.${system}."0.16.0";
        rarProducer = import ./nix/rar-producer.nix { inherit pkgs; };

        pname = "rarz";
        version = "0.1.0";

        sourceFilter = import ./nix/source-filter.nix;
        sourceBoundaryTests = import ./tests/unit/source-filter.nix sourceFilter;
        compilationSource = pkgs.lib.cleanSourceWith {
          name = "rarz-build-source";
          src = self;
          filter = path: type:
            sourceFilter (if toString path == toString self then ""
              else pkgs.lib.removePrefix "${self}/" (toString path)) type;
        };

        isDarwin = pkgs.stdenv.isDarwin;

        zigDepsHash = "sha256-LVJqd/hSp1YI2XQqsFRXLfXomoM3SDP02ppmhr7D/Us=";

        zigDeps = pkgs.stdenv.mkDerivation {
          pname = "${pname}-zig-deps";
          inherit version;
          src = compilationSource;
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

        nativeTarget = if pkgs.stdenv.isLinux then "${pkgs.stdenv.hostPlatform.parsed.cpu.name}-linux-musl"
          else "${pkgs.stdenv.hostPlatform.parsed.cpu.name}-macos";
        mkRarz = { optimize, target ? nativeTarget, testArtifacts ? false }: pkgs.stdenv.mkDerivation {
          inherit pname version;
          src = compilationSource;

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
            zig build ${pkgs.lib.optionalString testArtifacts "test-artifacts"} --prefix $out -Doptimize=${optimize} -Dtarget=${target}
          '';

          installPhase = ''
            mkdir -p $out/include
            cp include/rarz.h $out/include/rarz.h
          '';
        };

        rarz = mkRarz { optimize = "ReleaseFast"; };
        targetPackages = builtins.listToAttrs (pkgs.lib.concatMap (target:
          map (profile: {
            name = "${target.pf}${if target ? variant then "-${target.variant}" else ""}-${profile}";
            value = mkRarz { optimize = profile; target = target.triple; };
          }) [ "ReleaseFast" "ReleaseSafe" "Debug" ]
        ) (builtins.fromJSON (builtins.readFile ./scripts/targets.json)));

        publicationProducts = pkgs.writeText "rarz-build-products.json" (builtins.toJSON
          (builtins.listToAttrs (map (target: {
            name = target.pf;
            value = targetPackages."${target.pf}${if target ? variant then "-${target.variant}" else ""}-ReleaseFast";
          }) (builtins.fromJSON (builtins.readFile ./scripts/targets.json)))));

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
          src = compilationSource;

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
        packages = targetPackages // {
          default = rarz;
          test = mkRarz { optimize = "ReleaseSafe"; };
          test-artifacts = mkRarz { optimize = "ReleaseSafe"; testArtifacts = true; };
        };

        checks = {
          default = checks-test;
          package-smoke = checks-package;
          classifiers = checks-classifiers;
          v70-controls = pkgs.runCommand "rarz-v70-controls" {
            nativeBuildInputs = [ pkgs.bash pkgs.coreutils pkgs.diffutils pkgs.gnugrep pkgs.jq corruption-reader.packages.${system}.default ];
          } ''
            cp -R ${self} source
            chmod -R u+w source
            cd source
            patchShebangs tests
            bash tests/cli/test_v70_controls.sh
            mkdir -p $out
          '';
          test-driver = pkgs.runCommand "rarz-test-driver" {
            nativeBuildInputs = [ pkgs.bash pkgs.coreutils ];
          } ''
            cd ${self}
            bash tests/cli/test_test_driver.sh
            mkdir -p $out
          '';
          build-publication = assert sourceBoundaryTests; pkgs.runCommand "rarz-build-publication" {
            nativeBuildInputs = [ pkgs.bash pkgs.coreutils pkgs.jq pkgs.llvmPackages.llvm
              (pkgs.luajit.withPackages (ps: [ ps.lua-cjson ])) ];
          } ''
            cp -R ${self} source
            chmod -R u+w source
            cd source
            bash tests/integration/build-matrix ${publicationProducts} ${mkRarz { optimize = "ReleaseSafe"; }} ${mkRarz { optimize = "Debug"; }}
            mkdir -p $out
          '';
        } // pkgs.lib.optionalAttrs (system == "x86_64-linux") {
          windows-metadata = pkgs.runCommand "rarz-windows-metadata" {
            nativeBuildInputs = [ pkgs.bash pkgs.coreutils pkgs.diffutils rarProducer pkgs.wineWow64Packages.stable ];
          } ''
            cd ${self}
            bash tests/integration/windows-metadata ${targetPackages.mswin-amd64-ReleaseFast}/bin/rarz.exe
            mkdir -p $out
          '';
        };

        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            zig
            unrar
            hyperfine
            (luajit.withPackages (ps: [ ps.lua-cjson ]))
            jq
            coreutils
            gzip
            findutils
            file
            llvmPackages.llvm
          ] ++ pkgs.lib.optionals pkgs.stdenv.isLinux [ pkgs.bubblewrap ]
          ++ pkgs.lib.optionals (builtins.hasAttr system corruption-reader.packages) [
            corruption-reader.packages.${system}.default
          ] ++ pkgs.lib.optionals (builtins.elem system [ "x86_64-linux" "x86_64-darwin" "aarch64-darwin" ]) [
            rarProducer
          ];
        };
      }
    );
}
