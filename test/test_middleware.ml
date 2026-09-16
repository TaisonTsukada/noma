open Noma
module M = Middleware

let status =
  Alcotest.testable
    (fun ppf s -> Format.pp_print_int ppf (Http.Status.to_int s))
    (fun a b -> Http.Status.to_int a = Http.Status.to_int b)

let req ?(meth = `GET) ?(headers = []) ?body target =
  Request.make ~meth ~headers:(Http.Header.of_list headers) ?body target

let body r = Body.to_string ~max_size:1_000_000 (Response.body r)
let hdr r k = Http.Header.get (Response.headers r) k
let ok _ = Response.text "ok"

let contains hay needle =
  let nl = String.length needle and hl = String.length hay in
  let rec go i = i + nl <= hl && (String.sub hay i nl = needle || go (i + 1)) in
  nl = 0 || go 0

(* ログを捕まえる reporter *)
let capture f =
  let buf = Buffer.create 256 in
  let ppf = Format.formatter_of_buffer buf in
  let saved = Logs.reporter () in
  let saved_level = Logs.level () in
  Logs.set_reporter (Log.json_reporter ~ppf ~now:(fun () -> 0.) ());
  Logs.set_level (Some Logs.Debug);
  Fun.protect
    ~finally:(fun () ->
      Logs.set_reporter saved;
      Logs.set_level saved_level)
    (fun () ->
      let r = f () in
      Format.pp_print_flush ppf ();
      (r, Buffer.contents buf))

(* ------------------------------------------------------------- recover *)

let recover_tests =
  [
    ( "例外を 500 に変え、トレースを本体に載せない",
      `Quick,
      fun () ->
        let mw = M.recover ~on_error:(fun _ _ -> ()) () in
        let res = mw (fun _ -> failwith "secret internals") (req "/") in
        Alcotest.check status "500" `Internal_server_error (Response.status res);
        Alcotest.(check bool) "秘密が漏れない" false (contains (body res) "secret");
        Alcotest.(check string) "定型文" "Internal Server Error" (body res) );
    ( "on_error に例外とバックトレースが渡る",
      `Quick,
      fun () ->
        let seen = ref None in
        let mw = M.recover ~on_error:(fun e bt -> seen := Some (e, bt)) () in
        ignore (mw (fun _ -> failwith "boom") (req "/"));
        match !seen with
        | Some (Failure m, _) when m = "boom" -> ()
        | _ -> Alcotest.fail "on_error が呼ばれていない" );
    ( "M2: Aborted を再送出する",
      `Quick,
      fun () ->
        let mw = M.recover ~on_error:(fun _ _ -> ()) () in
        let h = mw (fun _ -> abort (Response.forbidden ())) in
        Alcotest.check status "403 が生き残る" `Forbidden
          (Response.status (run_handler h (req "/"))) );
    ( "M2: Cancelled を再送出する",
      `Quick,
      fun () ->
        let mw = M.recover ~on_error:(fun _ _ -> ()) () in
        let e = Eio.Cancel.Cancelled (Failure "x") in
        Alcotest.(check bool)
          "素通し" true
          (try
             ignore (mw (fun _ -> raise e) (req "/"));
             false
           with Eio.Cancel.Cancelled _ -> true) );
    ( "既定の on_error はログに出し本体には出さない",
      `Quick,
      fun () ->
        let mw = M.recover () in
        let res, logs =
          capture (fun () -> mw (fun _ -> failwith "logged-only") (req "/"))
        in
        Alcotest.(check bool) "ログに出る" true (contains logs "logged-only");
        Alcotest.(check bool) "ログにトレースが出る" true (contains logs "backtrace");
        Alcotest.(check bool) "本体には出ない" false (contains (body res) "logged-only") );
  ]

(* ---------------------------------------------------------- request_id *)

