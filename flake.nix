{
  description = "Rebuild disposable integration branches from a manifest";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-26.05";
    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    git-hooks = {
      url = "github:cachix/git-hooks.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = {
    self,
    nixpkgs,
    treefmt-nix,
    git-hooks,
  }: let
    systems = ["x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin"];
    forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

    treefmtEval = forAllSystems (pkgs: treefmt-nix.lib.evalModule pkgs ./treefmt.nix);
  in {
    packages = forAllSystems (pkgs: rec {
      default = git-franken;
      git-franken = pkgs.writeShellApplication {
        name = "git-franken";
        runtimeInputs = [pkgs.git];
        text = builtins.readFile ./git-franken;
        meta = {
          description = "Rebuild disposable integration branches from a manifest";
          mainProgram = "git-franken";
        };
      };
    });

    formatter = forAllSystems (pkgs: treefmtEval.${pkgs.system}.config.build.wrapper);

    checks = forAllSystems (pkgs: {
      formatting = treefmtEval.${pkgs.system}.config.build.check self;

      pre-commit = git-hooks.lib.${pkgs.system}.run {
        src = ./.;
        hooks = {
          treefmt = {
            enable = true;
            package = treefmtEval.${pkgs.system}.config.build.wrapper;
          };
          shellcheck = {
            enable = true;
            args = ["--severity=style"];
          };
          deadnix.enable = true;
        };
      };

      tests =
        pkgs.runCommand "git-franken-tests" {
          nativeBuildInputs = [pkgs.bats pkgs.git pkgs.coreutils];
          GIT_FRANKEN = nixpkgs.lib.getExe self.packages.${pkgs.system}.git-franken;
        } ''
          cp -r ${nixpkgs.lib.cleanSource ./.}/. work
          chmod -R +w work
          cd work
          export HOME="$TMPDIR/home"
          mkdir -p "$HOME"
          bats tests/git-franken.bats
          touch "$out"
        '';
    });

    devShells = forAllSystems (pkgs: {
      default = pkgs.mkShell {
        inherit (self.checks.${pkgs.system}.pre-commit) shellHook;
        buildInputs =
          self.checks.${pkgs.system}.pre-commit.enabledPackages
          ++ [pkgs.bats pkgs.git pkgs.shellcheck pkgs.shfmt];
      };
    });
  };
}
