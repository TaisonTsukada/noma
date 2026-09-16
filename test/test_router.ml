open Noma

let status =
  Alcotest.testable
    (fun ppf s -> Format.pp_print_int ppf (Http.Status.to_int s))
    (fun a b -> Http.Status.to_int a = Http.Status.to_int b)

let req ?(meth = `GET) target = Request.make ~meth target
let body r = Body.to_string ~max_size:10_000 (Response.body r)
let hdr r k = Http.Header.get (Response.headers r) k

(* 値制限を避けるためイータ展開する (README に書いた癖) *)
let users () = Router.(s "users" /? nil)
let user () = Router.(s "users" / int /? nil)
let root () = Router.nil

let sample () =
  Router.make
    [
      Router.get (root ()) (fun _ -> Response.text "root");
      Router.get (users ()) (fun _ -> Response.text "index");
      Router.get (user ()) (fun id _ -> Response.text ("user " ^ string_of_int id));
      Router.post (users ()) (fun _ -> Response.text ~status:`Created "created");
      Router.delete (user ()) (fun id _ -> Response.text ("deleted " ^ string_of_int id));
    ]

let basic =
  [
    ( "パスパラメータが型付きで届く",
      `Quick,
      fun () ->
        let h = Router.handler (sample ()) in
        Alcotest.(check string) "index" "index" (body (h (req "/users")));
        Alcotest.(check string) "show" "user 42" (body (h (req "/users/42")));
        Alcotest.(check string) "root" "root" (body (h (req "/"))) );
    ( "メソッドで分岐する (同じパスでも別ハンドラ)",
      `Quick,
      fun () ->
        let h = Router.handler (sample ()) in
        Alcotest.check status "GET /users" `OK (Response.status (h (req "/users")));
        Alcotest.check status "POST /users" `Created
          (Response.status (h (req ~meth:`POST "/users")));
        Alcotest.(check string)
          "DELETE" "deleted 7"
          (body (h (req ~meth:`DELETE "/users/7"))) );
    ( "一致しなければ 404",
      `Quick,
      fun () ->
        let h = Router.handler (sample ()) in
        Alcotest.check status "404" `Not_found (Response.status (h (req "/nope")));
        (* int に一致しないセグメントも 404 *)
        Alcotest.check status "bad int" `Not_found
          (Response.status (h (req "/users/abc"))) );
    ( "not_found は差し替えられる",
      `Quick,
      fun () ->
        let r =
          Router.make
            ~not_found:(fun _ -> Response.json ~status:`Not_found {|{"e":1}|})
            []
        in
        let res = Router.handler r (req "/x") in
        Alcotest.check status "404" `Not_found (Response.status res);
        Alcotest.(check string) "custom body" {|{"e":1}|} (body res) );
    ( "href で逆引きできる",
      `Quick,
      fun () ->
        Alcotest.(check string) "user" "/users/42" (Router.href (user ()) 42);
        Alcotest.(check string) "index" "/users" (Router.href (users ())) );
    ( "to_list は宣言順を保つ",
      `Quick,
      fun () ->
        Alcotest.(check (list string))
          "routes"
          [
            "GET /"; "GET /users"; "GET /users/:int"; "POST /users"; "DELETE /users/:int";
          ]
          (Router.to_list (sample ())) );
  ]

let method_semantics =
  [
    ( "405 は allow を正しく並べる",
      `Quick,
      fun () ->
        let h = Router.handler (sample ()) in
        let res = h (req ~meth:`PUT "/users/42") in
        Alcotest.check status "405" `Method_not_allowed (Response.status res);
        (* GET と DELETE が在る → HEAD と OPTIONS も暗黙に許される *)
        Alcotest.(check (option string))
          "allow" (Some "GET, DELETE, HEAD, OPTIONS") (hdr res "allow") );
    ( "HEAD は GET を引き、本体を落として content-length を残す",
      `Quick,
      fun () ->
        let h = Router.handler (sample ()) in
        let res = h (req ~meth:`HEAD "/users/42") in
        Alcotest.check status "200" `OK (Response.status res);
        Alcotest.(check string) "no body" "" (body res);
        Alcotest.(check (option string))
          "content-length" (Some "7") (hdr res "content-length") );
    ( "HEAD の専用経路があればそちらが勝つ",
      `Quick,
      fun () ->
        let r =
          Router.make
            [
              Router.get (users ()) (fun _ -> Response.text "get");
              Router.head (users ()) (fun _ -> Response.text ~status:`Accepted "head");
            ]
        in
        Alcotest.check status "202" `Accepted
          (Response.status (Router.handler r (req ~meth:`HEAD "/users"))) );
    ( "OPTIONS は 204 + allow を自動で返す",
      `Quick,
      fun () ->
        let h = Router.handler (sample ()) in
        let res = h (req ~meth:`OPTIONS "/users") in
        Alcotest.check status "204" `No_content (Response.status res);
        Alcotest.(check (option string))
          "allow" (Some "GET, POST, HEAD, OPTIONS") (hdr res "allow");
        Alcotest.(check string) "no body" "" (body res) );
    ( "OPTIONS の専用経路があればそちらが勝つ",
      `Quick,
      fun () ->
        let r =
          Router.make
            [
              Router.get (users ()) (fun _ -> Response.text "g");
              Router.options (users ()) (fun _ -> Response.text "custom options");
            ]
        in
        Alcotest.(check string)
          "custom" "custom options"
          (body (Router.handler r (req ~meth:`OPTIONS "/users"))) );
    ( "存在しないパスへの OPTIONS は 404",
      `Quick,
      fun () ->
        Alcotest.check status "404" `Not_found
          (Response.status (Router.handler (sample ()) (req ~meth:`OPTIONS "/nope"))) );
  ]

