(** 型付きのルーティング。

    経路は文字列パターンではなく型付きコンビネータで書く。パスパラメータは型の
    ついた値としてハンドラに届き、実行時のパースも [param] の取り出しも要らない。
    おまけに逆引き ({!href}) が無料で付いてくる。

    {[
      let users () = Router.(s "users" /? nil)
      let user  () = Router.(s "users" / int /? nil)

      let router =
        Router.make
          [ Router.get  (users ()) Users.index
          ; Router.get  (user  ()) Users.show      (* Users.show : int -> handler *)
          ; Router.post (users ()) Users.create
          ]

      let app = Router.handler router
    ]}

    {2 「決定」と「方針」を分ける}

    {!val-resolve} は「何が一致したか」を純粋なデータとして返し、{!val-handler} が
    「それにどう応答するか」という HTTP の方針を与える。切り離してあるので、
    405 の [allow] や HEAD の扱いといった RFC 準拠の部分を単体で検査でき、
    方針だけ差し替えることもできる。

    {2 値制限について}

    [routes] のパス値は値制限のため弱多相になる。ルータ定義と {!href} の両方で
    同じパスを使うなら [let user () = s "users" / int /? nil] のように
    イータ展開して関数にすること。上の例がそうしているのはこのため。 *)

type ('a, 'b) path = ('a, 'b) Routes.path
(** パスのパターン。[('a, 'b)] の ['a] は一致したときに呼ばれる関数の型。 *)

type route
(** メソッドとパスとハンドラの組。 *)

type t
(** 組み上がったルータ。 *)

type 'a decision =
  | Found of 'a  (** 一致した。 *)
  | Redirect of string  (** 正規形へ転送すべき (末尾スラッシュの正規化)。 *)
  | Wrong_method of Http.Method.t list  (** パスはあるがメソッドが違う。値は [allow] に載せる一覧。 *)
  | Missing  (** どのメソッドでも一致しない。 *)

(** {1 パスのコンビネータ}

    [routes] の再エクスポート。[open Routes] を書かずに済ませるためのもの。 *)

module Parts = Routes.Parts

val s : string -> ('a, 'b) path -> ('a, 'b) path
(** [s w] は固定の語 [w] に一致するセグメント。値は捨てられる。 *)

val int : ('a, 'b) path -> (int -> 'a, 'b) path
(** [int] 型のセグメント。 *)

val int32 : ('a, 'b) path -> (int32 -> 'a, 'b) path
(** [int32] 型のセグメント。 *)

val int64 : ('a, 'b) path -> (int64 -> 'a, 'b) path
(** [int64] 型のセグメント。 *)

val str : ('a, 'b) path -> (string -> 'a, 'b) path
(** 任意の 1 セグメント。

    保証: 受け取る文字列は {!Request.path} と同じ復号規則を通ったもの
          (パーセント復号済みだが、復号すると ["/"] を含むものは生のまま)。 *)

val bool : ('a, 'b) path -> (bool -> 'a, 'b) path
(** [bool] 型のセグメント。 *)

val wildcard : (Parts.t -> 'a, 'a) path
(** 残り全部のセグメント。 *)

val nil : ('a, 'a) path
(** パスの終端。単体では ["/"] にも [""] にも一致する。 *)

val ( / ) : (('a, 'b) path -> 'c) -> ('d -> ('a, 'b) path) -> 'd -> 'c
(** セグメントの連結。 *)

val ( /? ) : ('a -> ('b, 'c) path) -> 'a -> ('b, 'c) path
(** 末尾の連結。[... /? nil] の形で使う。 *)

val ( /~ ) : (('a, 'b) path -> ('c, 'd) path) -> ('a, 'b) path -> ('c, 'd) path
(** パスとパスの連結。[s "x" /~ wildcard] の形で使う。 *)

val custom :
  serialize:('c -> string) ->
  parse:(string -> 'c option) ->
  label:string ->
  ('a, 'b) path ->
  ('c -> 'a, 'b) path
(** 独自の型のセグメント。noma が用意していない型を足す拡張点。

    要求: [parse] と [serialize] が互いに逆であること — {!href} の正しさが
          これに依存する。[label] は [":shape"] のようにコロン始まりを推奨
          (経路一覧の表示に使われる)。
    保証: [parse] が [None] を返したセグメントは不一致として扱う。 *)

(** {1 経路の宣言} *)

val get : ('a, Handler.handler) path -> 'a -> route
(** [GET] の経路。 *)

val post : ('a, Handler.handler) path -> 'a -> route
(** [POST] の経路。 *)

val put : ('a, Handler.handler) path -> 'a -> route
(** [PUT] の経路。 *)

val patch : ('a, Handler.handler) path -> 'a -> route
(** [PATCH] の経路。 *)

val delete : ('a, Handler.handler) path -> 'a -> route
(** [DELETE] の経路。 *)

val options : ('a, Handler.handler) path -> 'a -> route
(** [OPTIONS] の経路。明示すると {!val-handler} の自動応答より優先される。 *)

val head : ('a, Handler.handler) path -> 'a -> route
(** [HEAD] の経路。明示しなければ [GET] が使われる (RFC 9110)。 *)

val meths : Http.Method.t list -> ('a, Handler.handler) path -> 'a -> route
(** 任意のメソッド集合の経路。

    要求: メソッド一覧は空でないこと (違反は [Invalid_argument])。
          空の経路は決して一致せず、宣言した側の意図と食い違うため。 *)

val any : ('a, Handler.handler) path -> 'a -> route
(** [GET POST PUT PATCH DELETE HEAD OPTIONS] すべての経路。 *)

val mount : string -> Handler.handler -> route
(** [mount prefix sub] は [prefix] 以下を丸ごと [sub] に委ねる。
    サブアプリもただの handler であることの帰結である。

    要求: [prefix] は 1 セグメント (["admin"] であって ["/admin/v1"] ではない)。
    保証: [sub] が受け取る {!Request.t} は{b 接頭辞を剥がしたもの}。
          [/admin/users] は [sub] からは [/users] に見える。剥がさないと
          サブアプリを単体で使えるという前提が崩れる。
          クエリ文字列は保たれる。剥がした接頭辞は {!mount_prefix_key} で
          文脈に残るので、サブアプリ側が絶対 URL を組み立てられる。
          入れ子にした場合は接頭辞が連結される。 *)

val mount_prefix_key : string Hmap.key
(** {!mount} が剥がした接頭辞を置く文脈の鍵 (["/admin"] のように先頭スラッシュ付き)。 *)

val group : Handler.middleware -> route list -> route list
(** [group mw rs] は [rs] のそれぞれに [mw] をかぶせる。

    要求: [mw] はミドルウェアの契約 M1–M5 を守ること ({!module:Handler})。
    保証: [mw] は一致した経路のハンドラだけを包む。一致しなかった場合
          (404 / 405) には走らない。認証のように「この一群だけ」に効かせたい
          ものに使う。 *)

(** {1 組み立てと実行} *)

val make :
  ?not_found:Handler.handler ->
  ?trailing_slash:[ `Redirect | `Match | `Strict ] ->
  route list ->
  t
(** 経路の一覧からルータを組む。

    要求: なし。空の一覧も有効で、すべてが [not_found] に落ちる。
          同じメソッドとパスの組を二重に宣言した場合、先に書いたものが勝つ。
    保証: [not_found] 省略時は 404 を返す。
          [trailing_slash] 省略時は [`Redirect] で、[/users/] は [/users] へ
          {b 308} で転送する。301 ではないのは、古いクライアントが 301 で
          POST を GET に書き換えてしまうため。[`Match] は末尾スラッシュを
          同一視し、[`Strict] は不一致とする。 *)

val resolve : t -> Request.t -> Handler.handler decision
(** 何が一致したかを返す。純粋で、副作用も応答の生成もしない。

    保証: [HEAD] に専用の経路がなければ [GET] の経路を探す (RFC 9110)。
          一致するメソッドが他にあれば [Wrong_method] を返し、その一覧は
          [GET] があるとき [HEAD] を、常に [OPTIONS] を含む。 *)

val handler : t -> Handler.handler
(** {!val-resolve} の結果に HTTP の方針を与えてハンドラにする。

    保証:
    - [Found h] なら [h] を呼ぶ。ただし [HEAD] のときは本体を落とし、
      長さが判っていれば [content-length] にその値を残す (RFC 9110)。
    - [Redirect loc] なら 308。
    - [Wrong_method allow] なら 405 + [allow]。ただし [OPTIONS] のときは
      204 + [allow] を返す (資源は在るので 405 は誤り)。
    - [Missing] なら [not_found]。 *)

val href : ('a, string) path -> 'a
(** パスから URL 文字列を組み立てる (逆引き)。

    {[ Router.href (user ()) 42  (* "/users/42" *) ]}

    保証: {!custom} の [parse]/[serialize] が互いに逆である限り、生成した URL は
          同じパスに一致する。 *)

val to_list : t -> string list
(** 宣言された経路の一覧 (["GET /users/:int"] の形)。起動時ログや疎通確認用。

    保証: 宣言した順を保つ。 *)
