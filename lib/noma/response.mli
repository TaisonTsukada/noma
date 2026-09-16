(** 返す HTTP レスポンス。

    抽象型である。レコードを公開すると
    [{ status = `No_content; body = String "hi" }] のような RFC 違反の値が
    書けてしまう。{b 書けないようにするのが契約}であって、書いてから怒るのは
    契約ではない。代償は [r.status] が [Response.status r] になることだが、
    見返りに「フィールドを足しても永久に非破壊」が付いてくる。

    この型を noma が所有していること自体が、core をアダプタから分けている理由である。
    cohttp-eio のレスポンスは [writer -> unit] の不透明な関数で、status を読むことも
    ヘッダを足すこともできない。それではログも CORS も ETag も書けない。 *)

type t

val make : ?status:Http.Status.t -> ?headers:Http.Header.t -> ?body:Body.t -> unit -> t
(** [make ()] はレスポンスを組み立てる。既定は [`OK] / ヘッダ無し / 本体無し。

    要求: なし。
    不変: [Http.Status.body_allowed status] が [false] のとき (1xx / 204 / 304)、
          [body] は捨てられて {!body} は空を返す。RFC 9110 では枠付けヘッダごと
          省く必要があり、ここで落としておかないとアダプタが不正な応答を書く。 *)

(** {2 構築} *)

val text : ?status:Http.Status.t -> ?headers:Http.Header.t -> string -> t
(** [text s] は [text/plain; charset=utf-8] の応答。

    保証: 呼び手が [headers] で content-type を与えていればそちらを尊重する。 *)

val html : ?status:Http.Status.t -> ?headers:Http.Header.t -> string -> t
(** [html s] は [text/html; charset=utf-8] の応答。

    保証: 呼び手の content-type を尊重する。 *)

val json : ?status:Http.Status.t -> ?headers:Http.Header.t -> string -> t
(** [json s] は [application/json] の応答。[s] は{b 直列化済み}の JSON 文字列。

    要求: [s] が妥当な JSON であること — noma は検査しない。
          noma は JSON ライブラリを選ばないので、直列化は呼び手の仕事である
          ([noma-yojson] を使うか、好きなライブラリで文字列にする)。
    保証: 呼び手の content-type を尊重する。 *)

val stream : ?status:Http.Status.t -> ?headers:Http.Header.t -> _ Eio.Flow.source -> t
(** [stream src] は [src] を本体とする応答。

    保証: 長さ不明なのでアダプタは chunked で送る (契約 A6)。 *)

val empty : ?status:Http.Status.t -> ?headers:Http.Header.t -> unit -> t
(** 本体のない応答。既定は [`OK]。

    要求: なし。
    保証: {!body} は空。204 を返したいときの入口でもある
          ([empty ~status:`No_content ()])。 *)

val redirect :
  ?status:
    [ `Moved_permanently
    | `Found
    | `See_other
    | `Temporary_redirect
    | `Permanent_redirect ] ->
  string ->
  t
(** [redirect loc] は [location: loc] を付けた転送応答。既定は [`See_other]。

    要求: [status] は 3xx の転送のみ — 型がそれ以外を渡す方法を持たない。
          事前条件を型にした例である。
    保証: [location] ヘッダが [loc] に設定される。 *)

(** {2 定型の応答} *)

val not_found : unit -> t
(** 404。 *)

val bad_request : ?msg:string -> unit -> t
(** 400。

    要求: [msg] は利用者に見せてよい内容であること — 内部の詳細を渡さない。
    保証: [msg] 省略時の本体は定型文のみ。 *)

val unauthorized : ?challenge:string -> unit -> t
(** 401。

    要求: なし。
    保証: [challenge] を渡すと [www-authenticate] ヘッダに載る
          (RFC 9110 は 401 にこのヘッダを要求する)。 *)

val forbidden : unit -> t
(** 403。 *)

val method_not_allowed : allow:Http.Method.t list -> t
(** 405。

    要求: [allow] は空でないこと (違反は [Invalid_argument])。
          RFC 9110 は 405 に [allow] ヘッダを必須としており、空の 405 は
          クライアントに何の情報も与えない。
    保証: [allow] ヘッダが設定される。 *)

val payload_too_large : unit -> t
(** 413。 *)

val internal_server_error : unit -> t
(** 500。

    保証: 本体は定型文のみ。noma が内部の詳細を本体に載せることはない。 *)

(** {2 読み出し} *)

val status : t -> Http.Status.t
(** ステータス。 *)

val headers : t -> Http.Header.t
(** ヘッダ。 *)

val body : t -> Body.t
(** 本体。 *)

(** {2 変換 — ミドルウェアが使う} *)

val add_header : string -> string -> t -> t
(** 同名ヘッダを残したまま 1 つ足す ([set-cookie] のように複数許される用。) *)

val set_header : string -> string -> t -> t
(** 同名ヘッダを置き換える。 *)

val remove_header : string -> t -> t
(** 同名ヘッダを取り除く。 *)

val with_status : Http.Status.t -> t -> t
(** ステータスを差し替える。

    不変: 新しい [status] が本体を許さないなら本体は捨てられる。 *)

val map_body : (Body.t -> Body.t) -> t -> t
(** 本体を写す。

    不変: [status] が本体を許さないなら結果は捨てられる。 *)

val with_body : Body.t -> t -> t
(** 本体を差し替える。

    不変: [status] が本体を許さないなら捨てられる。 *)
