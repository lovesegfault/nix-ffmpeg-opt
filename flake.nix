{
  inputs = {
    flake-compat = {
      url = "github:edolstra/flake-compat";
      flake = false;
    };
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    git-hooks = {
      url = "github:cachix/git-hooks.nix";
      inputs = {
        flake-compat.follows = "flake-compat";
        nixpkgs-stable.follows = "nixpkgs";
        nixpkgs.follows = "nixpkgs";
      };
    };
    utils.url = "github:numtide/flake-utils";
  };

  outputs = inputs: with inputs;
    utils.lib.eachSystem [ "x86_64-linux" ]
      (localSystem:
        let
          ffmpegConfig = {
            withFdkAac = true;
            withSvtav1 = true;
            withUnfree = true;

            # These cause infinite recursions, or depend on other ffmpeg
            # versions
            withSdl2 = false;
            withQuirc = false;
            withChromaprint = false;
            withOpenal = false;
            withFrei0r = false;

            # These balloon the closure size
            withCuda = false;
            withCudaLLVM = false;
            withSamba = false;

            # # These don't work on pkgsStatic
            # withOpengl = false;
            # withVaapi = false;
            # withMfx = false;
            # withAvisynth = false;
            # withPulse = false;
            # withFlite = false;
            # withOpenmpt = false;
            # withPlacebo = false;
            # withSvg = false;
          };

          optimizePackageClosure = pkg:
            let
              inherit (inputs.nixpkgs) lib;

              appendFlags = new: old:
                if lib.isString old then lib.concatStringsSep " " ([ old ] ++ new)
                else if lib.isList old then lib.concatStringsSep " " (old ++ new)
                else (lib.concatStringsSep " " new);

              optCFlags = [
                "-march=x86-64-v3"
              ] ++ (lib.optionals (pkg.stdenv.cc.isGNU or false) [
                "-fgraphite-identity"
                "-floop-nest-optimize"
              ]);

              appendOptimizedFlags = appendFlags optCFlags;

              brokenPkgNames = [
                "cracklib"
                "e2fsprogs"
                "glib"
                "gnutls"
                "sharutils"
              ];

              optimizedBuildInputs = p: lib.optionalAttrs (p ? buildInputs) {
                buildInputs = map optimizePackageClosure p.buildInputs;
              };

              optimizedPropagatedBuildInputs = p: lib.optionalAttrs (p ? propagatedBuildInputs) {
                propagatedBuildInputs = map optimizePackageClosure p.propagatedBuildInputs;
              };

              optimizedFlags = p:
                if p ? env then {
                  env.NIX_CFLAGS_COMPILE = appendOptimizedFlags (p.env.NIX_CFLAGS_COMPILE or null);
                } else {
                  NIX_CFLAGS_COMPILE = appendOptimizedFlags (p.NIX_CFLAGS_COMPILE or null);
                };
            in
            if (! (lib.isDerivation pkg)) then pkg
            else if (pkg ? pname && (builtins.elem pkg.pname brokenPkgNames)) then pkg
            else
              pkg.overrideAttrs (p:
                (optimizedFlags p)
                // (optimizedBuildInputs p)
                // (optimizedPropagatedBuildInputs p)
              )
          ;

          # -march=znver2 --param=l1-cache-line-size=64 --param=l1-cache-size=32 --param=l2-cache-size=512
          pkgs = import nixpkgs {
            inherit localSystem;
            config = { allowUnfree = true; };
            overlays = [
              (final: prev: {
                ffmpeg-optimized = (optimizePackageClosure final.ffmpeg_7-full).override ffmpegConfig;
              })
              (final: prev: {
                svt-av1 = prev.svt-av1.overrideAttrs (_: rec {
                  version = "2.1.0";
                  src = final.fetchFromGitLab {
                    owner = "AOMediaCodec";
                    repo = "SVT-AV1";
                    rev = "v${version}";
                    hash = "sha256-yfKnkO8GPmMpTWTVYDliERouSFgQPe3CfJmVussxfHY=";
                  };
                });
              })
            ];
          };
        in
        {
          packages = {
            default = self.packages.${localSystem}.ffmpeg-optimized;
            inherit (pkgs) ffmpeg-optimized;
          };

          legacyPackages = pkgs;

          devShells.default = pkgs.mkShell {
            name = "nix-ffmpeg-opt";
            nativeBuildInputs = with pkgs; [
              nil
              nix-tree
              nixpkgs-fmt
              statix
            ];
          };

          checks = {
            pre-commit = git-hooks.lib.${localSystem}.run {
              src = ./.;
              hooks = {
                actionlint.enable = true;
                nixpkgs-fmt.enable = true;
                statix.enable = true;
              };
            };
          };
        }
      );

}
