{
  description = "Renfe flake";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    zig.url = "github:mitchellh/zig-overlay";
  };

  outputs = {
    self,
    nixpkgs,
    zig,
  }: let
    systems = ["x86_64-darwin" "aarch64-darwin" "x86_64-linux"];
    createDevShell = system: let
      pkgs = import nixpkgs {
        system = "${system}";
        config.allowUnfree = true;
      };
    in
      pkgs.mkShell {
        buildInputs = with pkgs; [
            zig.packages."${system}".master
            zls
            llvmPackages_18.libllvm
            gdb
            gf
        ];
      };
  in {
    devShell = nixpkgs.lib.genAttrs systems createDevShell;
  };
}
