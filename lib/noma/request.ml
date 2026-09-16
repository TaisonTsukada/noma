type parts = { path : string; query : (string * string list) list }

type t = {
  meth : Http.Method.t;
  target : string;
  version : Http.Version.t;
  headers : Http.Header.t;
  body : Body.t;
  ctx : Hmap.t;
  client : Eio.Net.Sockaddr.stream option;
  sw : Eio.Switch.t option;
  parts : parts Lazy.t;
}

(* セグメント単位で復号する。復号すると "/" や NUL を含んでしまうセグメントは
   生のまま残す — そうしないと "%2F" がセグメントを 1 つ増やしてしまい、
   経路照合と認可判断が別の区切りを見ることになる (認可の迂回)。 *)
let decode_segment seg =
  match Uri.pct_decode seg with
  | exception _ -> seg
  | d -> if String.contains d '/' || String.contains d '\000' then seg else d

(* Uri.query は "a=1&a=2" を別々の組として返すが、利用者から見て自然なのは
   鍵ごとに値が並ぶ形なので統合する。出現順は保つ。 *)
let merge_query q =
  let tbl = Hashtbl.create 8 in
  let order = ref [] in
  List.iter
    (fun (k, vs) ->
      match Hashtbl.find_opt tbl k with
      | Some acc -> Hashtbl.replace tbl k (acc @ vs)
      | None ->
          Hashtbl.add tbl k vs;
          order := k :: !order)
    q;
  List.map (fun k -> (k, Hashtbl.find tbl k)) (List.rev !order)

let parse_target target =
  let uri = Uri.of_string target in
  let path =
    Uri.path uri |> String.split_on_char '/' |> List.map decode_segment
    |> String.concat "/"
  in
  let path = if path = "" then "/" else path in
  { path; query = merge_query (Uri.query uri) }

let make ?(version = `HTTP_1_1) ?(headers = Http.Header.init ()) ?(body = Body.empty)
    ?(ctx = Hmap.empty) ?client ?sw ~meth target =
  {
    meth;
    target;
    version;
    headers;
    body;
    ctx;
    client;
    sw;
    parts = lazy (parse_target target);
  }

let of_http ?body ?ctx ?client ?sw (r : Http.Request.t) =
  make ?body ?ctx ?client ?sw ~version:r.version ~headers:r.headers ~meth:r.meth
    r.resource

let meth t = t.meth
let target t = t.target
let version t = t.version
let headers t = t.headers
let body t = t.body
let client t = t.client
let ctx t = t.ctx
let path t = (Lazy.force t.parts).path
let query t = (Lazy.force t.parts).query

let query_opt t k =
  match List.assoc_opt k (query t) with Some (v :: _) -> Some v | _ -> None

let header t name = Http.Header.get t.headers name
let sw_opt t = t.sw

let sw t =
  match t.sw with
  | Some sw -> sw
  | None ->
      invalid_arg
        "Noma.Request.sw: このリクエストは Switch を持たない (~sw 付きで作るか Request.sw_opt を使うこと)"

let find k t = Hmap.find k t.ctx
let get k t = Hmap.get k t.ctx
let add k v t = { t with ctx = Hmap.add k v t.ctx }
let with_body body t = { t with body }
let with_headers headers t = { t with headers }
let with_target target t = { t with target; parts = lazy (parse_target target) }
