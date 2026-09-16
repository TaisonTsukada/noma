(* アダプタの契約 A1–A6 を実サーバーで検証する。 *)

open Noma
module P = Http_probe

let users () = Router.(s "users" /? nil)
let user () = Router.(s "users" / int /? nil)

let app () =
  Router.handler
    (Router.make
       [
         Router.get (users ()) (fun _ -> Response.text "index");
         Router.get (user ()) (fun id _ -> Response.text ("user " ^ string_of_int id));
         Router.post (users ()) (fun r ->
             (* 本体を読み切る正常な経路 *)
             let b = Body.to_string ~max_size:10_000_000 (Request.body r) in
             Response.text (Printf.sprintf "got %d bytes" (String.length b)));
         Router.get
           Router.(s "stream" /? nil)
           (fun _ -> Response.stream (Eio.Flow.string_source "streamed-payload"));
         Router.get
           Router.(s "empty" /? nil)
           (fun _ -> Response.empty ~status:`No_content ());
         Router.get Router.(s "boom" /? nil) (fun _ -> failwith "handler exploded");
         Router.get Router.(s "abort" /? nil) (fun _ -> abort (Response.forbidden ()));
       ])

let basic =
  [
    ( "素の往復ができる",
      `Quick,
      fun () ->
        P.with_server (app ()) (fun connect ->
            let r = P.round_trip connect (P.get "/users/42") in
            Alcotest.(check int) "status" 200 r.P.status;
            Alcotest.(check string) "body" "user 42" r.P.body;
            Alcotest.(check (option string))
              "content-length" (Some "7") (P.header r "content-length")) );
    ( "A6: 長さ既知は content-length、不明は chunked",
      `Quick,
      fun () ->
        P.with_server (app ()) (fun connect ->
            let fixed = P.round_trip connect (P.get "/users") in
            Alcotest.(check (option string))
              "fixed" (Some "5")
              (P.header fixed "content-length");
            Alcotest.(check (option string))
              "no TE" None
              (P.header fixed "transfer-encoding");
            let chunked = P.round_trip connect (P.get "/stream") in
            Alcotest.(check (option string))
              "chunked" (Some "chunked")
              (P.header chunked "transfer-encoding");
            Alcotest.(check string) "streamed body" "streamed-payload" chunked.P.body) );
    ( "A4: 204 は本体も枠付けヘッダも持たない",
      `Quick,
      fun () ->
        P.with_server (app ()) (fun connect ->
            let r = P.round_trip connect (P.get "/empty") in
            Alcotest.(check int) "status" 204 r.P.status;
            Alcotest.(check string) "no body" "" r.P.body;
            Alcotest.(check (option string)) "no CL" None (P.header r "content-length");
            Alcotest.(check (option string)) "no TE" None (P.header r "transfer-encoding"))
    );
    ( "A4: HEAD は本体を書かず content-length は GET の長さを残す",
      `Quick,
      fun () ->
        P.with_server (app ()) (fun connect ->
            let raw = "HEAD /users/42 HTTP/1.1\r\nhost: localhost\r\n\r\n" in
            let flow = connect () in
            Eio.Flow.copy_string raw flow;
            let br = Eio.Buf_read.of_flow ~max_size:100_000 flow in
            (* HEAD なので content-length が 7 でも本体は来ない。
               read_response は content-length 分読もうとするので手で読む。 *)
            let line = Eio.Buf_read.line br in
            Alcotest.(check bool)
              "200" true
              (String.length line > 12 && String.sub line 9 3 = "200");
            let rec hdrs acc =
              match Eio.Buf_read.line br with "" -> acc | l -> hdrs (l :: acc)
            in
            let hs = List.map String.lowercase_ascii (hdrs []) in
            Alcotest.(check bool)
              "content-length: 7 が残る" true
              (List.exists (fun h -> h = "content-length: 7") hs);
            Eio.Flow.close flow) );
  ]

let resilience =
  [
    ( "A1: 深い abort がワイヤまで届く",
      `Quick,
      fun () ->
        P.with_server (app ()) (fun connect ->
            let r = P.round_trip connect (P.get "/abort") in
            Alcotest.(check int) "403" 403 r.P.status) );
    ( "recover 無しのハンドラ例外は接続が落ちる (recover が必須である証拠)",
      `Quick,
      fun () ->
        P.with_server (app ()) (fun connect ->
            let flow = connect () in
            Eio.Flow.copy_string (P.get "/boom") flow;
            let br = Eio.Buf_read.of_flow ~max_size:100_000 flow in
            (* 応答なしで接続が閉じる。これが recover を必須にしている理由。 *)
            Alcotest.(check bool)
              "応答が来ない" true
              (match Eio.Buf_read.line br with
              | _ -> false
              | exception End_of_file -> true
              | exception _ -> true);
            Eio.Flow.close flow) );
    ( "recover を入れれば 500 が返り接続は生きる",
      `Quick,
      fun () ->
        let guarded = Middleware.recover () (app ()) in
        P.with_server guarded (fun connect ->
            let flow = connect () in
            Eio.Flow.copy_string (P.get "/boom") flow;
            let br = Eio.Buf_read.of_flow ~max_size:100_000 flow in
            let r = P.read_response br in
            Alcotest.(check int) "500" 500 r.P.status;
            Alcotest.(check bool) "トレースが漏れない" false (String.length r.P.body > 100);
            (* 同じ接続で次が通る = 接続が生きている *)
            Eio.Flow.copy_string (P.get "/users") flow;
            let r2 = P.read_response br in
            Alcotest.(check int) "keep-alive 生存" 200 r2.P.status;
            Eio.Flow.close flow) );
    ( "A3: 本体を読まずに応答しても次のリクエストが壊れない",
      `Quick,
      fun () ->
        P.with_server (app ()) (fun connect ->
            let flow = connect () in
            let br = Eio.Buf_read.of_flow ~max_size:1_000_000 flow in
            let payload = String.make 20_000 'x' in
            (* 404 の経路 = 本体を一切読まずに応答する *)
            Eio.Flow.copy_string (P.post "/nope" payload) flow;
            let r1 = P.read_response br in
            Alcotest.(check int) "404" 404 r1.P.status;
            (* ここで drain されていなければ 20000 バイトの 'x' が
               次のリクエスト行として解釈される *)
            Eio.Flow.copy_string (P.get "/users") flow;
            let r2 = P.read_response br in
            Alcotest.(check int) "2 本目が正しく処理される" 200 r2.P.status;
            Alcotest.(check string) "2 本目の本体" "index" r2.P.body;
            Eio.Flow.close flow) );
    ( "A3: drain 上限を超える未読本体では接続を畳む (次が解釈されない)",
      `Quick,
      fun () ->
        P.with_server ~max_drain_bytes:1024 (app ()) (fun connect ->
            let flow = connect () in
            let br = Eio.Buf_read.of_flow ~max_size:1_000_000 flow in
            let payload = String.make 20_000 'x' in
            (* 書き込み中に RST を受けうる。接続を畳むのだから当然で、
               ここで保証するのは 404 が届くことではなく、
               残りのバイトが次のリクエストとして解釈されないこと。 *)
            (try Eio.Flow.copy_string (P.post "/nope" payload) flow with _ -> ());
            let served_second =
              try
                ignore (P.read_response br);
                Eio.Flow.copy_string (P.get "/users") flow;
                let r2 = P.read_response br in
                r2.P.status = 200 && r2.P.body = "index"
              with _ -> false
            in
            Alcotest.(check bool) "2 本目は通らない" false served_second;
            try Eio.Flow.close flow with _ -> ()) );
    ( "本体を読み切る経路では keep-alive が続く",
      `Quick,
      fun () ->
        P.with_server (app ()) (fun connect ->
            let flow = connect () in
            let br = Eio.Buf_read.of_flow ~max_size:1_000_000 flow in
            let payload = String.make 5_000 'y' in
            Eio.Flow.copy_string (P.post "/users" payload) flow;
            let r1 = P.read_response br in
            Alcotest.(check string) "1 本目" "got 5000 bytes" r1.P.body;
            Eio.Flow.copy_string (P.post "/users" payload) flow;
            let r2 = P.read_response br in
            Alcotest.(check string) "2 本目" "got 5000 bytes" r2.P.body;
            Eio.Flow.close flow) );
    ( "頭部の上限を超えても OOM せず接続が終わる",
      `Quick,
      fun () ->
        P.with_server ~max_header_size:4096 (app ()) (fun connect ->
            let big = String.make 200_000 'a' in
            let raw =
              Printf.sprintf "GET /users HTTP/1.1\r\nhost: localhost\r\nx-big: %s\r\n\r\n"
                big
            in
            let flow = connect () in
            let br = Eio.Buf_read.of_flow ~max_size:1_000_000 flow in
            (try Eio.Flow.copy_string raw flow with _ -> ());
            (* 431 が届けばそれでよいが、接続を畳む以上 RST で失われることもある。
               保証するのは「200 を返さない」ことと「終わる」こと。 *)
            let outcome = try `Status (P.read_response br).P.status with _ -> `Closed in
            (match outcome with
            | `Status 431 -> ()
            | `Closed -> ()
            | `Status n -> Alcotest.failf "想定外の応答: %d" n);
            try Eio.Flow.close flow with _ -> ()) );
  ]

let () =
  Alcotest.run "noma.server" [ ("基本 / A4 / A6", basic); ("耐障害性 / A1 / A3", resilience) ]
