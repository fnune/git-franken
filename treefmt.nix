{...}: {
  projectRootFile = "flake.nix";

  programs = {
    alejandra.enable = true;
    shfmt.enable = true;
    prettier.enable = true;
  };

  settings = {
    # bats defines tests with `@test "..." { }`, which shfmt cannot parse.
    global.excludes = [
      "flake.lock"
      "LICENSE"
      "*.bats"
    ];
    formatter.shfmt.includes = ["git-franken" "*.bash"];
  };
}
