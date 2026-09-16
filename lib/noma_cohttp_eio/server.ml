type drain_deadline = float * float Eio.Time.clock_ty Eio.Resource.t

(* 未読の本体が多すぎて読み捨てられないとき、応答を送り終えてから接続を畳むための
   合図。cohttp-eio の keep-alive 判定はリクエスト側しか見ないので、応答に
   Connection: close を付けるだけでは次のリクエストを読みに行ってしまう。
   例外で抜けるのが唯一正しい。 *)
exception Close_connection

let default_max_header_size = 64 * 1024
let default_max_drain_bytes = 64 * 1024

(* ---------------------------------------------------------------- A4/A6 *)

let empty_source = Eio.Flow.string_source ""

let with_connection creq headers =
  match Cohttp.Header.connection headers with
  | Some _ -> headers
  | None ->
      Http.Header.add headers "connection"
        (if Http.Request.is_keep_alive creq then "keep-alive" else "close")

(* 応答の本体と枠付けを決める。

   本体を持てない status (1xx / 204 / 304) では `Expert を使う。cohttp-eio の
   respond は「長さ不明なら chunked」と機械的に決めてしまい 204 にも
   transfer-encoding を付けてしまうが、`Expert が通る write_header は
   allowed_body を見て枠付けを省くので、こちらが RFC 9110 に正しい。 *)
let response_action ~creq ~res ~finish =
  let status = Noma.Response.status res in
  let meth = Http.Request.meth creq in
  if not (Http.Status.body_allowed status) then
    let headers = with_connection creq (Noma.Response.headers res) in
    `Expert (Http.Response.make ~status ~headers (), fun _ic _oc -> finish ())
  else
    let headers =
      (* 呼び手が枠付けを決めているならそれを尊重する。Router の HEAD 処理は
         GET の長さを content-length に残すので、ここで上書きしてはならない。 *)
      match Cohttp.Header.get_transfer_encoding (Noma.Response.headers res) with
      | Cohttp.Transfer.Unknown -> (
          let headers = Noma.Response.headers res in
          match Noma.Body.length (Noma.Response.body res) with
          | Some n -> Cohttp.Header.add_transfer_encoding headers (Fixed (Int64.of_int n))
          | None -> Cohttp.Header.add_transfer_encoding headers Chunked)
      | _ -> Noma.Response.headers res
    in
    (* A4: HEAD には本体を書かない。cohttp-eio の write はメソッドを見ないので
       抑止できるのはここだけ。 *)
    let source =
      if meth = `HEAD then empty_source
      else
        match Noma.Body.Private.view (Noma.Response.body res) with
        | Noma.Body.Private.Empty -> empty_source
        | Noma.Body.Private.String s -> Eio.Flow.string_source s
        | Noma.Body.Private.Stream src -> (src :> Eio.Flow.source_ty Eio.Resource.t)
    in
    let write = Cohttp_eio.Server.respond ~headers ~status ~body:source () in
    `Response
      (fun writer ->
        write writer;
        finish ())

(* ------------------------------------------------------------- on_error *)

let is_client_noise = function
  | Eio.Buf_read.Buffer_limit_exceeded | End_of_file -> true
  | Eio.Io (Eio.Net.E (Connection_reset _), _) -> true
  | Eio.Io (Eio.Net.E (Connection_failure _), _) -> true
  | _ -> false

let default_on_error exn =
  if is_client_noise exn then
    Noma.Log.event Logs.Info "noma.connection.aborted"
      [ ("exn", Noma.Log.S (Printexc.to_string exn)) ]
  else
    Noma.Log.event Logs.Error "noma.connection.error"
      [
        ("exn", Noma.Log.S (Printexc.to_string exn));
        ("hint", Noma.Log.S "recover ミドルウェアを入れていればハンドラの例外はここに来ない — ミドルウェアの配線を確認すること");
      ]

(* 頭部の上限を超えたときの応答。この時点でリクエストは解析できておらず接続も
   畳むので、cohttp の書き出し器を通さず固定のバイト列を直接書く。 *)
let write_431 oc =
  let body = "Request Header Fields Too Large" in
  Eio.Buf_write.string oc
    (Printf.sprintf
       "HTTP/1.1 431 Request Header Fields Too Large\r\n\
        content-type: text/plain; charset=utf-8\r\n\
        content-length: %d\r\n\
        connection: close\r\n\
        \r\n\
        %s"
       (String.length body) body);
  Eio.Buf_write.flush oc

(* ------------------------------------------------------------------ run *)

let run ~sw ~net ?addr ?(port = 8080) ?(backlog = 128) ?max_connections
    ?(max_header_size = default_max_header_size)
    ?(max_drain_bytes = default_max_drain_bytes) ?additional_domains ?stop ?drain_deadline
    ?(on_error = default_on_error) ?on_listen handler =
  if max_header_size <= 0 then
    invalid_arg "Noma_cohttp_eio.Server.run: max_header_size は正であること";
  if max_drain_bytes <= 0 then
    invalid_arg "Noma_cohttp_eio.Server.run: max_drain_bytes は正であること";
  let addr = match addr with Some a -> a | None -> `Tcp (Eio.Net.Ipaddr.V4.any, port) in
  let socket = Eio.Net.listen ~reuse_addr:true ~backlog ~sw net addr in
  Option.iter (fun f -> f (Eio.Net.listening_addr socket)) on_listen;

  (* リクエストごとのコールバック。A1/A2/A3/A5 はここで果たす。 *)
  let callback ((_conn_sw, peer), _id) creq cbody =
    let tracked, body_src = Tracked_source.create cbody in
    (* A2: リクエストごとの Switch。run_handler より外側に置く —
       abort は discontinue で巻き戻るので、この順序で解放が正しく走る。 *)
    let res =
      Eio.Switch.run @@ fun req_sw ->
      let req =
        Noma.Request.of_http ~sw:req_sw ~client:peer
          ~body:(Noma.Body.of_source body_src)
          creq
      in
      (* A1: abort の受け皿はここ 1 箇所だけ *)
      Noma.run_handler handler req
    in
    (* A3: 応答を書き終えてから未読の本体を始末する *)
    let finish () =
      if not (Tracked_source.drain ~limit:max_drain_bytes tracked) then
        raise Close_connection
    in
    response_action ~creq ~res ~finish
  in
  let server = Cohttp_eio.Server.make_response_action ~callback () in

  let conn_handler flow peer =
    Eio.Switch.run @@ fun conn_sw ->
    (* cohttp-eio の run と違い、頭部のバッファに上限を入れる *)
    let ic = Eio.Buf_read.of_flow ~max_size:max_header_size flow in
    Eio.Buf_write.with_flow flow @@ fun oc ->
    try Cohttp_eio.Server.callback server (conn_sw, peer) ic oc with
    | Eio.Buf_read.Buffer_limit_exceeded -> write_431 oc
    | Close_connection -> ()
  in

  let serve () =
    Eio.Net.run_server ?max_connections ?additional_domains ?stop ~on_error socket
      conn_handler
  in
  match (stop, drain_deadline) with
  | Some stop, Some (secs, clock) ->
      Eio.Fiber.first serve (fun () ->
          Eio.Promise.await stop;
          Eio.Time.sleep clock secs;
          Noma.Log.event Logs.Warning "noma.shutdown.deadline"
            [ ("seconds", Noma.Log.F secs) ])
  | _ -> serve ()