let request_id_tests =
  [
    ( "無ければ採番し、ctx と応答ヘッダに載せる",
      `Quick,
      fun () ->
        let seen = ref None in
        let mw = M.request_id () in
        let res =
          mw
            (fun r ->
              seen := Request.find M.request_id_key r;
              ok r)
            (req "/")
        in
        let from_hdr = hdr res "x-request-id" in
        Alcotest.(check bool) "採番された" true (!seen <> None);
        Alcotest.(check (option string)) "ヘッダと ctx が一致" !seen from_hdr );
    ( "既にあれば受け継ぐ",
      `Quick,
      fun () ->
        let seen = ref None in
        let mw = M.request_id () in
        let r = req ~headers:[ ("x-request-id", "upstream-42") ] "/" in
        let res =
          mw
            (fun r ->
              seen := Request.find M.request_id_key r;
              ok r)
            r
        in
        Alcotest.(check (option string)) "ctx" (Some "upstream-42") !seen;
        Alcotest.(check (option string))
          "ヘッダ" (Some "upstream-42") (hdr res "x-request-id") );
    ( "ヘッダ名と採番器を差し替えられる",
      `Quick,
      fun () ->
        let mw = M.request_id ~header:"x-trace" ~gen:(fun () -> "fixed") () in
        let res = mw ok (req "/") in
        Alcotest.(check (option string)) "custom" (Some "fixed") (hdr res "x-trace") );
    ( "採番は繰り返し異なる",
      `Quick,
      fun () ->
        let mw = M.request_id () in
        let id () = hdr (mw ok (req "/")) "x-request-id" in
        let a = id () and b = id () and c = id () in
        Alcotest.(check bool) "全部違う" true (a <> b && b <> c && a <> c) );
  ]

(* --------------------------------------------------------------- cors *)

let cors_tests =
  let allowed = `List [ "https://app.example" ] in
  [
    ( "Origin が無ければ何も足さない",
      `Quick,
      fun () ->
        let res = M.cors ~origins:allowed () ok (req "/") in
        Alcotest.(check (option string))
          "no ACAO" None
          (hdr res "access-control-allow-origin") );
    ( "許していない Origin にも足さない",
      `Quick,
      fun () ->
        let r = req ~headers:[ ("origin", "https://evil.example") ] "/" in
        let res = M.cors ~origins:allowed () ok r in
        Alcotest.(check (option string))
          "no ACAO" None
          (hdr res "access-control-allow-origin") );
    ( "許した Origin には足し、vary: origin も付ける",
      `Quick,
      fun () ->
        let r = req ~headers:[ ("origin", "https://app.example") ] "/" in
        let res = M.cors ~origins:allowed () ok r in
        Alcotest.(check (option string))
          "ACAO" (Some "https://app.example")
          (hdr res "access-control-allow-origin");
        Alcotest.(check (option string)) "vary" (Some "origin") (hdr res "vary");
        Alcotest.(check string) "下流は動く" "ok" (body res) );
    ( "`Any は * を返し vary を付けない",
      `Quick,
      fun () ->
        let r = req ~headers:[ ("origin", "https://whatever") ] "/" in
        let res = M.cors ~origins:`Any () ok r in
        Alcotest.(check (option string))
          "ACAO" (Some "*")
          (hdr res "access-control-allow-origin");
        Alcotest.(check (option string)) "no vary" None (hdr res "vary") );
    ( "preflight は下流を呼ばず 204 を返す",
      `Quick,
      fun () ->
        let called = ref false in
        let r =
          req ~meth:`OPTIONS
            ~headers:
              [
                ("origin", "https://app.example");
                ("access-control-request-method", "POST");
              ]
            "/"
        in
        let res =
          M.cors ~origins:allowed ~max_age:600 ()
            (fun rq ->
              called := true;
              ok rq)
            r
        in
        Alcotest.check status "204" `No_content (Response.status res);
        Alcotest.(check bool) "下流は呼ばれない" false !called;
        Alcotest.(check (option string))
          "max-age" (Some "600")
          (hdr res "access-control-max-age");
        Alcotest.(check bool)
          "allow-methods" true
          (contains
             (Option.value ~default:"" (hdr res "access-control-allow-methods"))
             "POST") );
    ( "credentials:true と `Any は事前条件で弾く",
      `Quick,
      fun () ->
        Alcotest.(check bool)
          "rejected" true
          (try
             let (_ : Noma.middleware) = M.cors ~origins:`Any ~credentials:true () in
             false
           with Invalid_argument _ -> true) );
  ]

