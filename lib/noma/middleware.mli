(** 同梱のミドルウェア。

    どれも [handler -> handler] のただの関数で、登録の仕組みも初期化の順序もない。
    必要なものを [Noma.compose] で並べるだけである。全部が
    [noma.test] の [check_middleware] を通っている。

    {2 推奨の並び}

    {[
      let app =
        Noma.compose
          [ Noma.Middleware.recover ()
          ; Noma.Middleware.request_id ()
          ; Noma.Middleware.logger ~clock:env#mono_clock ()
          ; Noma.Middleware.secure_headers ()
          ; Noma.Middleware.timeout ~clock:env#clock ~seconds:30.
          ; Noma.Middleware.body_limit ~max_bytes:1_048_576
          ]
          (Noma.Router.handler router)
    ]}

    [recover] を最も外に置くのは、内側のどのミドルウェアが落ちても応答が返るように
    するため。[request_id] を [logger] より先に置くのは、ログに ID を載せるため。 *)

(** {1 耐障害性} *)

val recover :
  ?on_error:(exn -> Printexc.raw_backtrace -> unit) -> unit -> Handler.middleware
(** 例外を 500 に変える。{b これは任意ではなく必須}である。

    要求: [on_error] は例外を送出しないこと。
    保証: [Noma.Aborted] と [Eio.Cancel.Cancelled] は{b 再送出する} (契約 M2)。
          前者を飲むと早期リターンが消え、後者を飲むと Eio のキャンセルが壊れて
          [timeout] の内側に置いた構成が黙って効かなくなる。
          それ以外の例外は [on_error] に渡したうえで 500 を返す。
    不変: {b バックトレースを応答本体に載せない}。[on_error] (既定ではログ) に
          しか渡らない。
    
    これが必須である理由: cohttp-eio はハンドラの例外を捕まえないので、
    未捕捉のまま抜けると{b 応答を返さずに接続が切れる}。 *)

val timeout :
  clock:float Eio.Time.clock_ty Eio.Resource.t -> seconds:float -> Handler.middleware
(** 指定秒で打ち切って 503 を返す。

    要求: [seconds > 0] (違反は [Invalid_argument])。
    保証: 超過時は下流の fiber をキャンセルし、503 を返す。
          [Noma.abort] は時間内なら素通しする。 *)

val body_limit : max_bytes:int -> Handler.middleware
(** リクエスト本体に上限を課す。

    要求: [max_bytes > 0] (違反は [Invalid_argument])。
    保証: [content-length] が上限を超えていれば{b 下流を呼ばずに} 413 を返す。
          ヘッダを詐称して実体が大きい場合も、読み出しの途中で上限に達した時点で
          413 になる — 宣言値だけを信じない。
    不変: [Request.ctx] を保存する。 *)

(** {1 可観測性} *)

val request_id_key : string Hmap.key
(** {!request_id} が文脈に置く鍵。 *)

val request_id : ?header:string -> ?gen:(unit -> string) -> unit -> Handler.middleware
(** リクエスト ID を受け継ぐか採番して、文脈と応答ヘッダに載せる。

    要求: [gen] は呼ぶたび異なる文字列を返すこと。
    保証: 受け取ったヘッダに ID があればそれを使い、無ければ [gen] で採番する。
          どちらの場合も {!request_id_key} で文脈から取れ、同じ名前のヘッダで
          応答にも載る。[header] 既定は ["x-request-id"]。
    不変: 既定の [gen] は{b 推測されにくさを保証しない} — 起動時の値と
          ドメイン番号と連番から作る一意な文字列にすぎない。推測できないことが
          要件なら暗号論的な生成器を [gen] に渡すこと。 *)

val logger : clock:Mtime.t Eio.Time.clock_ty Eio.Resource.t -> unit -> Handler.middleware
(** 1 リクエストにつき 1 行の構造化ログを出す (12factor XI)。

    要求: [clock] は{b 単調}時計 ([env#mono_clock])。壁時計だと NTP の補正で
          所要時間が負になりうるので型で単調時計だけを受ける。
    保証: [method] [path] [status] [dur_ms] [req_id] [client] [bytes] を記録する。
          下流が例外や [Noma.abort] で抜けた場合も必ず 1 行出す。
    不変: {b 下流の応答本体を読まない} (契約 M5)。[bytes] は長さが既知のときだけ
          記録し、流れの応答では [null] にする。長さを測るために読んでしまうと
          クライアントに空が届く。 *)

(** {1 セキュリティ} *)

type origins = [ `Any | `List of string list ]
(** 許す Origin。[`Any] は [*] を返す。 *)

val cors :
  origins:origins ->
  ?methods:Http.Method.t list ->
  ?headers:string list ->
  ?expose:string list ->
  ?credentials:bool ->
  ?max_age:int ->
  unit ->
  Handler.middleware
(** CORS ヘッダと preflight 応答。

    要求: [credentials:true] と [origins:`Any] は同時に使えない
          (違反は [Invalid_argument])。Fetch 仕様が
          [access-control-allow-origin: *] と資格情報の併用を禁じており、
          ブラウザは黙って要求を落とすため、ここで気付ける方がよい。
    保証: [origin] ヘッダが無いか許可されていない要求には CORS ヘッダを
          {b 付けない} (下流はそのまま動く)。
          preflight ([OPTIONS] かつ [access-control-request-method] あり) には
          下流を呼ばずに 204 を返す。
          [`List] のときは [vary: origin] を付ける (中間キャッシュの汚染防止)。 *)

val secure_headers :
  ?hsts:[ `Off | `Max_age of int ] ->
  ?frame:[ `Deny | `Same_origin | `Off ] ->
  ?referrer:string ->
  unit ->
  Handler.middleware
(** 既定で安全側に倒す応答ヘッダを足す。

    要求: [`Max_age n] の [n] は正であること (違反は [Invalid_argument])。
    保証: [x-content-type-options: nosniff]、[referrer-policy]、
          [x-frame-options] を足す。[hsts] 既定は [`Off] —
          HTTPS で配信していない環境で付けると自分のサイトに到達できなくなるため、
          明示的に有効にさせる。
    不変: {b ハンドラが既に設定したヘッダは上書きしない}。個別の応答で
          方針を変えられる。 *)
