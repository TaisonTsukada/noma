(* 契約検査器そのものの検査。
   検査器の生命線は「違反を全部捕らえる」ことと「正しいものを落とさない」ことの
   両方であり、後者を怠ると誰も使わなくなる。 *)

open Noma

let contains hay needle =
  let nl = String.length needle and hl = String.length hay in
  let rec go i = i + nl <= hl && (String.sub hay i nl = needle || go (i + 1)) in
  nl = 0 || go 0

let violates contract mw =
  match Noma_test.check_middleware ~name:"probe" mw with
  | () -> Alcotest.failf "%s の違反を検出できなかった" contract
  | exception Noma_test.Contract_violation msg ->
      if not (contains msg contract) then
        Alcotest.failf "違反は検出したが %s 以外として報告された: %s" contract msg

let passes name mw =
  match Noma_test.check_middleware ~name mw with
  | () -> ()
  | exception Noma_test.Contract_violation msg ->
      Alcotest.failf "正しいミドルウェアを落とした (偽陽性): %s" msg

(* ------------------------------------------ 契約を破る偽ミドルウェア 5 種 *)

(* M1: inner を 2 回呼ぶ。本体は使い捨てなので 2 回目は空を読む。 *)
let breaks_m1 inner req =
  ignore (inner req);
  inner req

(* M2: catch-all が Aborted を飲む。早期リターンが消える。 *)
let breaks_m2_abort inner req = try inner req with _ -> Response.text "swallowed"

(* M2: Cancelled を飲む。Eio のキャンセルが壊れ timeout が効かなくなる。 *)
let breaks_m2_cancelled inner req =
  try inner req with Eio.Cancel.Cancelled _ -> Response.text "swallowed cancel"

(* M3: 自分から落ちる。 *)
let breaks_m3 _inner _req = failwith "middleware blew up"

(* M4: リクエストを作り直して上流の ctx を捨てる。 *)
let breaks_m4 inner req =
  inner (Request.make ~meth:(Request.meth req) (Request.target req))

(* M5: 長さを測るために下流の本体を読み捨てる。クライアントには空が届く。 *)
let breaks_m5 inner req =
  let res = inner req in
  ignore (Body.to_string ~max_size:4096 (Response.body res));
  res

(* -------------------------------------------------- 正しいミドルウェア群 *)

let good_passthrough inner req = inner req
let good_adds_header inner req = Response.add_header "x-probe" "1" (inner req)

(* inner を呼ばずに短絡するのは正当 (cors の preflight、body_limit の 413) *)
let good_short_circuit _inner _req = Response.empty ~status:`No_content ()

(* 本体を読んで別の本体に差し替えるのは正当 (圧縮など) *)
let good_reads_and_replaces inner req =
  let res = inner req in
  let s = Body.to_string ~max_size:4096 (Response.body res) in
  Response.with_body (Body.of_string (String.uppercase_ascii s)) res

let ctx_key : int Hmap.key = Hmap.Key.create ()
let good_adds_ctx inner req = inner (Request.add ctx_key 1 req)

(* recover が取るべき形 — Aborted と Cancelled だけは通す *)
let good_recover inner req =
  try inner req with
  | (Aborted | Eio.Cancel.Cancelled _) as e -> raise e
  | _ -> Response.internal_server_error ()

let good_measures_before inner req =
  (* 下流の応答ではなくリクエスト側を見るのは自由 *)
  let n = String.length (Request.path req) in
  Response.add_header "x-path-len" (string_of_int n) (inner req)

(* ------------------------------------------------------------ テスト *)

let detects =
  [
    ("M1: inner を 2 回呼ぶ", `Quick, fun () -> violates "M1" breaks_m1);
    ("M2: Aborted を飲む", `Quick, fun () -> violates "M2" breaks_m2_abort);
    ("M2: Cancelled を飲む", `Quick, fun () -> violates "M2" breaks_m2_cancelled);
    ("M3: 自分から落ちる", `Quick, fun () -> violates "M3" breaks_m3);
    ("M4: ctx を捨てる", `Quick, fun () -> violates "M4" breaks_m4);
    ("M5: 下流の本体を読み捨てる", `Quick, fun () -> violates "M5" breaks_m5);
  ]

let no_false_positives =
  List.map
    (fun (name, mw) -> (name, `Quick, fun () -> passes name mw))
    [
      ("素通し", good_passthrough);
      ("ヘッダを足す", good_adds_header);
      ("inner を呼ばず短絡する", good_short_circuit);
      ("本体を読んで差し替える", good_reads_and_replaces);
      ("ctx を足す", good_adds_ctx);
      ("recover の形", good_recover);
      ("リクエストを見る", good_measures_before);
      ("id", Noma.id);
    ]

let composition =
  [
    ( "compose した結果も契約を守る",
      `Quick,
      fun () ->
        passes "composed" (Noma.compose [ good_recover; good_adds_header; good_adds_ctx ])
    );
    ( "違反を含む compose は落ちる",
      `Quick,
      fun () -> violates "M5" (Noma.compose [ good_adds_header; breaks_m5 ]) );
  ]

let () =
  Alcotest.run "noma.contract"
    [ ("違反を検出する", detects); ("偽陽性を出さない", no_false_positives); ("合成", composition) ]
