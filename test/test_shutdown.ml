(* 12factor IX: SIGTERM で新規受付を止め、処理中を完走させて 0 で終わる。
   実プロセスに実シグナルを送って確かめる。 *)

module P = Http_probe

let read_line_from br = Eio.Buf_read.line br

let () =
  Alcotest.run "noma.shutdown"
    [
      ( "graceful shutdown (12factor IX)",
        [
          ( "SIGTERM: 処理中は完走し、新規は拒否され、0 で終わる",
            `Quick,
            fun () ->
              Eio_main.run @@ fun env ->
              Eio.Switch.run @@ fun sw ->
              let out_src, out_sink = Eio_unix.pipe sw in
              let child =
                Eio.Process.spawn ~sw env#process_mgr ~stdout:out_sink
                  [ Sys.getenv "NOMA_SHUTDOWN_SERVER" ]
              in
              let out = Eio.Buf_read.of_flow ~max_size:4096 out_src in
              let port = Scanf.sscanf (read_line_from out) "PORT=%d" (fun p -> p) in
              let connect () =
                Eio.Net.connect ~sw env#net (`Tcp (Eio.Net.Ipaddr.V4.loopback, port))
              in
              (* まず疎通 *)
              let warm = P.round_trip connect (P.get "/fast") in
              Alcotest.(check int) "起動できている" 200 warm.P.status;

              (* 1 秒かかるリクエストを投げ、その最中に SIGTERM を送る *)
              let slow_flow = connect () in
              Eio.Flow.copy_string (P.get "/slow") slow_flow;
              let slow_br = Eio.Buf_read.of_flow ~max_size:65536 slow_flow in
              Eio.Time.sleep env#clock 0.2;
              Eio.Process.signal child Sys.sigterm;

              (* 処理中のリクエストは完走する *)
              let slow = P.read_response slow_br in
              Alcotest.(check int) "処理中は完走する" 200 slow.P.status;
              Alcotest.(check string) "本体も揃う" "slow done" slow.P.body;

              (* 新規接続は処理されない。

                 stop 後もリスニングソケットは switch が終わるまで閉じないので、
                 接続自体はカーネルの backlog に入って成立しうる。ただし accept
                 ループは止まっているので誰も応答しない。だから「接続が拒否される」
                 ではなく「応答が返らない」で確かめる。 *)
              Eio.Time.sleep env#clock 0.2;
              let served =
                match
                  Eio.Time.with_timeout env#clock 1.0 (fun () ->
                      try
                        let f = connect () in
                        Eio.Flow.copy_string (P.get "/fast") f;
                        let br = Eio.Buf_read.of_flow ~max_size:65536 f in
                        let r = P.read_response br in
                        Eio.Flow.close f;
                        Ok (r.P.status = 200)
                      with _ -> Ok false)
                with
                | Ok served -> served
                | Error `Timeout -> false
              in
              Alcotest.(check bool) "新規は処理されない" false served;

              (* 排出が終わるには、こちらが掴んでいる接続を離す必要がある。
                 keep-alive の接続を開いたままだとサーバーは待ち続ける —
                 それこそが「処理中を待つ」という約束そのものだからである。 *)
              Eio.Flow.close slow_flow;

              (* 排出してから 0 で終わる *)
              Alcotest.(check string) "排出を報告する" "DRAINED" (read_line_from out);
              match Eio.Process.await child with
              | `Exited 0 -> ()
              | `Exited n -> Alcotest.failf "終了コードが 0 でない: %d" n
              | `Signaled n -> Alcotest.failf "シグナルで落ちた: %d" n );
          ( "drain_deadline: 掴まれたままの接続は期限で打ち切られる",
            `Quick,
            fun () ->
              Eio_main.run @@ fun env ->
              Eio.Switch.run @@ fun sw ->
              let out_src, out_sink = Eio_unix.pipe sw in
              let child =
                Eio.Process.spawn ~sw env#process_mgr ~stdout:out_sink
                  ~env:
                    (Array.append (Unix.environment ()) [| "NOMA_DRAIN_DEADLINE=0.5" |])
                  [ Sys.getenv "NOMA_SHUTDOWN_SERVER" ]
              in
              let out = Eio.Buf_read.of_flow ~max_size:4096 out_src in
              let port = Scanf.sscanf (read_line_from out) "PORT=%d" (fun p -> p) in
              let connect () =
                Eio.Net.connect ~sw env#net (`Tcp (Eio.Net.Ipaddr.V4.loopback, port))
              in
              (* keep-alive の接続を開いたまま握り続ける。
                 期限が無ければサーバーはこれを永久に待つ。 *)
              let held = connect () in
              Eio.Flow.copy_string (P.get "/fast") held;
              let br = Eio.Buf_read.of_flow ~max_size:65536 held in
              ignore (P.read_response br);
              Eio.Process.signal child Sys.sigterm;
              (* 期限 0.5 秒 + 余裕。掴んだままでも終わること。 *)
              let finished =
                match
                  Eio.Time.with_timeout env#clock 5.0 (fun () ->
                      Ok (Eio.Process.await child))
                with
                | Ok st -> Some st
                | Error `Timeout -> None
              in
              (try Eio.Flow.close held with _ -> ());
              match finished with None -> Alcotest.fail "期限を過ぎても終わらなかった" | Some _ -> () );
        ] );
    ]
