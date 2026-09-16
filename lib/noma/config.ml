type problem = Missing of string * string | Bad of string * string
type var = { name : string; kind : string; secret : bool; fallback : string option }

type 'a t = {
  vars : var list;
  run : (string -> string option) -> ('a, problem list) result;
}

let problem_to_string = function
  | Missing (name, kind) -> Printf.sprintf "%s: 未設定です (%s が必要)" name kind
  | Bad (name, msg) -> Printf.sprintf "%s: %s" name msg

let is_missing = function Missing _ -> true | Bad _ -> false

let reader name kind parse =
  {
    vars = [ { name; kind; secret = false; fallback = None } ];
    run =
      (fun getenv ->
        match getenv name with
        | None -> Error [ Missing (name, kind) ]
        | Some v -> (
            match parse v with
            | Ok x -> Ok x
            | Error msg -> Error [ Bad (name, Printf.sprintf "%s (実際の値: %S)" msg v) ]));
  }

let string name = reader name "文字列" (fun v -> Ok v)

let int name =
  reader name "整数" (fun v ->
      match int_of_string_opt (String.trim v) with
      | Some n -> Ok n
      | None -> Error "整数として読めません")

let float name =
  reader name "数値" (fun v ->
      match float_of_string_opt (String.trim v) with
      | Some f -> Ok f
      | None -> Error "数値として読めません")

let bool name =
  reader name "真偽値" (fun v ->
      match String.lowercase_ascii (String.trim v) with
      | "true" | "1" | "yes" | "on" -> Ok true
      | "false" | "0" | "no" | "off" -> Ok false
      | _ -> Error "真偽値として読めません (true/false/1/0/yes/no/on/off)")

let enum alts name =
  if alts = [] then invalid_arg "Noma.Config.enum: 候補を空にできない";
  let kind = "次のいずれか: " ^ String.concat " | " (List.map fst alts) in
  reader name kind (fun v ->
      let v' = String.lowercase_ascii (String.trim v) in
      match List.find_opt (fun (k, _) -> String.lowercase_ascii k = v') alts with
      | Some (_, x) -> Ok x
      | None ->
          Error
            (Printf.sprintf "候補にありません (候補: %s)" (String.concat " | " (List.map fst alts))))

let custom ~name f c =
  let var_name = match c.vars with v :: _ -> v.name | [] -> "?" in
  {
    vars = List.map (fun v -> { v with kind = name }) c.vars;
    run =
      (fun getenv ->
        match c.run getenv with
        | Error e -> Error e
        | Ok s -> (
            match f s with
            | Ok x -> Ok x
            | Error msg ->
                Error [ Bad (var_name, Printf.sprintf "%s として読めません: %s" name msg) ]));
  }

(* 未設定のときだけ既定値を使う。設定されていて読めない値は既定値で隠さずに
   報告する — 打ち間違いが黙って既定値に化けるのが設定事故の典型だから。 *)
let default v c =
  {
    vars = List.map (fun var -> { var with fallback = Some "既定値あり" }) c.vars;
    run =
      (fun getenv ->
        match c.run getenv with
        | Ok x -> Ok x
        | Error ps when List.for_all is_missing ps -> Ok v
        | Error ps -> Error ps);
  }

let optional c =
  {
    vars = List.map (fun var -> { var with fallback = Some "任意" }) c.vars;
    run =
      (fun getenv ->
        match c.run getenv with
        | Ok x -> Ok (Some x)
        | Error ps when List.for_all is_missing ps -> Ok None
        | Error ps -> Error ps);
  }

let secret c = { c with vars = List.map (fun v -> { v with secret = true }) c.vars }
let ( let+ ) c f = { c with run = (fun getenv -> Result.map f (c.run getenv)) }

(* ここが「全部まとめて報告する」性質の源。両側を必ず評価して問題を連結する。
   モナドにすると左が失敗した時点で右を評価できなくなり、この性質が壊れる。 *)
let ( and+ ) a b =
  {
    vars = a.vars @ b.vars;
    run =
      (fun getenv ->
        match (a.run getenv, b.run getenv) with
        | Ok x, Ok y -> Ok (x, y)
        | Error e1, Error e2 -> Error (e1 @ e2)
        | Error e, Ok _ | Ok _, Error e -> Error e);
  }

let load ?(getenv = Sys.getenv_opt) c =
  match c.run getenv with
  | Ok x -> Ok x
  | Error ps -> Error (List.map problem_to_string ps)

let load_exn ?getenv c =
  match load ?getenv c with
  | Ok x -> x
  | Error problems -> failwith ("設定に問題があります:\n  " ^ String.concat "\n  " problems)

let describe ?(getenv = Sys.getenv_opt) c =
  List.map
    (fun v ->
      let value =
        match getenv v.name with
        | None -> (
            (* 未設定のときは何を入れればよいかまで出す *)
            match v.fallback with
            | Some note -> Printf.sprintf "(未設定 — %s / %s)" note v.kind
            | None -> Printf.sprintf "(未設定 — %s が必要)" v.kind)
        | Some _ when v.secret -> "********"
        | Some s -> s
      in
      (v.name, value))
    c.vars
