# standalone derivation, for nix-build, nix-shell, etc
{ pkgs ? import <nixpkgs> {}, opam2nix ? import ../opam2nix.nix }:
pkgs.callPackage ./nix { inherit opam2nix; }
