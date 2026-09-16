(* graceful shutdown の検査に使う子プロセス。

   port 0 で待ち受け、実際の port を stdout に 1 行出す。/slow は 1 秒かかる。
   SIGTERM / SIGINT で停止する。 *)

let () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let clock = env#clock in
  let app =
    Noma.Router.handler
      (Noma.Router.make
         [
           Noma.Router.get
             Noma.Router.(s "slow" /? nil)
             (fun _ ->
               Eio.Time.sleep clock 1.0;
               Noma.Response.text "slow done");
           Noma.Router.get
             Noma.Router.(s "fast" /? nil)
             (fun _ -> Noma.Response.text "fast");
         ])
  in
  let stop = Noma_cohttp_eio.Signal.stop_on ~sw [ Sys.sigterm; Sys.sigint ] in
  (* NOMA_DRAIN_DEADLINE を渡すと、掴まれたままの接続を期限で打ち切る *)
  let drain_deadline =
    Option.map
      (fun s ->
        (float_of_string s, (env#clock :> float Eio.Time.clock_ty Eio.Resource.t)))
      (Sys.getenv_opt "NOMA_DRAIN_DEADLINE")
  in
  Noma_cohttp_eio.Server.run ~sw ~net:env#net ~port:0 ~stop ?drain_deadline
    ~on_error:(fun _ -> ())
    ~on_listen:(fun addr ->
      (match addr with
      | `Tcp (_, p) -> print_string (Printf.sprintf "PORT=%d\n" p)
      | _ -> print_string "PORT=?\n");
      flush stdout)
    app;
  (* run が戻った = 排出が済んだ *)
  print_string "DRAINED\n";
  flush stdout
