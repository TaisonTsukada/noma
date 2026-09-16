(** 早期リターン — noma で唯一の effect。

    正常系は [Request.t -> Response.t] の 1 本道である。そこから外れる方法は
    {!abort} ただ 1 つに限る。制御の抜け道を 1 つに絞ることが、多くを許すより
    simple だからである。

    {[
      let current_user req =
        match Request.header req "authorization" with
        | None -> Noma.abort (Response.unauthorized ())   (* 5 段深くても直接出口へ *)
        | Some tk -> verify tk
    ]}

    {2 なぜ例外でなく effect なのか}

    {!run_handler} は継続を再開せず [Effect.Deep.discontinue] する。したがって
    巻き戻り方そのものは例外と変わらない — 放棄したスタック上の
    [Eio.Switch.run] や [Fun.protect ~finally] は正しく実行される。継続を放置する
    実装にすると資源が永久に解放されず、リクエストごとに switch と fd が漏れる。

    effect が例外に対して唯一持つ利点は、{b 握り潰されたことを検知できる}点にある。
    素の例外では、業務コードの [try ... with _ -> ...] に飲まれたことを noma は
    知りようがない。{!run_handler} は飲まれた場合でも abort した応答を返し、
    併せて警告を記録する。{b effect を使う根拠はこの 1 点に限る} —
    そう限ることが、effect を撒き散らさないための自らへの契約である。 *)

exception Aborted
(** {!abort} が継続を打ち切るときに送出する例外。

    不変: 業務コードもミドルウェアもこれを捕まえてはならない (契約 M2)。
          捕まえても {!run_handler} が abort した応答を返すが、警告が記録される。 *)

val abort : Response.t -> 'a
(** [abort r] は現在のハンドラを直ちに打ち切り、[r] を応答とする。

    要求: {!run_handler} の内側で呼ばれること。外で呼ぶと OCaml 5 には effect 型が
          ないため実行時に [Effect.Unhandled] となる。アダプタ契約 A1 が
          「リクエストごとに必ず {!run_handler} を設置する」と定めているのは
          この事前条件を満たすため。
    保証: 呼び出しから戻ることはない (型 ['a] の通り)。
          巻き戻りの途中の [Fun.protect] や [Eio.Switch.run] は実行される。
          [Eio.Fiber.both] などで{b 分岐した fiber の中}から呼んだ場合、effect は
          受け皿ではなく scheduler に抜けて [Effect.Unhandled] となるが、Eio が
          それを親 fiber まで運ぶので {!run_handler} が回収する。並行に呼び出しを
          投げる書き方でも応答は失われない。 *)

val run_handler : Handler.handler -> Request.t -> Response.t
(** [run_handler h req] は {!abort} の受け皿を設置して [h req] を走らせる。

    要求: {b リクエストごとに 1 回}、そのリクエストを処理する fiber の内側で
          呼ぶこと。[Eio.Net.run_server] は接続ごとに fiber を fork するので、
          fiber の外側に置いたハンドラには effect が届かない (scheduler に抜ける)。
    保証: 戻り値は必ず [Response.t]。[h] が {!abort} したならその応答、
          そうでなければ [h] の戻り値。
          [h] が {!Aborted} を握り潰して正常に戻った場合も abort した応答を返し、
          ["noma.abort.swallowed"] を警告として記録する。
          分岐した fiber から abort された場合 ([Effect.Unhandled]) も回収する。
          {!Aborted} 以外の例外はそのまま通す ([recover] ミドルウェアの仕事)。 *)
