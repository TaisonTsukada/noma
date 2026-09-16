(* シグナルハンドラの中で確保しないよう、あらかじめ用意しておく。 *)
let byte = Bytes.make 1 'x'

let stop_on ~sw signals =
  if signals = [] then invalid_arg "Noma_cohttp_eio.Signal.stop_on: signals を空にできない";
  let r, w = Unix.socketpair PF_UNIX SOCK_STREAM 0 in
  Unix.set_nonblock w;
  Eio.Switch.on_release sw (fun () -> try Unix.close w with _ -> ());
  let src = Eio_unix.Net.import_socket_stream ~sw ~close_unix:true r in
  List.iter
    (fun s ->
      Sys.set_signal s
        (Sys.Signal_handle
           (fun _ ->
             (* ここで呼んでよいのは raw な write だけ。Eio に触れない。 *)
             try ignore (Unix.write w byte 0 1) with _ -> ())))
    signals;
  let p, u = Eio.Promise.create () in
  Eio.Fiber.fork ~sw (fun () ->
      let buf = Cstruct.create 1 in
      (try ignore (Eio.Flow.single_read src buf) with End_of_file -> ());
      Noma.Log.event Logs.Info "noma.shutdown.signal" [];
      ignore (Eio.Promise.try_resolve u ()));
  p
