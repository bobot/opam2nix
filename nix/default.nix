{ pkgs, stdenv, lib, nix-update-source, newScope, libev, fetchurl }:
let
	ocamlPackages = pkgs.ocaml-ng.ocamlPackages_4_05;
	ocaml = ocamlPackages.ocaml;
	# TODO: check versions againa
	# /home/tim/dev/ocaml/opam/src_ext/Makefile.sources
	localPackages = lib.makeScope pkgs.newScope (self: with self; pkgs // {
		ocamlPackages = lib.makeScope pkgs.newScope (self:
			let opam = callPackage ./opam.nix { ocamlPackages = self; }; in with self; ocamlPackages // {
			opam-core = callPackage opam.core {};
			opam-format = callPackage opam.format {};
			opam-file-format = callPackage ./opam-file-format.nix {};
			opam-installer = callPackage opam.installer {};
			opam-repository = callPackage opam.repository {};
			opam-solver = callPackage opam.solver {};
			opam-state = callPackage opam.state {};
			cudf = callPackage ./cudf.nix {};
			dose3 = callPackage ./dose3.nix {};
			dune = callPackage ./dune.nix {};
			mccs = callPackage ./mccs.nix {};
			basedir = callPackage ./basedir.nix {};
		});
	});

	ocVersion = (builtins.parseDrvName (localPackages.ocamlPackages.ocaml.name)).version;
in
with localPackages; with localPackages.ocamlPackages;
stdenv.mkDerivation {
	name = "opam2nix-${lib.removeSuffix "\n" (builtins.readFile ../VERSION)}";
	src = if lib.isStorePath ../. then ../. else (nix-update-source.fetch ./src.json).src;
	buildPhase = "gup all";
	installPhase = ''
		mkdir $out
		cp -r --dereference bin $out/bin
		wrapProgram $out/bin/opam2nix \
			--prefix PATH : "${localPackages.aspcud}/bin" \
			--prefix PATH : "${pkgs.nix.out}/bin" \
		;
	'';
	passthru = {
		format_version = import ./format_version.nix;
		pkgs = localPackages;
		devInputs = [ utop ];
		packages = localPackages;
	};
	buildInputs = [
		ocaml
		findlib
		opam-solver
		opam-state
		ocaml_lwt
		ocurl
		yojson
		fileutils
		basedir
		gup
		ounit
		makeWrapper
		dune
		ocaml-migrate-parsetree
		coreutils

		# XXX these should be picked up by propagatedBuildInputs
		libev
		camlp4
		cmdliner
		dose3
		cudf
		ocamlgraph
		re
		jsonm
		ocaml_extlib
		pkgs.libssh2
	];

	# XXX this seems to be necessary for .byte targets only
	# (but we like those during development / testing).
	# Seems fragile though.
	CAML_LD_LIBRARY_PATH = lib.concatStringsSep ":" [
		"${ocaml_lwt}/lib/ocaml/${ocVersion}/site-lib/lwt"
		"${ocurl}/lib/ocaml/${ocVersion}/site-lib/curl"
	];
}

