(* 12factor に沿った小さな JSON API。

   設定はすべて環境変数から読み、起動時に欠落を一度に報告して落ちる。
   ログは stdout に 1 行 1 JSON。SIGTERM で処理中を完走させてから終わる。

   $ PORT=8080 TODO_TOKEN=secret dune exec example/todo/main.exe
   $ curl -s localhost:8080/todos -H 'authorization: Bearer secret' | jq
   $ curl -s -XPOST localhost:8080/todos -H 'authorization: Bearer secret' \
       -H 'content-type: application/json' -d '{"title":"buy milk"}' | jq

   設定を忘れるとどうなるか:
   $ dune exec example/todo/main.exe        # 欠落が「全部まとめて」出る *)

(* ------------------------------------------------------------ 設定 (III) *)

type config = {
  port : int;
  token : string;
  max_body : int;
  request_timeout : float;
  log_level : Logs.level;
}

let config_reader =
  let open Noma.Config in
  let+ port = default 8080 (int "PORT")
  and+ token = secret (string "TODO_TOKEN")
  and+ max_body = default 65536 (int "MAX_BODY_BYTES")
  and+ request_timeout = default 30. (float "REQUEST_TIMEOUT_SECONDS")
  and+ log_level =
    default Logs.Info
      (enum
         [
           ("debug", Logs.Debug);
           ("info", Logs.Info);
           ("warning", Logs.Warning);
           ("error", Logs.Error);
         ]
         "LOG_LEVEL")
  in
  { port; token; max_body; request_timeout; log_level }

(* --------------------------------------------- ドメイン (VI: ステートレス) *)

(* 本物なら DB。noma は DB を知らないので、依存はただの引数として渡す。 *)
module Store = struct
  type todo = { id : int; title : string; done_ : bool }
  type t = { mutable items : todo list; mutable next : int; mutex : Mutex.t }

  let create () = { items = []; next = 1; mutex = Mutex.create () }

  let with_lock t f =
    Mutex.lock t.mutex;
    Fun.protect ~finally:(fun () -> Mutex.unlock t.mutex) f

  let list t = with_lock t (fun () -> List.rev t.items)

  let add t title =
    with_lock t (fun () ->
        let todo = { id = t.next; title; done_ = false } in
        t.items <- todo :: t.items;
        t.next <- t.next + 1;
        todo)

  let find t id = with_lock t (fun () -> List.find_opt (fun x -> x.id = id) t.items)

  let complete t id =
    with_lock t (fun () ->
        match List.find_opt (fun x -> x.id = id) t.items with
        | None -> None
        | Some todo ->
            let updated = { todo with done_ = true } in
            t.items <- List.map (fun x -> if x.id = id then updated else x) t.items;
            Some updated)

  let to_json { id; title; done_ } =
    `Assoc [ ("id", `Int id); ("title", `String title); ("done", `Bool done_) ]
end

(* ------------------------------------------------------------- 認証 *)

(* 深い所から直接 401 を返せる。これが abort の使いどころ。 *)
let authenticate ~token req =
  match Noma.Request.header req "authorization" with
  | Some v when v = "Bearer " ^ token -> ()
  | _ -> Noma.abort (Noma.Response.unauthorized ~challenge:{|Bearer realm="todo"|} ())

(* --------------------------------------------------------- ハンドラ *)

let todos () = Noma.Router.(s "todos" /? nil)
let todo () = Noma.Router.(s "todos" / int /? nil)
let todo_done () = Noma.Router.(s "todos" / int / s "done" /? nil)

