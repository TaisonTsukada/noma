type ('a, 'b) path = ('a, 'b) Routes.path

module Parts = Routes.Parts

let s = Routes.s
let int = Routes.int
let int32 = Routes.int32
let int64 = Routes.int64
let str = Routes.str
let bool = Routes.bool
let wildcard = Routes.wildcard
let nil = Routes.nil
let ( / ) = Routes.( / )
let ( /? ) = Routes.( /? )
let ( /~ ) = Routes.( /~ )
let custom = Routes.custom
let href = Routes.sprintf

type route = {
  meths : Http.Method.t list;
  r : Handler.handler Routes.route;
  desc : string;
}

type t = {
  routers : (Http.Method.t * Handler.handler Routes.router) list;
  not_found : Handler.handler;
  trailing_slash : [ `Redirect | `Match | `Strict ];
  descriptions : string list;
}

type 'a decision =
  | Found of 'a
  | Redirect of string
  | Wrong_method of Http.Method.t list
  | Missing

let all_meths = [ `GET; `POST; `PUT; `PATCH; `DELETE; `HEAD; `OPTIONS ]

let route_of meths path f =
  let r = Routes.route path f in
  { meths; r; desc = Routes.string_of_route r }

let get p f = route_of [ `GET ] p f
let post p f = route_of [ `POST ] p f
let put p f = route_of [ `PUT ] p f
let patch p f = route_of [ `PATCH ] p f
let delete p f = route_of [ `DELETE ] p f
let options p f = route_of [ `OPTIONS ] p f
let head p f = route_of [ `HEAD ] p f
let any p f = route_of all_meths p f

let meths ms p f =
  if ms = [] then invalid_arg "Noma.Router.meths: メソッド一覧を空にできない (決して一致しない経路になる)";
  route_of ms p f

let group mw rs = List.map (fun rt -> { rt with r = Routes.map mw rt.r }) rs

(* target のクエリ部 ("?a=1")。無ければ "" *)
let query_suffix target =
  match String.index_opt target '?' with
  | Some i -> String.sub target i (String.length target - i)
  | None -> ""

let path_part target =
  match String.index_opt target '?' with
  | Some i -> String.sub target 0 i
  | None -> target

let mount_prefix_key : string Hmap.key = Hmap.Key.create ()

let mount prefix sub =
  if String.contains prefix '/' then
    invalid_arg "Noma.Router.mount: prefix は 1 セグメント (\"admin\" であって \"/admin/v1\" ではない)";
  let path = s prefix /~ wildcard in
  let f parts req =
    let rest = Parts.wildcard_match parts in
    let rest = if rest = "" then "/" else rest in
    let outer = Option.value ~default:"" (Request.find mount_prefix_key req) in
    Request.with_target (rest ^ query_suffix (Request.target req)) req
    |> Request.add mount_prefix_key (outer ^ Parts.prefix parts)
    |> sub
  in
  let r = Routes.route path f in
  { meths = all_meths; r; desc = Routes.string_of_route r }

let make ?(not_found = fun _ -> Response.not_found ()) ?(trailing_slash = `Redirect)
    routes =
  let routers =
    List.filter_map
      (fun m ->
        match List.filter (fun rt -> List.mem m rt.meths) routes with
        | [] -> None
        | rs -> Some (m, Routes.one_of (List.map (fun rt -> rt.r) rs)))
      all_meths
  in
  let descriptions =
    List.concat_map
      (fun rt -> List.map (fun m -> Http.Method.to_string m ^ " " ^ rt.desc) rt.meths)
      routes
  in
  { routers; not_found; trailing_slash; descriptions }

let router_for t m = List.assoc_opt m t.routers

let matches t m p =
  match router_for t m with
  | None -> false
  | Some r -> (
      match Routes.match' r ~target:p with Routes.NoMatch -> false | _ -> true)

(* この経路に対して許されるメソッド。GET があれば HEAD も暗黙に許され、
   OPTIONS は常に自動で応答するので必ず含める (RFC 9110 の allow の意味)。 *)
let allowed t p =
  let base = List.filter (fun m -> matches t m p) all_meths in
  if base = [] then []
  else
    let base =
      if List.mem `GET base && not (List.mem `HEAD base) then base @ [ `HEAD ] else base
    in
    if List.mem `OPTIONS base then base else base @ [ `OPTIONS ]

let on_trailing t req h =
  match t.trailing_slash with
  | `Match -> Found h
  | `Strict -> Missing
  | `Redirect ->
      (* 正規形は生の target から作る。復号済みの path を使うと元の符号化が壊れる。 *)
      let target = Request.target req in
      let p = path_part target in
      let p =
        if String.length p > 1 && p.[String.length p - 1] = '/' then
          String.sub p 0 (String.length p - 1)
        else p
      in
      Redirect (p ^ query_suffix target)

let lookup t m req p =
  match router_for t m with
  | None -> None
  | Some r -> (
      match Routes.match' r ~target:p with
      | Routes.FullMatch h -> Some (Found h)
      | Routes.MatchWithTrailingSlash h -> Some (on_trailing t req h)
      | Routes.NoMatch -> None)

let resolve t req =
  let m = Request.meth req in
  let p = Request.path req in
  let fallback () =
    match allowed t p with [] -> Missing | allow -> Wrong_method allow
  in
  match lookup t m req p with
  | Some d -> d
  | None -> (
      (* HEAD に専用の経路がなければ GET を使う (RFC 9110) *)
      match m with
      | `HEAD -> ( match lookup t `GET req p with Some d -> d | None -> fallback ())
      | _ -> fallback ())

(* HEAD の応答: 本体を落とし、長さが判っていれば content-length に残す。

   既に content-length があれば上書きしない。mount したサブアプリが先に
   HEAD 処理を済ませている場合 (本体は空、content-length は GET の長さ) に
   上書きすると 0 に潰れてしまう。 *)
let to_head res =
  if not (Http.Status.body_allowed (Response.status res)) then res
  else
    let res =
      if Http.Header.mem (Response.headers res) "content-length" then res
      else
        match Body.length (Response.body res) with
        | Some n -> Response.set_header "content-length" (string_of_int n) res
        | None -> res
    in
    Response.with_body Body.empty res

let allow_header allow =
  Http.Header.init_with "allow"
    (String.concat ", " (List.map Http.Method.to_string allow))

let handler t req =
  match resolve t req with
  | Found h -> if Request.meth req = `HEAD then to_head (h req) else h req
  | Redirect loc -> Response.redirect ~status:`Permanent_redirect loc
  | Wrong_method allow ->
      (* 資源は在るので OPTIONS に 405 を返すのは誤り。204 + allow が正しい。 *)
      if Request.meth req = `OPTIONS then
        Response.empty ~status:`No_content ~headers:(allow_header allow) ()
      else Response.method_not_allowed ~allow
  | Missing -> t.not_found req

let to_list t = t.descriptions
