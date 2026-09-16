let status =
  Alcotest.testable
    (fun ppf s -> Format.pp_print_int ppf (Http.Status.to_int s))
    (fun a b -> Http.Status.to_int a = Http.Status.to_int b)

let req ?(meth = `GET) target = Noma.Request.make ~meth target

let contains hay needle =
  let nl = String.length needle and hl = String.length hay in
  let rec go i = i + nl <= hl && (String.sub hay i nl = needle || go (i + 1)) in
  nl = 0 || go 0

(* ログを捕まえる *)
let capture f =
  let buf = Buffer.create 256 in
  let ppf = Format.formatter_of_buffer buf in
  let saved = Logs.reporter () and saved_level = Logs.level () in
  Logs.set_reporter (Noma.Log.json_reporter ~ppf ~now:(fun () -> 0.) ());
  Logs.set_level (Some Logs.Debug);
  Fun.protect
    ~finally:(fun () ->
      Logs.set_reporter saved;
      Logs.set_level saved_level)
    (fun () ->
      let r = f () in
      Format.pp_print_flush ppf ();
      (r, Buffer.contents buf))

(* ------------------------------------------------------------------ Body *)

let body_tests =
  let open Noma in
  [
    ( "of_string は長さが既知",
      `Quick,
      fun () ->
        Alcotest.(check (option int))
          "length" (Some 5)
          (Body.length (Body.of_string "hello"));
        Alcotest.(check bool) "not empty" false (Body.is_empty (Body.of_string "hello"));
        Alcotest.(check bool) "empty" true (Body.is_empty Body.empty) );
    ( "of_string は何度でも to_string できる",
      `Quick,
      fun () ->
        let b = Body.of_string "hi" in
        Alcotest.(check string) "1st" "hi" (Body.to_string ~max_size:10 b);
        Alcotest.(check string) "2nd" "hi" (Body.to_string ~max_size:10 b) );
    ( "to_string は max_size を超えると Too_large",
      `Quick,
      fun () ->
        Alcotest.check_raises "too large" (Body.Too_large 2) (fun () ->
            ignore (Body.to_string ~max_size:2 (Body.of_string "hello"))) );
    ( "to_string は max_size <= 0 を拒む",
      `Quick,
      fun () ->
        Alcotest.check_raises "precondition"
          (Invalid_argument "Noma.Body.to_string: max_size must be > 0") (fun () ->
            ignore (Body.to_string ~max_size:0 Body.empty)) );
    ( "of_source は長さ不明・一度しか読めない",
      `Quick,
      fun () ->
        let b = Body.of_source (Eio.Flow.string_source "streamed") in
        Alcotest.(check (option int)) "length" None (Body.length b);
        Alcotest.(check string) "1st" "streamed" (Body.to_string ~max_size:100 b);
        Alcotest.check_raises "2nd" Body.Already_consumed (fun () ->
            ignore (Body.to_string ~max_size:100 b)) );
    ( "of_source もちょうど max_size までは通る",
      `Quick,
      fun () ->
        let b = Body.of_source (Eio.Flow.string_source "12345") in
        Alcotest.(check string) "exact" "12345" (Body.to_string ~max_size:5 b);
        let b2 = Body.of_source (Eio.Flow.string_source "123456") in
        Alcotest.check_raises "over" (Body.Too_large 5) (fun () ->
            ignore (Body.to_string ~max_size:5 b2)) );
  ]

(* --------------------------------------------------------------- Request *)

let request_tests =
  let open Noma in
  [
    ( "path はセグメントごとに復号する",
      `Quick,
      fun () ->
        Alcotest.(check string) "plain" "/users/42" (Request.path (req "/users/42"));
        Alcotest.(check string)
          "space" "/hello world"
          (Request.path (req "/hello%20world"));
        Alcotest.(check string) "utf8" "/caf\xc3\xa9" (Request.path (req "/caf%C3%A9")) );
    ( "不変条件: %2F はセグメントを増やせない",
      `Quick,
      fun () ->
        let segs t = List.length (String.split_on_char '/' (Request.path (req t))) in
        Alcotest.(check int) "raw segments" (segs "/a/c") (segs "/a%2Fb/c");
        (* 復号すると "/" を含むので生のまま残す *)
        Alcotest.(check string) "kept raw" "/a%2Fb/c" (Request.path (req "/a%2Fb/c")) );
    ( "query は復号され重複を保つ",
      `Quick,
      fun () ->
        let r = req "/x?a=1&a=2&b=hello%20there" in
        Alcotest.(check (option string)) "first a" (Some "1") (Request.query_opt r "a");
        Alcotest.(check (list string))
          "all a" [ "1"; "2" ]
          (List.assoc "a" (Request.query r));
        Alcotest.(check (option string))
          "b" (Some "hello there") (Request.query_opt r "b");
        Alcotest.(check (option string)) "missing" None (Request.query_opt r "zz");
        Alcotest.(check string) "path has no query" "/x" (Request.path r) );
    ( "header は大小文字を区別しない",
      `Quick,
      fun () ->
        let r =
          Request.make ~meth:`GET
            ~headers:(Http.Header.init_with "Content-Type" "application/json")
            "/"
        in
        Alcotest.(check (option string))
          "lower" (Some "application/json")
          (Request.header r "content-type");
        Alcotest.(check (option string))
          "upper" (Some "application/json")
          (Request.header r "CONTENT-TYPE") );
    ( "ctx は型付きの鍵で出し入れできる",
      `Quick,
      fun () ->
        let k : int Hmap.key = Hmap.Key.create () in
        let r = req "/" in
        Alcotest.(check (option int)) "absent" None (Request.find k r);
        let r = Request.add k 42 r in
        Alcotest.(check (option int)) "present" (Some 42) (Request.find k r);
        Alcotest.(check int) "get" 42 (Request.get k r) );
    ( "sw は事前条件を持ち sw_opt は持たない",
      `Quick,
      fun () ->
        let r = req "/" in
        Alcotest.(check bool) "sw_opt" true (Request.sw_opt r = None);
        Alcotest.(check bool)
          "sw raises" true
          (try
             ignore (Request.sw r);
             false
           with Invalid_argument _ -> true) );
    ( "with_target は path/query を作り直す",
      `Quick,
      fun () ->
        let r = Request.with_target "/new/path?z=9" (req "/old") in
        Alcotest.(check string) "path" "/new/path" (Request.path r);
        Alcotest.(check (option string)) "query" (Some "9") (Request.query_opt r "z") );
  ]

(* -------------------------------------------------------------- Response *)

let response_tests =
  let open Noma in
  [
    ( "不変条件: 本体を持てない status では本体が落ちる",
      `Quick,
      fun () ->
        let r = Response.make ~status:`No_content ~body:(Body.of_string "x") () in
        Alcotest.(check bool) "204 empty" true (Body.is_empty (Response.body r));
        let r = Response.make ~status:`Not_modified ~body:(Body.of_string "x") () in
        Alcotest.(check bool) "304 empty" true (Body.is_empty (Response.body r)) );
    ( "不変条件は with_status / map_body / with_body でも保たれる",
      `Quick,
      fun () ->
        let r = Response.text "hello" in
        Alcotest.(check bool) "200 has body" false (Body.is_empty (Response.body r));
        let r' = Response.with_status `No_content r in
        Alcotest.(check bool) "after with_status" true (Body.is_empty (Response.body r'));
        let r'' = Response.with_body (Body.of_string "again") r' in
        Alcotest.(check bool) "after with_body" true (Body.is_empty (Response.body r''));
        let r''' = Response.map_body (fun _ -> Body.of_string "again") r' in
        Alcotest.(check bool) "after map_body" true (Body.is_empty (Response.body r'''))
    );
    ( "構築子は content-type を付け、呼び手の指定を尊重する",
      `Quick,
      fun () ->
        let ct r = Http.Header.get (Response.headers r) "content-type" in
        Alcotest.(check (option string))
          "text" (Some "text/plain; charset=utf-8")
          (ct (Response.text "x"));
        Alcotest.(check (option string))
          "json" (Some "application/json")
          (ct (Response.json "{}"));
        Alcotest.(check (option string))
          "html" (Some "text/html; charset=utf-8")
          (ct (Response.html "<p/>"));
        let custom =
          Response.json
            ~headers:(Http.Header.init_with "content-type" "application/ld+json")
            "{}"
        in
        Alcotest.(check (option string))
          "caller wins" (Some "application/ld+json") (ct custom) );
    ( "method_not_allowed は allow を要求する",
      `Quick,
      fun () ->
        let r = Response.method_not_allowed ~allow:[ `GET; `POST ] in
        Alcotest.check status "405" `Method_not_allowed (Response.status r);
        Alcotest.(check (option string))
          "allow" (Some "GET, POST")
          (Http.Header.get (Response.headers r) "allow");
        Alcotest.(check bool)
          "empty allow rejected" true
          (try
             ignore (Response.method_not_allowed ~allow:[]);
             false
           with Invalid_argument _ -> true) );
    ( "redirect は location を設定する",
      `Quick,
      fun () ->
        let r = Response.redirect "/elsewhere" in
        Alcotest.check status "303" `See_other (Response.status r);
        Alcotest.(check (option string))
          "location" (Some "/elsewhere")
          (Http.Header.get (Response.headers r) "location");
        let r = Response.redirect ~status:`Permanent_redirect "/x" in
        Alcotest.check status "308" `Permanent_redirect (Response.status r) );
    ( "500 の本体に内部の詳細は載らない",
      `Quick,
      fun () ->
        let r = Response.internal_server_error () in
        Alcotest.(check string)
          "generic" "Internal Server Error"
          (Body.to_string ~max_size:1000 (Response.body r)) );
  ]

