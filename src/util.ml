let rec filter_map fn lst =
	lst |> List.fold_left (fun acc item ->
		match fn item with
			| None -> acc
			| Some result -> result :: acc
	) [] |> List.rev


let ends_with suffix s =
	let suffix_len = String.length suffix in
	let len = String.length s in
	len >= suffix_len && String.sub s (len - suffix_len) (suffix_len) = suffix

let without_leading prefix s =
	let prefix_len = String.length prefix in
	let len = String.length s in
	if len >= prefix_len && String.sub s 0 prefix_len = prefix
	then Some (String.sub s prefix_len (len - prefix_len))
	else None

let without_trailing suffix s =
	let suffix_len = String.length suffix in
	let len = String.length s in
	if len >= suffix_len && String.sub s (len - suffix_len) (suffix_len) = suffix
	then Some (String.sub s 0 (len - suffix_len))
	else None

let list_dirs root =
	Sys.readdir root |> Array.to_list |> List.filter (fun name ->
		Sys.is_directory (Filename.concat root name)
	) |> List.sort String.compare

let rec rm_r root =
	if Sys.file_exists root then (
		Sys.readdir root |> Array.to_list |> List.iter (fun name ->
			let path = (Filename.concat root name) in
			if Sys.is_directory path
				then rm_r path
				else Unix.unlink path
		);
		Unix.rmdir root
	)

let nonempty value arg =
	if value = ""
	then failwith (arg ^ " required")
	else value

let nonempty_list value arg =
	if value = []
	then failwith (arg ^ " required")
	else value

module Option = struct
	let map fn = function None -> None | Some x -> Some (fn x)
	let may fn = function None -> () | Some x -> fn x
	let bind fn = function None -> None | Some x -> fn x
	let default d v = match v with Some v -> v | None -> d
	let exists fn = function None -> false | Some v -> fn v
	let to_list = function None -> [] | Some v -> [v]
	let is_some = function None -> false | Some _ -> true
end

let rec drop n lst =
	if n <= 0
		then lst
		else match lst with
			| [] -> []
			| head :: tail -> drop (n-1) tail

let rec take n lst =
	if n <= 0
		then []
		else match lst with
			| [] -> []
			| head :: tail -> head :: (take (n-1) tail)

let head_opt = function
	| x::_ -> Some x
	| [] -> None

let tail = function
	| [] -> []
	| _::x -> x

let group_by : 'item 'key. ('item -> 'key) -> 'item list -> ('key * 'item list) list
= fun fn items ->
	let finish key items_rev = (key, List.rev items_rev) in
	let rec accum groups_rev current_key current_group_rev = function
		| [] -> (* end of inputs *)
			(if (current_group_rev = [])
				then []
				else [finish current_key current_group_rev]
			) @ groups_rev
		| head::tail ->
			let key = fn head in
			if (key = current_key)
				then accum groups_rev current_key (head :: current_group_rev) tail
				else (
					let groups_rev = (finish current_key current_group_rev) :: groups_rev in
					accum groups_rev key [head] tail
				)
	in
	match items with
		| [] -> []
		| head::tail ->
			let key = fn head in
			accum [] key [head] tail |> List.rev

let fst = function (a,_) -> a
let snd = function (_,b) -> b

let explode s =
	let rec exp i l =
		if i < 0 then l else exp (i - 1) (s.[i] :: l) in
		exp (String.length s - 1) []

let string_of_char = String.make 1

(* This is a bit ad-hoc.
 * We represent non-safe characters as +xNN, where NN is the hex representation.
 * Only supports ASCII. Literal +x is encoded (as +x2b+x78) *)
let encode_nix_safe_path str =
	let encode ch =
		let a,b = (Hex.of_char ch) in
		"+x" ^ (string_of_char a) ^ (string_of_char b)
	in
	let open Str in
	full_split (regexp "[^.+_a-zA-Z0-9-]\\|\\+x") str |> List.map (function
		| Delim x when x = "+x" -> (encode '+' ^ encode 'x')
		| Delim x -> String.concat "" (List.map encode (explode x))
		| Text x -> x
	) |> String.concat ""

let decode_nix_safe_path str =
	let open Str in
	let hex = "[0-9a-fA-F]" in
	full_split (regexp ("\\+x" ^ hex ^ hex)) str |> List.map (function
		| Delim x -> Hex.to_char x.[2] x.[3] |> String.make 1
		| Text x -> x
	) |> String.concat ""

module List = struct
	include List
	let to_string fn lst = "[" ^ (String.concat ", " (map fn lst)) ^ "]"
end
