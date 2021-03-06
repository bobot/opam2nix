open Util
module URL = OpamFile.URL
module OPAM = OpamFile.OPAM
module Descr = OpamFile.Descr
open OpamTypes
module StringSet = OpamStd.String.Set
module StringSetMap = OpamStd.String.SetMap

module StringMap = struct
	include Map.Make(String)
	let from_list items = List.fold_right (fun (k,v) map -> add k v map) items empty
end

let installed_suffix = ":installed"

type url = [
	| `http of string * Digest_cache.opam_digest
	| `local of string
]

type url_type =
	[ `http
	| `git
	| `local
	| `darcs
	| `hg
	]

exception Unsupported_archive of string
exception Invalid_package of string
exception Checksum_mismatch of string
exception Not_cached of string

let var_prefix = "opam_var_"

type dependency =
	| NixDependency of string
	| SimpleOpamDependency of string
	| OsDependency of (bool * string) OpamTypes.generic_formula
	| ExternalDependencies of OpamTypes.tags
	| PackageDependencies of OpamTypes.ext_formula

type importance = Required | Optional
type requirement = importance * dependency

module ImportanceOrd = struct
	type t = importance

	let compare a b = match (a,b) with
		| Required, Required | Optional, Optional -> 0
		| Required, _ -> 1
		| Optional, _ -> -1

	let more_important a b = (compare a b) > 0
end

let rec iter_formula : 'a . (importance -> 'a -> unit) -> importance -> 'a OpamFormula.formula -> unit =
	fun iter_atom importance formula ->
		let recurse = iter_formula iter_atom in
		let open OpamFormula in
		match formula with
			| Empty -> ()
			| Atom a -> iter_atom importance a
			| Block b -> recurse importance b
			| And (a,b) -> recurse importance a; recurse importance b
			| Or(a,b) -> recurse Optional a; recurse Optional b

let string_of_dependency = function
	| NixDependency dep -> "nix:"^dep
	| SimpleOpamDependency dep -> "package:"^dep
	| OsDependency formula ->
			"os:" ^
				(OpamFormula.string_of_formula (fun (b,s) -> (string_of_bool b) ^","^s) formula)
	| ExternalDependencies tags ->
			"external:" ^
				(StringSetMap.to_string (StringSet.to_string) tags)
	| PackageDependencies formula ->
		(* of OpamTypes.ext_formula *)
		"package:<TODO>"

let string_of_requirement = function
	| Required, dep -> string_of_dependency dep
	| Optional, dep -> "{" ^ (string_of_dependency dep) ^ "}"

let string_of_importance = function Required -> "required" | Optional -> "optional"

let add_nix_inputs
	~(add_native: importance -> string -> unit)
	~(add_opam:importance -> string -> unit)
	importance dep =
	let desc = match importance with
		| Required -> "dep"
		| Optional -> "optional dep"
	in
	(* let depend_on = add_input importance in *)
	match dep with
		| NixDependency name ->
				Printf.eprintf "  adding nix %s: %s\n" desc name;
				add_native importance name
		| OsDependency formula ->
				iter_formula (fun importance (b, str) ->
					Printf.eprintf "TODO: OS %s (%b,%s)\n" desc b str
				) importance formula
		| SimpleOpamDependency dep -> add_opam importance dep
		| ExternalDependencies externals ->
				let has_nix = ref false in
				let add_all importance packages =
					StringSet.iter (fun dep ->
						Printf.eprintf "  adding nix %s: %s\n" desc dep;
						add_native importance dep
					) packages
				in

				StringSetMap.iter (fun environments packages ->
					if StringSet.mem "nixpkgs" environments then (
						has_nix := true;
						add_all importance packages
					)
				) externals;
				if not !has_nix then begin
					Printf.eprintf
						"  Note: package has depexts, but none of them `nixpkgs`:\n    %s\n"
						(StringSetMap.to_string (StringSet.to_string) externals);
					Printf.eprintf "  Adding them all as `optional` deps, with fingers firmly crossed.\n";
					StringSetMap.iter (fun _environments packages ->
						add_all Optional packages
					) externals;
				end

		| PackageDependencies formula ->
			let iter_dep importance (dep:OpamPackage.Name.t * (package_dep_flag list * OpamFormula.version_formula)) =
				let (name, (flags, version_formula)) = dep in
				let name = OpamPackage.Name.to_string name in
				let needed_for_build = if List.length flags = 0
					then true
					else flags |> List.fold_left (fun required flag ->
						required || (match flag with Depflag_Build -> true | _ -> false)) false
				in
				let build_importance = if needed_for_build then importance else Optional in
				let version_desc = ref "" in
				version_formula |> iter_formula (fun _importance (relop, version) ->
					version_desc := !version_desc ^ (
						(OpamFormula.string_of_relop relop) ^
						(OpamPackage.Version.to_string version)
					)
				) build_importance;
				add_opam build_importance name
			in
			iter_formula iter_dep importance formula

module PackageMap = OpamPackage.Map

class dependency_map =
	let map : requirement list PackageMap.t ref = ref PackageMap.empty in
	let get_existing package_id = try PackageMap.find package_id !map with Not_found -> [] in
	object
		method init_package package_id =
			let existing = get_existing package_id in
			map := PackageMap.add package_id existing !map

		method add_dep package_id (dep:requirement) =
			let existing = get_existing package_id in
			map := PackageMap.add package_id (dep :: existing) !map

		method to_string =
			let reqs_to_string = (fun reqs -> String.concat "," (List.map string_of_requirement reqs)) in
			PackageMap.to_string reqs_to_string !map
	end

let url file: url = match (URL.kind file, URL.url file, URL.checksum file) with
	| `http, (src, None), Some checksum -> `http (src, `md5 checksum)
	| `http, (_src, Some _fragment), _ -> raise (Unsupported_archive "http with fragment")
	| `http, (_, _), None -> raise (Unsupported_archive "checksum required")
	| `local, (src, None), _ -> `local src
	| `local, (_src, Some _fragment), _ -> raise (Unsupported_archive "local with fragment")
	| `git, _, _ -> raise (Unsupported_archive "git")
	| `darcs, _, _ -> raise (Unsupported_archive "darcs")
	| `hg, _, _ -> raise (Unsupported_archive "hg")