(* ------------------------------------------------- Handler / モノイド則 *)

let h_const s _req = Noma.Response.text s
let mw_tag name inner req = Noma.Response.add_header "x-tag" name (inner req)
let tags r = Http.Header.get_multi (Noma.Response.headers r) "x-tag"

let law_tests =
  let open Noma in
  [
    ( "compose [] = id",
      `Quick,
      fun () ->
        let h = h_const "x" in
        Alcotest.(check (list string)) "no tags" [] (tags (compose [] h (req "/")));
        Alcotest.(check (list string)) "same as id" [] (tags (id h (req "/"))) );
    ( "compose [a;b;c] h = a (b (c h)) — 先頭が最も外側",
      `Quick,
      fun () ->
        let a, b, c = (mw_tag "a", mw_tag "b", mw_tag "c") in
        let via_compose = compose [ a; b; c ] (h_const "x") (req "/") in
        let via_nesting = a (b (c (h_const "x"))) (req "/") in
        Alcotest.(check (list string)) "same" (tags via_nesting) (tags via_compose);
        (* 内側 (c) が先に足すので、外側 (a) のタグが後ろに積まれる *)
        Alcotest.(check (list string)) "order" [ "c"; "b"; "a" ] (tags via_compose) );
    ( "結合律: compose [compose xs; compose ys] = compose (xs @ ys)",
      `Quick,
      fun () ->
        let xs = [ mw_tag "1"; mw_tag "2" ] and ys = [ mw_tag "3"; mw_tag "4" ] in
        let lhs = compose [ compose xs; compose ys ] (h_const "x") (req "/") in
        let rhs = compose (xs @ ys) (h_const "x") (req "/") in
        Alcotest.(check (list string)) "assoc" (tags rhs) (tags lhs) );
  ]

(* ----------------------------------------------------------------- abort *)

let abort_tests =
  let open Noma in
  [
    ( "深い所からの abort が直接出口へ抜ける",
      `Quick,
      fun () ->
        let deep () = abort (Response.unauthorized ()) in
        let mid () = deep () + 1 in
        let h _req = Response.text (string_of_int (mid ())) in
        let r = run_handler h (req "/") in
        Alcotest.check status "401" `Unauthorized (Response.status r) );
    ( "握り潰されても abort した応答が返り、警告が残る (effect を選んだ唯一の理由)",
      `Quick,
      fun () ->
        let h _req =
          try abort (Response.unauthorized ()) with _ -> Response.text "swallowed"
        in
        let r, logs = capture (fun () -> run_handler h (req "/")) in
        Alcotest.check status "401 despite catch-all" `Unauthorized (Response.status r);
        (* 素の例外ではこれを検知できない。effect にした意味はここに尽きる。 *)
        Alcotest.(check bool) "握り潰しが警告に残る" true (contains logs "noma.abort.swallowed");
        Alcotest.(check bool) "警告レベル" true (contains logs {|"level":"warning"|}) );
    ( "握り潰されていなければ警告は出ない",
      `Quick,
      fun () ->
        let _, logs =
          capture (fun () ->
              run_handler (fun _ -> abort (Response.forbidden ())) (req "/"))
        in
        Alcotest.(check bool) "余計な警告を出さない" false (contains logs "noma.abort.swallowed") );
    ( "分岐した fiber からの abort も回収される",
      `Quick,
      fun () ->
        (* Eio で並行に投げるのは普通のことなので、そこで落ちないこと *)
        let h _req =
          Eio_main.run @@ fun _env ->
          let result = ref (Response.text "not set") in
          Eio.Fiber.both
            (fun () -> ())
            (fun () -> result := abort (Response.forbidden ()));
          !result
        in
        Alcotest.check status "403" `Forbidden (Response.status (run_handler h (req "/")))
    );
    ( "abort 経路でも finally と Switch が解放される (discontinue を選んだ理由)",
      `Quick,
      fun () ->
        let released = ref [] in
        let h _req =
          Fun.protect
            ~finally:(fun () -> released := "protect" :: !released)
            (fun () ->
              Eio_main.run (fun _env ->
                  Eio.Switch.run (fun sw ->
                      Eio.Switch.on_release sw (fun () ->
                          released := "switch" :: !released);
                      abort (Response.forbidden ()))))
        in
        let r = run_handler h (req "/") in
        Alcotest.check status "403" `Forbidden (Response.status r);
        Alcotest.(check (list string)) "both released" [ "protect"; "switch" ] !released
    );
    ( "abort 以外の例外はそのまま通る",
      `Quick,
      fun () ->
        let h _req = failwith "boom" in
        Alcotest.check_raises "propagates" (Failure "boom") (fun () ->
            ignore (run_handler h (req "/"))) );
    ( "abort しなければ戻り値がそのまま返る",
      `Quick,
      fun () ->
        let r = run_handler (h_const "fine") (req "/") in
        Alcotest.check status "200" `OK (Response.status r);
        Alcotest.(check string)
          "body" "fine"
          (Body.to_string ~max_size:100 (Response.body r)) );
  ]

let () =
  Alcotest.run "noma"
    [
      ("Body", body_tests);
      ("Request", request_tests);
      ("Response", response_tests);
      ("Handler/laws", law_tests);
      ("abort", abort_tests);
    ]
