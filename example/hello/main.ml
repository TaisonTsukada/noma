(* 最小の noma アプリ。

   $ dune exec example/hello/main.exe
   $ curl -i localhost:8080/
   $ curl -i localhost:8080/hello/world *)

let router () =
  Noma.Router.(
    make
      [
        get nil (fun _ -> Noma.Response.text "noma");
        get
          (s "hello" / str /? nil)
          (fun who _ -> Noma.Response.text (Printf.sprintf "hello, %s" who));
      ])

let () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  Logs.set_reporter (Noma.Log.json_reporter ());
  Logs.set_level (Some Logs.Info);
  let app =
    Noma.compose
      [
        Noma.Middleware.recover ();
        Noma.Middleware.request_id ();
        Noma.Middleware.logger
          ~clock:(env#mono_clock :> Mtime.t Eio.Time.clock_ty Eio.Resource.t)
          ();
      ]
      (Noma.Router.handler (router ()))
  in
  Noma_cohttp_eio.Server.run ~sw ~net:env#net ~port:8080
    ~stop:(Noma_cohttp_eio.Signal.stop_on ~sw [ Sys.sigterm; Sys.sigint ])
    ~on_listen:(fun addr ->
      Noma.Log.event Logs.Info "noma.listening"
        [ ("addr", Noma.Log.S (Format.asprintf "%a" Eio.Net.Sockaddr.pp addr)) ])
    app