let load_url path =
	if Sys.file_exists path then begin
		let url_file = open_in path in
		let rv = URL.read_from_channel url_file in
		close_in url_file;
		Some (url rv)
	end else None

let load_opam path =
	(* Printf.eprintf "  Loading opam info from %s\n" path; *)
	if not (Sys.file_exists path) then raise (Invalid_package ("No opam file at " ^ path));
	let file = open_in path in
	let rv = OPAM.read_from_channel file in
	close_in file;
	rv

let concat_address (addr, frag) =
	match frag with
		| Some frag -> addr ^ "#" ^ frag
		| None -> addr

let string_of_url url =
	match url with
		| `http addr -> addr
		| `git addr -> "git:" ^ (concat_address addr)

let nix_of_url ~add_input ~cache ~offline (url:url) =
	let open Nix_expr in
	match url with
		| `local src -> `Lit src
		| `http (src, checksum) ->
			if (offline && not (Digest_cache.exists checksum cache)) then raise (Not_cached src);
			let digest = Digest_cache.add src checksum cache in
			add_input "fetchurl";
			`Call [
				`Id "fetchurl";
				`Attrs (AttrSet.build [
					"url", str src;
					(match digest with
						| `sha256 sha256 -> ("sha256", str sha256)
						| `checksum_mismatch desc -> raise (Checksum_mismatch desc)
					);
				])
			]

let unsafe_envvar_chars = Str.regexp "[^0-9a-zA-Z_]"
let envvar_of_ident name =
	var_prefix ^ (Str.global_replace unsafe_envvar_chars "_" name)

