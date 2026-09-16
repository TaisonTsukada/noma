(** noma — HTTP リクエストは値であり、サーバーとはその値を写す関数である。

    noma はこの 1 つの考えを OCaml 5 の direct style で最後まで貫く。

    {1 3 つの約束}

    {2 約束 1 — 型はひとつ}

    {[ type handler = Request.t -> Response.t ]}

    ルータも、ミドルウェアを積んだスタックも、mount したサブアプリも、テストの中の
    ハンドラも、全部この型。合成しても型が変わらない。

    {2 約束 2 — [next] が無い}

    ミドルウェアは [handler -> handler] のただの関数で、「次」を呼ぶとは
    ただの関数適用である。[async] も monad の bind もない。詳しくは {!module:Handler}。

    {2 約束 3 — 出口はふたつだけ}

    正常系は 1 本道、そこから外れる方法は {!abort} ただ 1 つ。詳しくは {!module:Abort}。

    {1 境界はひとつ}

    このライブラリは socket を一切知らない。HTTP/1.1 のワイヤコードは
    [noma-cohttp-eio] にしかない。だからハンドラのテストは
    [handler (Request.make ~meth:`GET "/users/42")] だけで済む。

    {2 アダプタを書く人へ (契約 A1–A6)}

    別の HTTP 実装 (httpun, h2, TLS 終端など) で書き直したければ、以下を満たせば
    よい。core は adapter に依存しないので、core を読む必要はない。

    - {b A1} {!run_handler} を{b リクエストごとに 1 回}、そのリクエストを処理する
      fiber の内側に設置する。[Eio.Net.run_server] は接続ごとに fiber を fork
      するので、外側に置いた受け皿には effect が届かない。
    - {b A2} リクエストごとに新しい [Eio.Switch.t] を張って
      [Request.make ~sw] に渡し、ハンドラから戻った時点で閉じる。接続ごとでは
      駄目で、keep-alive で資源が積み上がる。
    - {b A3} ハンドラが本体を読み切らなかったら、{b 読み捨てるか接続を閉じる}。
      残したまま次のリクエストを読むと、残りのバイトがリクエスト行として
      解釈される (request smuggling に隣接する)。本体の読了は [Body] が
      追跡しないので、アダプタが自前で EOF を追う source をかぶせてから渡すこと。
    - {b A4} [Http.Status.body_allowed] が false なら本体も枠付けヘッダも書かない。
      [HEAD] にも本体を書かない。
    - {b A5} {!Request.client} には{b 実ペアアドレス}を入れる。
      [X-Forwarded-For] を解決しない — 信用の境界を決めるのはアプリの仕事。
    - {b A6} [Body.length] が [Some n] なら [content-length]、[None] なら
      [chunked]。ただしハンドラが枠付けヘッダを明示していればそれを尊重する
      ([Router] の HEAD 処理がこれに依存している)。

    {1 使い方}

    {[
      let hello _req = Noma.Response.text "hello"

      let app =
        Noma.compose
          [ Noma.Middleware.recover ()
          ; Noma.Middleware.request_id ()
          ; Noma.Middleware.logger ~clock
          ]
          (Noma.Router.handler router)
    ]} *)

module Body = Body
module Request = Request
module Response = Response
module Handler = Handler
module Router = Router
module Middleware = Middleware
module Config = Config
module Abort = Abort
module Log = Log
module Json_out = Json_out

(** {1 ハンドラとミドルウェア}

    {!module:Handler} の中身をここに持ち上げてある。 *)

type handler = Handler.handler
(** [Request.t -> Response.t] *)

type middleware = Handler.middleware
(** [handler -> handler] *)

let id = Handler.id
let compose = Handler.compose
let ( @> ) = Handler.( @> )

(** {1 早期リターン}

    {!module:Abort} の中身をここに持ち上げてある。 *)

exception Aborted = Abort.Aborted

let abort = Abort.abort
let run_handler = Abort.run_handler
