open Noma

let env pairs name = List.assoc_opt name pairs

type app = { port : int; db : string; debug : bool; level : string }

let app_config =
  let open Config in
  let+ port = default 8080 (int "PORT")
  and+ db = secret (string "DATABASE_URL")
  and+ debug = default false (bool "DEBUG")
  and+ level =
    default "info"
      (enum [ ("debug", "debug"); ("info", "info"); ("warn", "warn") ] "LOG_LEVEL")
  in
  { port; db; debug; level }

let tests =
  [
    ( "全部揃っていれば読める",
      `Quick,
      fun () ->
        match
          Config.load
            ~getenv:
              (env
                 [
                   ("PORT", "9000");
                   ("DATABASE_URL", "postgres://x");
                   ("DEBUG", "yes");
                   ("LOG_LEVEL", "WARN");
                 ])
            app_config
        with
        | Ok c ->
            Alcotest.(check int) "port" 9000 c.port;
            Alcotest.(check string) "db" "postgres://x" c.db;
            Alcotest.(check bool) "debug" true c.debug;
            Alcotest.(check string) "level (大小文字を問わない)" "warn" c.level
        | Error e -> Alcotest.failf "読めるはず: %s" (String.concat "; " e) );
    ( "12factor III: 欠落は全部まとめて一度に報告する",
      `Quick,
      fun () ->
        let cfg =
          let open Config in
          let+ a = string "A_MISSING"
          and+ b = string "B_MISSING"
          and+ c = int "C_MISSING" in
          (a, b, c)
        in
        match Config.load ~getenv:(env []) cfg with
        | Ok _ -> Alcotest.fail "落ちるはず"
        | Error problems ->
            Alcotest.(check int) "3 件とも報告される" 3 (List.length problems);
            List.iter2
              (fun name msg ->
                Alcotest.(check bool)
                  name true
                  (String.length msg > 0 && String.sub msg 0 (String.length name) = name))
              [ "A_MISSING"; "B_MISSING"; "C_MISSING" ]
              problems );
    ( "読めない値は既定値で隠さずに報告する",
      `Quick,
      fun () ->
        match Config.load ~getenv:(env [ ("PORT", "eight thousand") ]) app_config with
        | Ok _ -> Alcotest.fail "落ちるはず"
        | Error problems ->
            (* PORT の打ち間違いと DATABASE_URL の欠落が両方出る *)
            Alcotest.(check int) "2 件" 2 (List.length problems);
            Alcotest.(check bool)
              "PORT が報告される" true
              (List.exists
                 (fun m -> String.length m > 4 && String.sub m 0 4 = "PORT")
                 problems);
            Alcotest.(check bool)
              "実際の値が添えられる" true
              (List.exists
                 (fun m ->
                   let n = String.length m in
                   let rec has i =
                     i + 15 <= n && (String.sub m i 15 = "eight thousand\"" || has (i + 1))
                   in
                   has 0)
                 problems) );
    ( "未設定なら既定値、設定されていればその値",
      `Quick,
      fun () ->
        let get e = Config.load ~getenv:(env e) app_config in
        (match get [ ("DATABASE_URL", "x") ] with
        | Ok c -> Alcotest.(check int) "既定" 8080 c.port
        | Error e -> Alcotest.failf "%s" (String.concat ";" e));
        match get [ ("DATABASE_URL", "x"); ("PORT", "1") ] with
        | Ok c -> Alcotest.(check int) "明示" 1 c.port
        | Error e -> Alcotest.failf "%s" (String.concat ";" e) );
    ( "optional は未設定を None にする",
      `Quick,
      fun () ->
        let cfg = Config.optional (Config.string "MAYBE") in
        Alcotest.(check (option string))
          "none" None
          (Result.get_ok (Config.load ~getenv:(env []) cfg));
        Alcotest.(check (option string))
          "some" (Some "v")
          (Result.get_ok (Config.load ~getenv:(env [ ("MAYBE", "v") ]) cfg)) );
    ( "enum は外れた値に候補を添える",
      `Quick,
      fun () ->
        let cfg = Config.enum [ ("a", 1); ("b", 2) ] "CHOICE" in
        match Config.load ~getenv:(env [ ("CHOICE", "z") ]) cfg with
        | Ok _ -> Alcotest.fail "落ちるはず"
        | Error [ msg ] ->
            let n = String.length msg in
            let rec has i sub =
              i + String.length sub <= n
              && (String.sub msg i (String.length sub) = sub || has (i + 1) sub)
            in
            Alcotest.(check bool) "候補が出る" true (has 0 "a | b")
        | Error _ -> Alcotest.fail "1 件のはず" );
    ( "custom は独自の型を足せる",
      `Quick,
      fun () ->
        let port_range =
          Config.custom ~name:"ポート番号"
            (fun s ->
              match int_of_string_opt s with
              | Some n when n > 0 && n < 65536 -> Ok n
              | _ -> Error "1..65535 の範囲外")
            (Config.string "P")
        in
        Alcotest.(check int)
          "ok" 443
          (Result.get_ok (Config.load ~getenv:(env [ ("P", "443") ]) port_range));
        Alcotest.(check bool)
          "範囲外は落ちる" true
          (Result.is_error (Config.load ~getenv:(env [ ("P", "99999") ]) port_range)) );
    ( "describe は秘匿を伏字にし、未設定には必要なものを書く",
      `Quick,
      fun () ->
        let d =
          Config.describe
            ~getenv:(env [ ("DATABASE_URL", "postgres://user:pw@host/db") ])
            app_config
        in
        Alcotest.(check (option string))
          "秘匿" (Some "********")
          (List.assoc_opt "DATABASE_URL" d);
        let port_desc = Option.get (List.assoc_opt "PORT" d) in
        Alcotest.(check bool)
          "未設定と判る" true
          (String.length port_desc > 0 && port_desc.[0] = '(') );
    ( "load_exn は全件を並べて落ちる",
      `Quick,
      fun () ->
        try
          ignore (Config.load_exn ~getenv:(env []) app_config);
          Alcotest.fail "落ちるはず"
        with Failure msg ->
          Alcotest.(check bool)
            "DATABASE_URL が文面にある" true
            (let n = String.length msg in
             let rec has i =
               i + 12 <= n && (String.sub msg i 12 = "DATABASE_URL" || has (i + 1))
             in
             has 0) );
  ]

let () = Alcotest.run "noma.config" [ ("Config (12factor III)", tests) ]