let index store _req =
  Noma_yojson.response (`List (List.map Store.to_json (Store.list store)))

let show store id _req =
  match Store.find store id with
  | None -> Noma.abort (Noma.Response.not_found ())
  | Some t -> Noma_yojson.response (Store.to_json t)

let create store ~max_body req =
  let json = Noma_yojson.abort_on_error (Noma_yojson.of_request ~max_size:max_body req) in
  let title =
    match json with
    | `Assoc fields -> (
        match List.assoc_opt "title" fields with
        | Some (`String s) when String.trim s <> "" -> String.trim s
        | _ -> Noma.abort (Noma.Response.bad_request ~msg:{|"title" (非空文字列) が要ります|} ()))
    | _ -> Noma.abort (Noma.Response.bad_request ~msg:"JSON オブジェクトが要ります" ())
  in
  let created = Store.add store title in
  Noma_yojson.response ~status:`Created
    ~headers:
      (Http.Header.init_with "location" (Noma.Router.href (todo ()) created.Store.id))
    (Store.to_json created)

let complete store id _req =
  match Store.complete store id with
  | None -> Noma.abort (Noma.Response.not_found ())
  | Some t -> Noma_yojson.response (Store.to_json t)

let health _req = Noma.Response.json {|{"status":"ok"}|}

(* ------------------------------------------------------------- 組み立て *)

let router ~store ~token ~max_body =
  let auth inner req =
    authenticate ~token req;
    inner req
  in
  Noma.Router.make
    (Noma.Router.get Noma.Router.(s "healthz" /? nil) health
    :: Noma.Router.group auth
         [
           Noma.Router.get (todos ()) (index store);
           Noma.Router.get (todo ()) (show store);
           Noma.Router.post (todos ()) (create store ~max_body);
           Noma.Router.post (todo_done ()) (complete store);
         ])

let () =
  (* V: 設定は build 時ではなく run 時に読む。
     III: 欠落は全部まとめて報告して落ちる。 *)
  let cfg =
    match Noma.Config.load config_reader with
    | Ok c -> c
    | Error problems ->
        prerr_endline "設定に問題があります:";
        List.iter (fun p -> prerr_endline ("  " ^ p)) problems;
        prerr_endline "";
        prerr_endline "必要な環境変数:";
        List.iter
          (fun (k, v) -> Printf.eprintf "  %-24s %s\n" k v)
          (Noma.Config.describe config_reader);
        exit 1
  in
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  (* XI: ログは stdout へ。ファイルもローテーションも持たない。 *)
  Logs.set_reporter (Noma.Log.json_reporter ());
  Logs.set_level (Some cfg.log_level);

  let store = Store.create () in
  let mono = (env#mono_clock :> Mtime.t Eio.Time.clock_ty Eio.Resource.t) in
  let clock = (env#clock :> float Eio.Time.clock_ty Eio.Resource.t) in
  let app =
    Noma.compose
      [
        Noma.Middleware.recover ();
        Noma.Middleware.request_id ();
        Noma.Middleware.logger ~clock:mono ();
        Noma.Middleware.secure_headers ();
        Noma.Middleware.timeout ~clock ~seconds:cfg.request_timeout;
        Noma.Middleware.body_limit ~max_bytes:cfg.max_body;
      ]
      (Noma.Router.handler (router ~store ~token:cfg.token ~max_body:cfg.max_body))
  in
  (* IX: SIGTERM で処理中を完走させてから終わる。 *)
  let stop = Noma_cohttp_eio.Signal.stop_on ~sw [ Sys.sigterm; Sys.sigint ] in
  (* VII: 自分で port を握る。リバースプロキシを前提にしない。 *)
  Noma_cohttp_eio.Server.run ~sw ~net:env#net ~port:cfg.port ~stop
    ~drain_deadline:(10., clock)
    ~on_listen:(fun addr ->
      Noma.Log.event Logs.Info "todo.listening"
        [ ("addr", Noma.Log.S (Format.asprintf "%a" Eio.Net.Sockaddr.pp addr)) ];
      List.iter
        (fun (k, v) -> Noma.Log.event Logs.Info "todo.config" [ (k, Noma.Log.S v) ])
        (Noma.Config.describe config_reader))
    app
