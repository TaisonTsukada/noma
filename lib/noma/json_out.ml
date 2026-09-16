type value = S of string | I of int | F of float | B of bool | Null

let escape_string buf s =
  Buffer.add_char buf '"';
  String.iter
    (fun c ->
      match c with
      | '"' -> Buffer.add_string buf "\\\""
      | '\\' -> Buffer.add_string buf "\\\\"
      | '\n' -> Buffer.add_string buf "\\n"
      | '\r' -> Buffer.add_string buf "\\r"
      | '\t' -> Buffer.add_string buf "\\t"
      | '\b' -> Buffer.add_string buf "\\b"
      | '\012' -> Buffer.add_string buf "\\f"
      | c when Char.code c < 0x20 ->
          Buffer.add_string buf (Printf.sprintf "\\u%04x" (Char.code c))
      | c -> Buffer.add_char buf c)
    s;
  Buffer.add_char buf '"'

(* 往復する最短表現を選ぶ。%.17g は常に往復するが読みにくいので、
   %.15g で往復するならそちらを使う。 *)
let float_repr f =
  if not (Float.is_finite f) then "null"
  else
    let s = Printf.sprintf "%.15g" f in
    if Float.equal (float_of_string s) f then s else Printf.sprintf "%.17g" f

let write_value buf = function
  | S s -> escape_string buf s
  | I i -> Buffer.add_string buf (string_of_int i)
  | F f -> Buffer.add_string buf (float_repr f)
  | B b -> Buffer.add_string buf (if b then "true" else "false")
  | Null -> Buffer.add_string buf "null"

let write_object buf fields =
  Buffer.add_char buf '{';
  List.iteri
    (fun i (k, v) ->
      if i > 0 then Buffer.add_char buf ',';
      escape_string buf k;
      Buffer.add_char buf ':';
      write_value buf v)
    fields;
  Buffer.add_char buf '}'

let object_to_string fields =
  let buf = Buffer.create 256 in
  write_object buf fields;
  Buffer.contents buf