(* ----------------------------------------------------- secure_headers *)

let secure_tests =
  [
    ( "既定のヘッダを足す。HSTS は既定で付けない",
      `Quick,
      fun () ->
        let res = M.secure_headers () ok (req "/") in
        Alcotest.(check (option string))
          "nosniff" (Some "nosniff")
          (hdr res "x-content-type-options");
        Alcotest.(check (option string))
          "referrer" (Some "no-referrer") (hdr res "referrer-policy");
        Alcotest.(check (option string)) "frame" (Some "DENY") (hdr res "x-frame-options");
        Alcotest.(check (option string))
          "hsts 既定は付けない" None
          (hdr res "strict-transport-security") );
    ( "ハンドラが設定したヘッダは上書きしない",
      `Quick,
      fun () ->
        let h _ =
          Response.set_header "x-frame-options" "SAMEORIGIN" (Response.text "x")
        in
        let res = M.secure_headers () h (req "/") in
        Alcotest.(check (option string))
          "handler wins" (Some "SAMEORIGIN") (hdr res "x-frame-options") );
    ( "HSTS を明示すれば付く",
      `Quick,
      fun () ->
        let res = M.secure_headers ~hsts:(`Max_age 31536000) () ok (req "/") in
        Alcotest.(check (option string))
          "hsts" (Some "max-age=31536000; includeSubDomains")
          (hdr res "strict-transport-security") );
    ( "HSTS の max-age は正であること",
      `Quick,
      fun () ->
        Alcotest.(check bool)
          "rejected" true
          (try
             let (_ : Noma.middleware) = M.secure_headers ~hsts:(`Max_age 0) () in
             false
           with Invalid_argument _ -> true) );
  ]

(* ---------------------------------------------------------- body_limit *)

