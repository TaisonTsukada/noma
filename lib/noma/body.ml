type view = Empty | String of string | Stream of Eio.Flow.source_ty Eio.Resource.t
type t = { view : view; mutable string_taken : bool }

exception Too_large of int
exception Already_consumed

let make view = { view; string_taken = false }
let empty = make Empty
let of_string s = make (String s)
let of_source src = make (Stream (src :> Eio.Flow.source_ty Eio.Resource.t))

let length t =
  match t.view with
  | Empty -> Some 0
  | String s -> Some (String.length s)
  | Stream _ -> None

let is_empty t = length t = Some 0

let to_string ~max_size t =
  if max_size <= 0 then invalid_arg "Noma.Body.to_string: max_size must be > 0";
  match t.view with
  | Empty -> ""
  | String s -> if String.length s > max_size then raise (Too_large max_size) else s
  | Stream src -> (
      if t.string_taken then raise Already_consumed;
      t.string_taken <- true;
      (* Buf_read.take_all は「残りが上限以上」で送出するので、ちょうど max_size を
         通すには上限を 1 だけ広く取る。 *)
      let limit = if max_size >= max_int - 1 then max_int else max_size + 1 in
      let r = Eio.Buf_read.of_flow ~max_size:limit src in
      try Eio.Buf_read.take_all r
      with Eio.Buf_read.Buffer_limit_exceeded -> raise (Too_large max_size))

module Private = struct
  type nonrec view = view =
    | Empty
    | String of string
    | Stream of Eio.Flow.source_ty Eio.Resource.t

  let view t = t.view
end
