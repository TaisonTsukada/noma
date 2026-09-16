(** noma のハンドラを socket に繋ぐ (cohttp-eio 版)。

    ここが noma で唯一の副作用の境界である。これより上は値から値への関数しかない。

    {2 なぜ cohttp-eio の [run] を使わないのか}

    cohttp-eio の [Server.run] はリクエスト頭部のバッファを
    [Buf_read.of_flow ~max_size:max_int] で作る。上限が無いので、頭部を延々と
    送りつけるだけでメモリを食い潰せる。[Server.callback] が公開されているので、
    受付ループだけ自前で回して境界を入れている。

    {2 アダプタの契約}

    この実装は [noma.mli] に書かれたアダプタ契約 A1–A6 を満たす。別の HTTP
    実装 (httpun, h2) で書き直す人は、この一覧を満たせばよい:

    - {b A1} [Noma.run_handler] をリクエストごとに 1 回設置する。
    - {b A2} リクエストごとに新しい [Switch] を張り、ハンドラ復帰後に閉じる。
    - {b A3} ハンドラが本体を読み切らなかったら drain するか接続を閉じる。
    - {b A4} [Status.body_allowed] が false なら本体も枠付けヘッダも書かない。
    - {b A5} [Request.client] に実ペアアドレスを入れる ([X-Forwarded-For] を
      解決しない)。
    - {b A6} 本体の長さが既知なら [content-length]、不明なら [chunked]。 *)

type drain_deadline = float * float Eio.Time.clock_ty Eio.Resource.t
(** 排出の期限と、それを計るための時計。

    期限だけ渡して時計を忘れる書き方ができないよう、1 つの型にまとめてある
    (事前条件を型にした例)。[env#clock] を
    [(env#clock :> float Eio.Time.clock_ty Eio.Resource.t)] と絞って渡す。 *)

val run :
  sw:Eio.Switch.t ->
  net:_ Eio.Net.t ->
  ?addr:Eio.Net.Sockaddr.stream ->
  ?port:int ->
  ?backlog:int ->
  ?max_connections:int ->
  ?max_header_size:int ->
  ?max_drain_bytes:int ->
  ?additional_domains:_ Eio.Domain_manager.t * int ->
  ?stop:unit Eio.Promise.t ->
  ?drain_deadline:drain_deadline ->
  ?on_error:(exn -> unit) ->
  ?on_listen:(Eio.Net.Sockaddr.stream -> unit) ->
  Noma.handler ->
  unit
(** [run ~sw ~net handler] は待ち受けて [handler] で応答する。戻らない
    (あるいは [stop] が解決されて排出が済むまで戻らない)。

    要求: [max_header_size] と [max_drain_bytes] は正であること
          (違反は [Invalid_argument])。
          [addr] と [port] を両方渡した場合は [addr] が勝つ。
    保証:
    - [port] 既定は 8080、[addr] 既定は [0.0.0.0:port] (12factor VII —
      リバースプロキシを前提にせず自分で port を握る)。
      [port] に 0 を渡すと空いている port が選ばれ、[on_listen] で実際の
      アドレスが判る (テスト用)。
    - [on_listen] は bind と listen が済んだ後、接続を受け始める前に 1 回だけ呼ばれる。
    - [max_header_size] (既定 64KiB) はリクエスト行と全ヘッダの{b 合計}に効く。
      超えたクライアントには 431 を書いてから接続を閉じる。
    - [max_drain_bytes] (既定 64KiB) は A3 の読み捨ての上限。これを超える未読の
      本体が残っていたら、応答を書いてから接続を閉じる。
    - {b どちらの上限も、超過時は未読データを残したまま接続を閉じる}。TCP は
      この場合 RST を送るので、書いた応答 (431 や 413) が相手に届かないことが
      ある。上限は DoS を防ぐためのもので、行儀の悪い相手に綺麗な応答を届ける
      ことは目的にしていない — 届けるには相手が送り終えるまで読み続ける必要が
      あり、それ自体が新たな滞留の口になる。
      {b 保証するのは、残ったバイトが次のリクエストとして解釈されないこと}。
    - [stop] を解決すると新規の受付を止め、処理中の接続の完了を待ってから戻る
      (12factor IX)。[drain_deadline] を渡すと、[stop] からその秒数が過ぎた時点で
      処理中のものも打ち切る。
      {b 受付を止めてもリスニングソケットは [sw] が終わるまで閉じない}ので、
      その間に来た接続はカーネルの backlog に入ったまま応答されない。
      ロードバランサから外してから [stop] を送るのが正しい順序で、
      これは 12factor IX が前提にしている運用でもある。
      keep-alive の接続を掴んだままのクライアントがいると、その接続が閉じるまで
      排出は終わらない — [drain_deadline] はそのための上限である。
    - [on_error] 既定は {!Noma.Log} への記録。クライアント由来の雑音
      ([Buffer_limit_exceeded] / 接続断 / [End_of_file]) は info、
      それ以外は error として「[recover] を入れていればここには来ない」と記録する。 *)
