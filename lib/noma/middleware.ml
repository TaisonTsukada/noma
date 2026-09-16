let no_clobber k v res =
  if Http.Header.mem (Response.headers res) k then res else Response.set_header k v res

(* ------------------------------------------------------------- recover *)

let default_on_error exn bt =
  Log.event Logs.Error "noma.handler.exception"
    [
      ("exn", Log.S (Printexc.to_string exn));
      ("backtrace", Log.S (Printexc.raw_backtrace_to_string bt));
    ]

let recover ?(on_error = default_on_error) () inner req =
  try inner req with
  (* M2: これを飲むと早期リターンと Eio のキャンセルが壊れる *)
  | (Abort.Aborted | Eio.Cancel.Cancelled _) as e -> raise e
  | e ->
      let bt = Printexc.get_raw_backtrace () in
      on_error e bt;
      (* バックトレースは on_error にしか渡さない。本体には絶対に載せない。 *)
      Response.internal_server_error ()

(* ------------------------------------------------------------- timeout *)

(* 事前条件はミドルウェアを組み立てた時点で検査する。リクエストごとに検査すると、
   recover が外側にある推奨の並びでは毎回 500 になるだけで起動時に気付けない。
   設定の誤りは起動時に落とす — Config と同じ考え方。 *)
let timeout ~clock ~seconds =
  if seconds <= 0. then invalid_arg "Noma.Middleware.timeout: seconds は正であること";
  fun inner req ->
    match Eio.Time.with_timeout clock seconds (fun () -> Ok (inner req)) with
    | Ok res -> res
    | Error `Timeout ->
        Log.event Logs.Warning "noma.request.timeout"
          [ ("path", Log.S (Request.path req)); ("seconds", Log.F seconds) ];
        Response.text ~status:`Service_unavailable "Service Unavailable"

(* ---------------------------------------------------------- body_limit *)

(* 読み出した量を数え、上限を超えた時点で打ち切る source。
   content-length の宣言値だけを信じないための実測側。 *)
module Limited = struct
  type t = { inner : Eio.Flow.source_ty Eio.Resource.t; max : int; mutable seen : int }

  let single_read t buf =
    let n = Eio.Flow.single_read t.inner buf in
    t.seen <- t.seen + n;
    if t.seen > t.max then raise (Body.Too_large t.max);
    n

  let read_methods = []
end

let limited_ops = Eio.Flow.Pi.source (module Limited)

let limit_source ~max src =
  Eio.Resource.T ({ Limited.inner = src; max; seen = 0 }, limited_ops)

let body_limit ~max_bytes =
  if max_bytes <= 0 then invalid_arg "Noma.Middleware.body_limit: max_bytes は正であること";
  fun inner req ->
    let too_large () =
      Log.event Logs.Info "noma.request.too_large"
        [ ("path", Log.S (Request.path req)); ("max_bytes", Log.I max_bytes) ];
      Response.payload_too_large ()
    in
    let declared = Option.bind (Request.header req "content-length") int_of_string_opt in
    match declared with
    | Some n when n > max_bytes -> too_large () (* 下流を呼ばない *)
    | _ -> (
        let body = Request.body req in
        let req =
          match Body.Private.view body with
          | Body.Private.Stream src ->
              (* 宣言値を信じず実測でも切る *)
              Request.with_body (Body.of_source (limit_source ~max:max_bytes src)) req
          | _ -> req
        in
        match Body.Private.view (Request.body req) with
        | Body.Private.String s when String.length s > max_bytes -> too_large ()
        | _ -> ( try inner req with Body.Too_large _ -> too_large ()))

(* ---------------------------------------------------------- request_id *)

let request_id_key : string Hmap.key = Hmap.Key.create ()
let id_counter = Atomic.make 0

let boot_token =
  Printf.sprintf "%x" (Hashtbl.hash (Unix.gettimeofday (), Unix.getpid ()) land 0xffffff)

let default_gen () =
  Printf.sprintf "%s-%x-%x" boot_token
    (Domain.self () :> int)
    (Atomic.fetch_and_add id_counter 1)

let request_id ?(header = "x-request-id") ?(gen = default_gen) () inner req =
  let id = match Request.header req header with Some id -> id | None -> gen () in
  let req = Request.add request_id_key id req in
  Response.set_header header id (inner req)

(* -------------------------------------------------------------- logger *)

