(* 生の socket で HTTP を喋る検査用クライアント。
   keep-alive の同期ずれや頭部の上限は、クライアントライブラリを挟むと
   見えなくなるので自前で組む。 *)

type response = { status : int; headers : (string * string) list; body : string }

let header r k = List.assoc_opt (String.lowercase_ascii k) r.headers

let read_chunked br =
  let buf = Buffer.create 256 in
  let rec go () =
    let n = int_of_string ("0x" ^ String.trim (Eio.Buf_read.line br)) in
    if n = 0 then (
      ignore (Eio.Buf_read.line br);
      Buffer.contents buf)
    else (
      Buffer.add_string buf (Eio.Buf_read.take n br);
      ignore (Eio.Buf_read.line br);
      go ())
  in
  go ()

let read_response br =
  let status_line = Eio.Buf_read.line br in
  let status = Scanf.sscanf status_line "HTTP/%_s@ %d" (fun c -> c) in
  let rec headers acc =
    match Eio.Buf_read.line br with
    | "" -> List.rev acc
    | l -> (
        match String.index_opt l ':' with
        | Some i ->
            let k = String.lowercase_ascii (String.trim (String.sub l 0 i)) in
            let v = String.trim (String.sub l (i + 1) (String.length l - i - 1)) in
            headers ((k, v) :: acc)
        | None -> headers acc)
  in
  let headers = headers [] in
  let body =
    match List.assoc_opt "content-length" headers with
    | Some n -> Eio.Buf_read.take (int_of_string n) br
    | None -> (
        match List.assoc_opt "transfer-encoding" headers with
        | Some te when String.lowercase_ascii te = "chunked" -> read_chunked br
        | _ -> "")
  in
  { status; headers; body }

(* サーバーを立ち上げて [f] に接続用の関数を渡す。port 0 で起動し、
   on_listen で実際の port を受け取る。 *)
let with_server ?max_header_size ?max_drain_bytes handler f =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let addr_p, addr_r = Eio.Promise.create () in
  let stop, set_stop = Eio.Promise.create () in
  Eio.Fiber.fork ~sw (fun () ->
      Noma_cohttp_eio.Server.run ~sw ~net:env#net ~port:0 ?max_header_size
        ?max_drain_bytes ~stop
        ~on_error:(fun _ -> ())
        ~on_listen:(fun a -> Eio.Promise.resolve addr_r a)
        handler);
  let port =
    match Eio.Promise.await addr_p with `Tcp (_, p) -> p | _ -> failwith "no tcp"
  in
  let connect () =
    Eio.Net.connect ~sw env#net (`Tcp (Eio.Net.Ipaddr.V4.loopback, port))
  in
  let result = f connect in
  Eio.Promise.resolve set_stop ();
  result

(* 1 接続で 1 往復 *)
let round_trip connect raw =
  let flow = connect () in
  Eio.Flow.copy_string raw flow;
  let br = Eio.Buf_read.of_flow ~max_size:1_000_000 flow in
  let res = read_response br in
  Eio.Flow.close flow;
  res

let get ?(headers = "") path =
  Printf.sprintf "GET %s HTTP/1.1\r\nhost: localhost\r\n%s\r\n" path headers

let post ?(headers = "") path body =
  Printf.sprintf "%s %s HTTP/1.1\r\nhost: localhost\r\ncontent-length: %d\r\n%s\r\n%s"
    "POST" path (String.length body) headers body
