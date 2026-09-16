type t = { status : Http.Status.t; headers : Http.Header.t; body : Body.t }

(* 不変条件を一箇所で守る。本体を持てないステータスでは本体を落とす。
   RFC 9110: 1xx / 204 / 304 は最初の空行で終端し、枠付けヘッダも持たない。 *)
let normalise r =
  if Http.Status.body_allowed r.status then r else { r with body = Body.empty }

let make ?(status = `OK) ?(headers = Http.Header.init ()) ?(body = Body.empty) () =
  normalise { status; headers; body }

let status t = t.status
let headers t = t.headers
let body t = t.body
let add_header k v t = { t with headers = Http.Header.add t.headers k v }
let set_header k v t = { t with headers = Http.Header.replace t.headers k v }
let remove_header k t = { t with headers = Http.Header.remove t.headers k }
let with_status status t = normalise { t with status }
let with_body body t = normalise { t with body }
let map_body f t = normalise { t with body = f t.body }
let with_content_type ct headers = Http.Header.add_unless_exists headers "content-type" ct

let of_string ~content_type ?(status = `OK) ?(headers = Http.Header.init ()) s =
  make ~status
    ~headers:(with_content_type content_type headers)
    ~body:(Body.of_string s) ()

let text = of_string ~content_type:"text/plain; charset=utf-8"
let html = of_string ~content_type:"text/html; charset=utf-8"
let json = of_string ~content_type:"application/json"

let stream ?(status = `OK) ?(headers = Http.Header.init ()) src =
  make ~status ~headers ~body:(Body.of_source src) ()

let empty ?(status = `OK) ?(headers = Http.Header.init ()) () = make ~status ~headers ()

let redirect ?(status = `See_other) loc =
  make
    ~status:(status :> Http.Status.t)
    ~headers:(Http.Header.init_with "location" loc)
    ()

let not_found () = text ~status:`Not_found "Not Found"

let bad_request ?msg () =
  text ~status:`Bad_request (match msg with Some m -> m | None -> "Bad Request")

let unauthorized ?challenge () =
  let headers =
    match challenge with
    | Some c -> Http.Header.init_with "www-authenticate" c
    | None -> Http.Header.init ()
  in
  text ~status:`Unauthorized ~headers "Unauthorized"

let forbidden () = text ~status:`Forbidden "Forbidden"

let method_not_allowed ~allow =
  if allow = [] then
    invalid_arg
      "Noma.Response.method_not_allowed: allow を空にできない (RFC 9110 は 405 に allow ヘッダを要求する)";
  let v = String.concat ", " (List.map Http.Method.to_string allow) in
  text ~status:`Method_not_allowed
    ~headers:(Http.Header.init_with "allow" v)
    "Method Not Allowed"

let payload_too_large () = text ~status:`Request_entity_too_large "Payload Too Large"
let internal_server_error () = text ~status:`Internal_server_error "Internal Server Error"