let body_limit_tests =
  [
    ( "content-length が上限超なら下流を呼ばずに 413",
      `Quick,
      fun () ->
        let called = ref false in
        let r = req ~meth:`POST ~headers:[ ("content-length", "99999") ] "/" in
        let res =
          M.body_limit ~max_bytes:1024
            (fun rq ->
              called := true;
              ok rq)
            r
        in
        Alcotest.check status "413" `Request_entity_too_large (Response.status res);
        Alcotest.(check bool) "下流は呼ばれない" false !called );
    ( "content-length を詐称しても読み出し時に 413",
      `Quick,
      fun () ->
        let big = String.make 5000 'x' in
        let r =
          req ~meth:`POST
            ~headers:[ ("content-length", "10") ] (* 嘘 *)
            ~body:(Body.of_source (Eio.Flow.string_source big))
            "/"
        in
        let res =
          M.body_limit ~max_bytes:1024
            (fun rq ->
              Response.text (Body.to_string ~max_size:1_000_000 (Request.body rq)))
            r
        in
        Alcotest.check status "413" `Request_entity_too_large (Response.status res) );
    ( "上限内なら素通り",
      `Quick,
      fun () ->
        let r =
          req ~meth:`POST
            ~headers:[ ("content-length", "5") ]
            ~body:(Body.of_source (Eio.Flow.string_source "hello"))
            "/"
        in
        let res =
          M.body_limit ~max_bytes:1024
            (fun rq ->
              Response.text (Body.to_string ~max_size:1_000_000 (Request.body rq)))
            r
        in
        Alcotest.(check string) "本体が届く" "hello" (body res) );
    ( "max_bytes は正であること (リクエストを待たず組み立て時に落ちる)",
      `Quick,
      fun () ->
        Alcotest.(check bool)
          "rejected" true
          (try
             let (_ : Noma.middleware) = M.body_limit ~max_bytes:0 in
             false
           with Invalid_argument _ -> true) );
  ]

(* -------------------------------------------- clock を要するものと契約検査 *)

let with_clocks env =
  let clock = (env#clock :> float Eio.Time.clock_ty Eio.Resource.t) in
  let mono = (env#mono_clock :> Mtime.t Eio.Time.clock_ty Eio.Resource.t) in
  let timeout_tests =
    [
      ( "時間内なら素通り",
        `Quick,
        fun () ->
          let res = M.timeout ~clock ~seconds:5. ok (req "/") in
          Alcotest.check status "200" `OK (Response.status res) );
      ( "超過したら 503",
        `Quick,
        fun () ->
          let slow _ =
            Eio.Time.sleep clock 1.0;
            Response.text "too late"
          in
          let res = M.timeout ~clock ~seconds:0.05 slow (req "/") in
          Alcotest.check status "503" `Service_unavailable (Response.status res) );
      ( "時間内の abort は素通しする",
        `Quick,
        fun () ->
          let h = M.timeout ~clock ~seconds:5. (fun _ -> abort (Response.forbidden ())) in
          Alcotest.check status "403" `Forbidden
            (Response.status (run_handler h (req "/"))) );
      ( "seconds は正であること (リクエストを待たず組み立て時に落ちる)",
        `Quick,
        fun () ->
          Alcotest.(check bool)
            "rejected" true
            (try
               let (_ : Noma.middleware) = M.timeout ~clock ~seconds:0. in
               false
             with Invalid_argument _ -> true) );
    ]
  in
  let logger_tests =
    [
      ( "1 リクエスト 1 行、必要な項目が載る",
        `Quick,
        fun () ->
          let mw = Noma.compose [ M.request_id (); M.logger ~clock:mono () ] in
          let _, logs = capture (fun () -> mw ok (req "/users?a=1")) in
          let lines = String.split_on_char '\n' (String.trim logs) in
          Alcotest.(check int) "1 行" 1 (List.length lines);
          List.iter
            (fun k ->
              Alcotest.(check bool) k true (contains logs (Printf.sprintf "\"%s\"" k)))
            [ "method"; "path"; "status"; "dur_ms"; "req_id"; "client"; "bytes" ];
          Alcotest.(check bool) "path が載る" true (contains logs "/users") );
      ( "M5: 下流の本体を読まない (流れの応答でも空にしない)",
        `Quick,
        fun () ->
          let mw = M.logger ~clock:mono () in
          let h _ = Response.stream (Eio.Flow.string_source "payload") in
          let res, logs = capture (fun () -> mw h (req "/")) in
          Alcotest.(check string) "本体が残っている" "payload" (body res);
          Alcotest.(check bool) "長さ不明は null" true (contains logs "\"bytes\":null") );
      ( "例外で抜けてもログを出して再送出する",
        `Quick,
        fun () ->
          let mw = M.logger ~clock:mono () in
          let raised =
            try
              ignore (snd (capture (fun () -> mw (fun _ -> failwith "boom") (req "/"))));
              false
            with Failure m when m = "boom" -> true
          in
          Alcotest.(check bool) "再送出される" true raised );
    ]
  in
  let contract_tests =
    List.map
      (fun (name, mw) -> (name, `Quick, fun () -> Noma_test.check_middleware ~name mw))
      [
        ("recover", M.recover ());
        ("request_id", M.request_id ());
        ("logger", M.logger ~clock:mono ());
        ("timeout", M.timeout ~clock ~seconds:30.);
        ("body_limit", M.body_limit ~max_bytes:1024);
        ("cors (list)", M.cors ~origins:(`List [ "https://a" ]) ());
        ("cors (any)", M.cors ~origins:`Any ());
        ("secure_headers", M.secure_headers ());
        ( "推奨スタック全体",
          Noma.compose
            [
              M.recover ();
              M.request_id ();
              M.logger ~clock:mono ();
              M.secure_headers ();
              M.timeout ~clock ~seconds:30.;
              M.body_limit ~max_bytes:1_048_576;
            ] );
      ]
  in
  (timeout_tests, logger_tests, contract_tests)

let () =
  Eio_main.run @@ fun env ->
  let timeout_tests, logger_tests, contract_tests = with_clocks env in
  Alcotest.run "noma.middleware"
    [
      ("recover", recover_tests);
      ("request_id", request_id_tests);
      ("cors", cors_tests);
      ("secure_headers", secure_tests);
      ("body_limit", body_limit_tests);
      ("timeout", timeout_tests);
      ("logger", logger_tests);
      ("契約検査 (M1-M5)", contract_tests);
    ]
