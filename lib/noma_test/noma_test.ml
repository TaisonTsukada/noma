exception Contract_violation of string

let violation name contract fmt =
  Printf.ksprintf
    (fun msg ->
      raise (Contract_violation (Printf.sprintf "[%s] %s: %s" name contract msg)))
    fmt

let probe_request () = Noma.Request.make ~meth:`GET "/"
let ok_response () = Noma.Response.text "probe-ok"

(* ---------------------------------------------------------------- M1 ---
   inner の呼び出し回数は 0 か 1。本体は使い捨てなので 2 回呼ぶと 2 回目は
   空を読む。正常・例外・abort のどの経路でも数える。 *)

let check_m1 name mw =
  let count behaviour =
    let n = ref 0 in
    let inner req =
      incr n;
      behaviour req
    in
    (try ignore (Noma.run_handler (mw inner) (probe_request ())) with _ -> ());
    !n
  in
  let scenarios =
    [
      ("正常に応答する inner", fun _ -> ok_response ());
      ("例外を投げる inner", fun _ -> failwith "probe");
      ("abort する inner", fun _ -> Noma.abort (Noma.Response.forbidden ()));
    ]
  in
  List.iter
    (fun (label, behaviour) ->
      let n = count behaviour in
      if n > 1 then violation name "M1" "%s に対して inner を %d 回呼んだ (0 回か 1 回であること)" label n)
    scenarios

(* ---------------------------------------------------------------- M2 ---
   Aborted を飲むと早期リターンが消える。Cancelled を飲むと Eio のキャンセルが
   壊れ、timeout の内側に recover を置いた構成が黙って効かなくなる。

   run_handler を通さず直接 raise して検査するのが要点 — run_handler には
   握り潰しを補う安全網があるので、通してしまうと違反が見えなくなる。 *)

let check_passthrough name contract exn describe mw =
  (* inner を呼ばずに短絡するミドルウェア (cors の preflight、body_limit の 413
     など) は正当で、素通しすべき例外がそもそも存在しない。呼んだ場合だけ問う。 *)
  let called = ref false in
  let inner _ =
    called := true;
    raise exn
  in
  match mw inner (probe_request ()) with
  | _ -> if !called then violation name contract "%s を握り潰した" describe
  | exception e when e == exn -> ()
  | exception (Contract_violation _ as e) -> raise e
  | exception e ->
      violation name contract "%s を別の例外に変えた (%s)" describe (Printexc.to_string e)

let check_m2 name mw =
  check_passthrough name "M2" Noma.Aborted "Noma.Aborted" mw;
  check_passthrough name "M2" (Eio.Cancel.Cancelled (Failure "probe"))
    "Eio.Cancel.Cancelled" mw

(* ---------------------------------------------------------------- M3 ---
   正常な inner に対して自分から例外を投げない。
   (inner を呼ばない場合に Response を返すこと自体は型が保証している。) *)

let check_m3 name mw =
  match mw (fun _ -> ok_response ()) (probe_request ()) with
  | _ -> ()
  | exception (Contract_violation _ as e) -> raise e
  | exception e -> violation name "M3" "正常な inner に対して例外を投げた (%s)" (Printexc.to_string e)

(* ---------------------------------------------------------------- M4 ---
   上流が置いた文脈 (request_id など) を下流まで届ける。足すのは可。 *)

let check_m4 name mw =
  let key : string Hmap.key = Hmap.Key.create () in
  let called = ref false in
  let seen = ref None in
  let inner req =
    called := true;
    seen := Noma.Request.find key req;
    ok_response ()
  in
  let req = Noma.Request.add key "sentinel" (probe_request ()) in
  (try ignore (Noma.run_handler (mw inner) req) with _ -> ());
  if !called && !seen <> Some "sentinel" then
    violation name "M4" "上流が ctx に置いた束縛が下流に届かなかった"

(* ---------------------------------------------------------------- M5 ---
   下流が返した本体を読み捨てない。本体は使い捨てなので、長さを測るために
   読んでしまうとクライアントには空が届く。

   返ってきた応答の本体が読めるかどうかで判定する。本体を読んで別の本体に
   差し替えるミドルウェア (圧縮など) は正当なので、それは通る。 *)

let check_m5 name mw =
  let inner _ = Noma.Response.stream (Eio.Flow.string_source "downstream-body") in
  let res = try Some (mw inner (probe_request ())) with _ -> None in
  match res with
  | None -> ()
  | Some res -> (
      match Noma.Body.to_string ~max_size:4096 (Noma.Response.body res) with
      | _ -> ()
      | exception Noma.Body.Already_consumed ->
          violation name "M5" "下流が返した本体を読み捨てた (返った応答の本体がもう読めない)")

(* M3 を先に走らせる。そもそも動かないミドルウェアを M2 違反として報告すると
   診断が読みにくくなるので、最も基本的な健全性から順に見る。 *)
let check_middleware ?(name = "middleware") mw =
  check_m3 name mw;
  check_m1 name mw;
  check_m2 name mw;
  check_m4 name mw;
  check_m5 name mw