let elapsed_ms clock t0 =
  Mtime.Span.to_float_ns (Mtime.span (Eio.Time.Mono.now clock) t0) /. 1e6

let client_str req =
  match Request.client req with
  | Some addr -> Format.asprintf "%a" Eio.Net.Sockaddr.pp addr
  | None -> "-"

let logger ~clock () inner req =
  let t0 = Eio.Time.Mono.now clock in
  let base () =
    [
      ("method", Log.S (Http.Method.to_string (Request.meth req)));
      ("path", Log.S (Request.path req));
      ("dur_ms", Log.F (elapsed_ms clock t0));
      ( "req_id",
        match Request.find request_id_key req with
        | Some id -> Log.S id
        | None -> Log.Null );
      ("client", Log.S (client_str req));
    ]
  in
  let emit level fields = Log.event level "noma.http" (base () @ fields) in
  match inner req with
  | res ->
      (* M5: 本体を読まない。長さが既知のときだけ記録する。 *)
      emit Logs.Info
        [
          ("status", Log.I (Http.Status.to_int (Response.status res)));
          ( "bytes",
            match Body.length (Response.body res) with
            | Some n -> Log.I n
            | None -> Log.Null );
        ];
      res
  | exception e ->
      emit Logs.Warning [ ("status", Log.Null); ("exn", Log.S (Printexc.to_string e)) ];
      raise e

(* ---------------------------------------------------------------- cors *)

type origins = [ `Any | `List of string list ]

let default_cors_methods = [ `GET; `POST; `PUT; `PATCH; `DELETE; `OPTIONS ]
let default_cors_headers = [ "content-type"; "authorization" ]

let cors ~origins ?(methods = default_cors_methods) ?(headers = default_cors_headers)
    ?(expose = []) ?(credentials = false) ?max_age () =
  if credentials && origins = `Any then
    invalid_arg
      "Noma.Middleware.cors: credentials:true と origins:`Any は併用できない (Fetch \
       仕様が禁じており、ブラウザは黙って要求を落とす)";
  let allow_origin origin =
    match origins with
    | `Any -> Some "*"
    | `List os -> if List.mem origin os then Some origin else None
  in
  let common origin res =
    let res = Response.set_header "access-control-allow-origin" origin res in
    let res =
      match origins with
      | `List _ -> Response.add_header "vary" "origin" res
      | `Any -> res
    in
    let res =
      if credentials then
        Response.set_header "access-control-allow-credentials" "true" res
      else res
    in
    if expose = [] then res
    else
      Response.set_header "access-control-expose-headers" (String.concat ", " expose) res
  in
  fun inner req ->
    match Option.bind (Request.header req "origin") allow_origin with
    | None -> inner req (* CORS の対象外。何も足さずに素通し。 *)
    | Some allowed ->
        let is_preflight =
          Request.meth req = `OPTIONS
          && Request.header req "access-control-request-method" <> None
        in
        if is_preflight then
          let res = Response.empty ~status:`No_content () |> common allowed in
          let res =
            Response.set_header "access-control-allow-methods"
              (String.concat ", " (List.map Http.Method.to_string methods))
              res
          in
          let res =
            Response.set_header "access-control-allow-headers"
              (String.concat ", " headers) res
          in
          match max_age with
          | Some n -> Response.set_header "access-control-max-age" (string_of_int n) res
          | None -> res
        else common allowed (inner req)

(* ------------------------------------------------------ secure_headers *)

let secure_headers ?(hsts = `Off) ?(frame = `Deny) ?(referrer = "no-referrer") () =
  (match hsts with
  | `Max_age n when n <= 0 ->
      invalid_arg "Noma.Middleware.secure_headers: hsts の max-age は正であること"
  | _ -> ());
  let frame_value =
    match frame with
    | `Deny -> Some "DENY"
    | `Same_origin -> Some "SAMEORIGIN"
    | `Off -> None
  in
  fun inner req ->
    let res = inner req in
    let res = no_clobber "x-content-type-options" "nosniff" res in
    let res = no_clobber "referrer-policy" referrer res in
    let res =
      match frame_value with Some v -> no_clobber "x-frame-options" v res | None -> res
    in
    match hsts with
    | `Off -> res
    | `Max_age n ->
        no_clobber "strict-transport-security"
          (Printf.sprintf "max-age=%d; includeSubDomains" n)
          res