let add_implicit_build_dependencies ~add_dep commands =
	let implicit_optdeps = ref StringSet.empty in
	(* If your build command depends on foo:installed, you have an implicit optional
	 * build dependency on foo. Packages *should* declare this, but don't always... *)
	let lookup_var key =
		let key = (OpamVariable.Full.to_string key) in
		let suffix = installed_suffix in
		if OpamStd.String.ends_with ~suffix key then (
			let pkgname = OpamStd.String.remove_suffix ~suffix key in
			Printf.eprintf "  adding implied dep: %s\n" pkgname;
			implicit_optdeps := !implicit_optdeps |> StringSet.add pkgname;
			Some (B true)
		) else (
			None
		)
	in
	commands |> List.iter (fun commands ->
		let (_:string list list) = commands |> OpamFilter.commands lookup_var in
		()
	);
	!implicit_optdeps |> StringSet.iter (fun pkg ->
		add_dep Optional (SimpleOpamDependency pkg)
	)
;;

let attrs_of_opam ~add_dep ~name (opam:OPAM.t) =
	add_implicit_build_dependencies ~add_dep [OPAM.build opam; OPAM.install opam];
	add_dep Optional (PackageDependencies (OPAM.depopts opam));
	add_dep Required (PackageDependencies (OPAM.depends opam));
	add_dep Required (OsDependency (OPAM.os opam));
	let () = match OPAM.depexts opam with
		| None -> ()
		| Some deps -> add_dep Required (ExternalDependencies deps);
	in
	[
		"configurePhase",  Nix_expr.str "true"; (* configuration is done in build commands *)
		"buildPhase",      `Lit "\"${opam2nix}/bin/opam2nix invoke build\"";
		"installPhase",    `Lit "\"${opam2nix}/bin/opam2nix invoke install\"";
	]
;;

module InputMap = struct
	include StringMap
	(* override `add` to keep the "most required" entry *)
	let add k v map =
		let existing = try Some (find k map) with Not_found -> None in
		match existing with
			| Some existing when (ImportanceOrd.more_important existing v) -> map
			| _ -> add k v map
end

let nix_of_opam ~name ~version ~cache ~offline ~deps ~has_files path : Nix_expr.t =
	let pkgid = OpamPackage.create
		(OpamPackage.Name.of_string name)
		(Repo.opam_version_of version)
	in
	let open Nix_expr in
	let pkgs_expression_inputs = ref (InputMap.from_list [
		"lib", Required;
	]) in
	let additional_env_vars = ref [] in
	let adder r = fun importance name -> r := InputMap.add name importance !r in

	let url = try load_url (Filename.concat path "url")
		with Unsupported_archive reason -> raise (
			Unsupported_archive (name ^ "-" ^ (Repo.string_of_version version) ^ ": " ^ reason)
		)
	in

	deps#init_package pkgid;

	let opam_inputs = ref InputMap.empty in
	let nix_deps = ref InputMap.empty in
	let add_native = adder nix_deps in
	let add_opam_input = adder opam_inputs in
	let add_expression_input = adder pkgs_expression_inputs in

	let src = Option.map (
		nix_of_url ~add_input:(add_expression_input Required) ~cache ~offline
	) url in

	(* If ocamlfind is in use by _anyone_ make it used by _everyone_. Otherwise,
	 * we end up with inconsistent install paths. XXX this is a bit hacky... *)
	let is_conf_pkg pkg =
		let re = Str.regexp "^conf-" in
		Str.string_match re pkg 0
	in
	if not (name = "ocamlfind" || is_conf_pkg name)
		then add_opam_input Optional "ocamlfind";
	add_opam_input Required "ocaml"; (* pretend this is an `opam` input for convenience *)

	let add_dep = fun importance dep ->
		add_nix_inputs
			~add_native
			~add_opam:add_opam_input
			importance dep
	in

	let opam = load_opam (Filename.concat path "opam") in
	let buildAttrs : (string * Nix_expr.t) list = attrs_of_opam ~add_dep ~name opam in

	let url_ends_with ext = (match url with
		| Some (`http (url,_)) | Some (`local url) -> ends_with ext url
		| _ -> false
	) in

	if url_ends_with ".zip" then add_native Required "unzip";

	let property_of_input src (name, importance) : Nix_expr.t =
		match importance with
			| Optional -> `Property_or (src, name, `Null)
			| Required -> `PropertyPath (src, String.split_on_char '.' name)
	in
	let attr_of_input src (name, importance) : string * Nix_expr.t =
		(name, property_of_input src (name, importance))
	in
	let sorted_bindings_of_input input = input
		|> InputMap.bindings
		|> List.sort (fun (a,_) (b,_) -> String.compare a b)
	in

	let opam_inputs : Nix_expr.t AttrSet.t =
		!opam_inputs |> InputMap.mapi (fun name importance ->
			property_of_input (`Id "selection") (name, importance)) in

	let nix_deps = !nix_deps
		|> sorted_bindings_of_input
		|> List.map (property_of_input (`Id "pkgs"))
	in
	let expression_args : (string * Nix_expr.t) list = !pkgs_expression_inputs
		|> sorted_bindings_of_input
		|> List.map (attr_of_input (`Id "pkgs"))
	in

	`Function (
		`Id "world",
		`Let_bindings (
			(AttrSet.build ([
				"lib", `Lit "world.pkgs.lib";
				"selection", `Property (`Id "world", "selection");
				"opam2nix", `Property (`Id "world", "opam2nix");
				"pkgs", `Property (`Id "world", "pkgs");
				"opamDeps", `Attrs opam_inputs;
				"inputs", `Call [
						`Id "lib.filter";
						`Lit "(dep: dep != true && dep != null)";
						`BinaryOp (
							`List nix_deps,
							"++",
							`Lit "(lib.attrValues opamDeps)"
						);
				];
			] @ expression_args) ),
			`Call [
				`Id "pkgs.stdenv.mkDerivation";
				`Attrs (AttrSet.build (!additional_env_vars @ [
					"name", Nix_expr.str (name ^ "-" ^ (Repo.path_of_version `Nix version));
					"opamEnv", `Call [`Id "builtins.toJSON"; `Attrs (AttrSet.build [
						"spec", `Lit "./opam";
						"deps", `Lit "opamDeps";
						"name", Nix_expr.str name;
						"files", if has_files then `Lit "./files" else `Null;
						"ocaml-version", `Property (`Id "world", "ocamlVersion");
					])];
					"buildInputs", `Lit "inputs";
					(* TODO: don't include build-only deps *)
					"propagatedBuildInputs", `Lit "inputs";
					"passthru", `Attrs (AttrSet.build [
						"selection", `Id "selection";
					]);
				] @ (
					if has_files
						then [
							"prePatch", `String [`Lit "cp -r "; `Expr (`Lit "./files"); `Lit "/* ./" ]
						]
						else []
				) @ buildAttrs @ (
					match src with
						| Some src -> [ "src", src ]
						| None -> [ "unpackPhase", str "true" ]
				) @ (
					if url_ends_with ".tbz" then
						["unpackCmd", Nix_expr.str "tar -xf \"$curSrc\""]
					else []
				)))
			]
		)
	)


let os_string = OpamStd.Sys.os_string

let add_var name v vars =
	vars |> OpamVariable.Full.Map.add (OpamVariable.Full.of_string name) v

let init_variables () =
	let state = OpamVariable.Full.Map.empty in
	state
		|> add_var "os" (S (os_string ()))
		|> add_var "make" (S "make")
                |> add_var "opam-version" (S (OpamVersion.to_string OpamVersion.current))
                (* With preinstalled packages suppose they can't write
                   in the ocaml directory *)
		|> add_var "preinstalled" (B true)
		|> add_var "pinned" (B false) (* probably ? *)
		|> add_var "jobs" (S "1") (* XXX NIX_JOBS? *)
		(* XXX best guesses... *)
		|> add_var "ocaml-native" (B true)
		|> add_var "ocaml-native-tools" (B true)
		|> add_var "ocaml-native-dynlink" (B true)
		|> add_var "arch" (S (OpamStd.Sys.arch ()))

let lookup_var vars key =
	try Some (OpamVariable.Full.Map.find key vars)
	with Not_found -> (
		let key = (OpamVariable.Full.to_string key) in
		if OpamStd.String.ends_with ~suffix:installed_suffix key then (
			(* evidently not... *)
			Some (B false)
		) else (
			prerr_endline ("WARN: opam var " ^ key ^ " not found...");
			None
		)
	)
