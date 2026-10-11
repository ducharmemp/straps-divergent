{
  description = "straps-divergent — fork a straps.nvim session's transcript into a parallel session";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    straps = {
      url = "github:ducharmemp/straps";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, straps }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

      mkPlugin = pkgs: pkgs.vimUtils.buildVimPlugin {
        pname = "straps-divergent";
        version = self.shortRev or self.dirtyShortRev or "dev";
        src = self;
        dependencies = [ straps.packages.${pkgs.stdenv.hostPlatform.system}.default ];
        meta = {
          description = "Fork a straps.nvim session's transcript into a parallel session";
          license = nixpkgs.lib.licenses.mit;
        };
      };
    in
    {
      packages = forAllSystems (pkgs: rec {
        straps-divergent = mkPlugin pkgs;
        default = straps-divergent;
      });

      overlays.default = final: prev: {
        vimPlugins = prev.vimPlugins // { straps-divergent = mkPlugin final; };
      };

      checks = forAllSystems (pkgs: {
        tests = pkgs.stdenvNoCC.mkDerivation {
          name = "straps-divergent-tests";
          src = self;
          nativeBuildInputs = [
            pkgs.neovim pkgs.git pkgs.curl
            pkgs.luajitPackages.busted pkgs.luajitPackages.nlua
          ];
          dontBuild = true;
          doCheck = true;
          checkPhase = ''
            export HOME=$TMPDIR
            export XDG_DATA_HOME=$TMPDIR/data XDG_STATE_HOME=$TMPDIR/state XDG_CACHE_HOME=$TMPDIR/cache
            export STRAPS_DIR=${straps}
            fail=0
            for t in tests/*_spec.lua; do
              echo "== $t"
              busted "$t" || fail=1
            done
            [ "$fail" = 0 ]
          '';
          installPhase = "touch $out";
        };
      });

      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = [
            pkgs.neovim pkgs.curl
            pkgs.luajitPackages.busted pkgs.luajitPackages.nlua
          ];
          STRAPS_DIR = "${straps}";
        };
      });
    };
}