let trailing =
  [
    ( "既定は 308 で正規形へ転送する",
      `Quick,
      fun () ->
        let res = Router.handler (sample ()) (req "/users/42/") in
        Alcotest.check status "308" `Permanent_redirect (Response.status res);
        Alcotest.(check (option string))
          "location" (Some "/users/42") (hdr res "location") );
    ( "転送先はクエリを保つ",
      `Quick,
      fun () ->
        let res = Router.handler (sample ()) (req "/users/42/?tab=all") in
        Alcotest.(check (option string))
          "location" (Some "/users/42?tab=all") (hdr res "location") );
    ( "`Match は末尾スラッシュを同一視する",
      `Quick,
      fun () ->
        let r =
          Router.make ~trailing_slash:`Match
            [ Router.get (user ()) (fun i _ -> Response.text (string_of_int i)) ]
        in
        Alcotest.(check string)
          "matched" "42"
          (body (Router.handler r (req "/users/42/"))) );
    ( "`Strict は不一致にする",
      `Quick,
      fun () ->
        let r =
          Router.make ~trailing_slash:`Strict
            [ Router.get (user ()) (fun i _ -> Response.text (string_of_int i)) ]
        in
        Alcotest.check status "404" `Not_found
          (Response.status (Router.handler r (req "/users/42/"))) );
  ]

let mount_tests =
  let sub =
    Router.handler
      (Router.make
         [
           Router.get (users ()) (fun r -> Response.text ("sub sees " ^ Request.path r));
           Router.get (root ()) (fun r -> Response.text ("sub root " ^ Request.path r));
         ])
  in
  [
    ( "mount はサブアプリから接頭辞を隠す",
      `Quick,
      fun () ->
        let h = Router.handler (Router.make [ Router.mount "admin" sub ]) in
        Alcotest.(check string)
          "stripped" "sub sees /users"
          (body (h (req "/admin/users")));
        Alcotest.(check string) "root" "sub root /" (body (h (req "/admin"))) );
    ( "mount はクエリを保ち、接頭辞を文脈に残す",
      `Quick,
      fun () ->
        let seen = ref "" in
        let sub r =
          seen := Option.value ~default:"?" (Request.find Router.mount_prefix_key r);
          Response.text (Option.value ~default:"-" (Request.query_opt r "q"))
        in
        let h = Router.handler (Router.make [ Router.mount "admin" sub ]) in
        Alcotest.(check string) "query kept" "1" (body (h (req "/admin/users?q=1")));
        Alcotest.(check string) "prefix in ctx" "/admin" !seen );
    ( "入れ子の mount は接頭辞を連結する",
      `Quick,
      fun () ->
        let inner r =
          Response.text
            (Option.value ~default:"?" (Request.find Router.mount_prefix_key r)
            ^ " | " ^ Request.path r)
        in
        let mid = Router.handler (Router.make [ Router.mount "v1" inner ]) in
        let h = Router.handler (Router.make [ Router.mount "api" mid ]) in
        Alcotest.(check string)
          "nested" "/api/v1 | /things"
          (body (h (req "/api/v1/things"))) );
    ( "mount はメソッドを問わず通す",
      `Quick,
      fun () ->
        let sub r = Response.text (Http.Method.to_string (Request.meth r)) in
        let h = Router.handler (Router.make [ Router.mount "a" sub ]) in
        Alcotest.(check string) "POST" "POST" (body (h (req ~meth:`POST "/a/x"))) );
    ( "mount 越しの HEAD でも content-length が潰れない",
      `Quick,
      fun () ->
        (* サブアプリ側でも HEAD 処理が走るので、外側が 0 で上書きしないこと *)
        let inner =
          Router.handler
            (Router.make [ Router.get (users ()) (fun _ -> Response.text "abcde") ])
        in
        let h = Router.handler (Router.make [ Router.mount "a" inner ]) in
        let get_len =
          Option.get (hdr (h (req ~meth:`HEAD "/a/users")) "content-length")
        in
        Alcotest.(check string) "GET の長さが残る" "5" get_len;
        Alcotest.(check string) "本体は空" "" (body (h (req ~meth:`HEAD "/a/users"))) );
    ( "mount の prefix は 1 セグメント",
      `Quick,
      fun () ->
        Alcotest.(check bool)
          "rejected" true
          (try
             ignore (Router.mount "a/b" sub);
             false
           with Invalid_argument _ -> true) );
  ]

let group_tests =
  let tag name inner req = Response.add_header "x-mw" name (inner req) in
  [
    ( "group は一致した経路だけを包む",
      `Quick,
      fun () ->
        let r =
          Router.make
            (Router.group (tag "auth")
               [ Router.get (users ()) (fun _ -> Response.text "guarded") ]
            @ [ Router.get (root ()) (fun _ -> Response.text "open") ])
        in
        let h = Router.handler r in
        Alcotest.(check (option string))
          "guarded" (Some "auth")
          (hdr (h (req "/users")) "x-mw");
        Alcotest.(check (option string)) "open" None (hdr (h (req "/")) "x-mw") );
    ( "group は 404 経路では走らない",
      `Quick,
      fun () ->
        let ran = ref false in
        let spy inner req =
          ran := true;
          inner req
        in
        let r =
          Router.make
            (Router.group spy [ Router.get (users ()) (fun _ -> Response.text "x") ])
        in
        ignore (Router.handler r (req "/nope"));
        Alcotest.(check bool) "not run" false !ran );
  ]

let resolve_tests =
  [
    ( "resolve は純粋な決定を返す (応答を作らない)",
      `Quick,
      fun () ->
        let t = sample () in
        (match Router.resolve t (req "/users/42") with
        | Router.Found _ -> ()
        | _ -> Alcotest.fail "expected Found");
        (match Router.resolve t (req ~meth:`PUT "/users/42") with
        | Router.Wrong_method ms ->
            Alcotest.(check (list string))
              "allow"
              [ "GET"; "DELETE"; "HEAD"; "OPTIONS" ]
              (List.map Http.Method.to_string ms)
        | _ -> Alcotest.fail "expected Wrong_method");
        (match Router.resolve t (req "/nope") with
        | Router.Missing -> ()
        | _ -> Alcotest.fail "expected Missing");
        match Router.resolve t (req "/users/42/") with
        | Router.Redirect loc -> Alcotest.(check string) "loc" "/users/42" loc
        | _ -> Alcotest.fail "expected Redirect" );
  ]

let () =
  Alcotest.run "noma.router"
    [
      ("基本", basic);
      ("メソッド意味論", method_semantics);
      ("末尾スラッシュ", trailing);
      ("mount", mount_tests);
      ("group", group_tests);
      ("resolve", resolve_tests);
    ]
