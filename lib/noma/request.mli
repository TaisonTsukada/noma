(** 受け取った HTTP リクエスト。

    抽象型である。[path] と [query] が [target] と必ず整合するという不変条件を
    型で保つため、レコードを公開しない。

    テストのために socket 無しで組み立てられることが要件で、{!make} がその入口。
    ハンドラは [Request.t -> Response.t] のただの関数なので、単体テストは
    サーバーを起動せずに済む。 *)

type t

val make :
  ?version:Http.Version.t ->
  ?headers:Http.Header.t ->
  ?body:Body.t ->
  ?ctx:Hmap.t ->
  ?client:Eio.Net.Sockaddr.stream ->
  ?sw:Eio.Switch.t ->
  meth:Http.Method.t ->
  string ->
  t
(** [make ~meth target] はリクエストを組み立てる。[target] は
    ["/users/42?tab=all"] のような生の request-target。

    要求: なし。壊れた [target] でも全域的に受け付ける (400 を返すのは上位の判断)。
    保証: {!path} のセグメント数は [target] のパス部のセグメント数と必ず等しい
          (下記の不変条件)。
    不変: [~sw] を省略した [t] に対して {!sw} は [Invalid_argument] を送出する。
          テストで {!sw} が要るときは [Eio.Switch.run] で包んで渡すこと。 *)

val meth : t -> Http.Method.t
(** リクエストメソッド。 *)

val target : t -> string
(** 生の request-target。パーセント復号もクエリ除去もしていない。 *)

val path : t -> string
(** 経路部。セグメントごとにパーセント復号してある。

    不変: {!path} のセグメント数は {!target} のパス部のセグメント数と常に等しい。
          復号すると ["/"] を含んでしまうセグメント (["%2F"] など) は復号せず
          生のまま残すので、パーセント符号化でセグメントを増やすことはできない。
          経路照合と認可判断が同じ区切りを見ることを保証する — ここがずれると
          認可の迂回になる。 *)

val query : t -> (string * string list) list
(** 復号済みのクエリ。

    保証: 同じ鍵が複数回現れた場合、1 つの組にまとめて値を出現順に並べる
          (["?a=1&a=2"] は [("a", ["1"; "2"])] の 1 組)。鍵の出現順も保つ。 *)

val query_opt : t -> string -> string option
(** [query_opt t k] は鍵 [k] の最初の値。

    保証: 同名の鍵が複数あるときは最初のものを返す。無ければ [None]。 *)

val headers : t -> Http.Header.t
(** 全ヘッダ。 *)

val header : t -> string -> string option
(** [header t name] はヘッダ [name] の値。

    保証: [name] の大小文字は区別しない。同名ヘッダが複数ある場合は最初の値。 *)

val body : t -> Body.t
(** リクエスト本体。 *)

val version : t -> Http.Version.t
(** HTTP バージョン。 *)

val client : t -> Eio.Net.Sockaddr.stream option
(** 接続相手の実アドレス。

    不変: これは TCP の相手そのものであって、[X-Forwarded-For] を解決した結果では
          ない。noma は既定で転送ヘッダを信用しない — 信用の境界を明示せずに
          信用すると、そのまま IP 詐称になるからである。 *)

val sw : t -> Eio.Switch.t
(** このリクエストに紐づく [Eio.Switch.t]。ファイルや接続を開くのに使う。

    要求: [t] が [~sw] 付きで作られていること。無ければ [Invalid_argument]。
    保証: アダプタはリクエストごとに新しい switch を張り、ハンドラから戻った時点で
          閉じる (契約 A2)。接続ごとではないので、keep-alive で多数のリクエストを
          処理しても資源が積み上がらない。 *)

val sw_opt : t -> Eio.Switch.t option
(** 事前条件を持たない {!sw}。 *)

val ctx : t -> Hmap.t
(** リクエストに付随する異種の文脈 (Ring の request map 相当)。 *)

val find : 'a Hmap.key -> t -> 'a option
(** 文脈から鍵を引く。 *)

val get : 'a Hmap.key -> t -> 'a
(** [get k t] は文脈の [k]。

    要求: [k] が束縛されていること。無ければ [Invalid_argument]。
          事前条件を持たない兄弟は {!find}。 *)

val add : 'a Hmap.key -> 'a -> t -> t
(** 文脈に束縛を足した新しいリクエスト。 *)

val with_body : Body.t -> t -> t
(** 本体を差し替えた新しいリクエスト。 *)

val with_headers : Http.Header.t -> t -> t
(** ヘッダを差し替えた新しいリクエスト。 *)

val with_target : string -> t -> t
(** request-target を差し替えた新しいリクエスト。

    保証: {!path} と {!query} は新しい [target] に合わせて作り直される
          (不変条件を壊さない)。[Router.mount] が接頭辞を剥がすのに使う。 *)

val of_http :
  ?body:Body.t ->
  ?ctx:Hmap.t ->
  ?client:Eio.Net.Sockaddr.stream ->
  ?sw:Eio.Switch.t ->
  Http.Request.t ->
  t
(** [http] パッケージの表現から組み立てる。アダプタ用。

    保証: [meth] [target] [version] [headers] を写し取る。 *)
