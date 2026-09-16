(** シグナルで停止を合図する (12factor IX)。

    {2 なぜ self-pipe なのか}

    Eio にはシグナルを受け取る API が無い。そして Eio のドキュメントは Switch の
    フックについて「thread-safe だが {b signal-safe ではない}」と明記している。
    OCaml のシグナルハンドラは安全点まで遅延されるとはいえ、どのドメインの
    どの地点で走るか判らないので、そこから Eio に触れるのは約束の外側になる。

    そこで {b self-pipe} を使う。シグナルハンドラの中で呼ぶのは raw な
    [Unix.write] だけで、Eio のコードには一切触れない。読み出し側は普通の
    Eio の fiber である。Unix で古くから使われている手であり、ここでも正解。 *)

val stop_on : sw:Eio.Switch.t -> int list -> unit Eio.Promise.t
(** [stop_on ~sw signals] は [signals] のいずれかを受け取ると解決される約束を返す。

    要求: [signals] は空でないこと (違反は [Invalid_argument])。
          [Sys.sigterm] や [Sys.sigint] を渡す。
    保証: 返った約束を [Server.run ~stop] に渡すと、シグナル受信で新規の受付を
          止め、処理中の接続の完了を待ってから戻る。
          シグナルハンドラの中では raw な [Unix.write] しか呼ばない
          (Eio は signal-safe ではないため)。
          2 回目以降のシグナルでは何もしない (約束は一度しか解決できない)。
    不変: [sw] が終わるとパイプは閉じられる。既存のシグナルハンドラは
          {b 置き換えられる} — 同じシグナルに別の処理を入れたいなら
          この関数を呼ぶ前後で自分で連鎖させること。 *)
