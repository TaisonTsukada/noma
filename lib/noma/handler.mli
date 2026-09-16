(** ハンドラとミドルウェア — noma の全体がこの 2 つの型に乗っている。

    {[
      type handler    = Request.t -> Response.t
      type middleware = handler -> handler
    ]}

    ルータも、ミドルウェアを積んだスタックも、mount したサブアプリも、テストの中の
    ハンドラも、全部 [handler] である。{b 合成しても型が変わらない}ので、どれだけ
    大きく組んでも「関数を 1 つ渡す」以上のことが起きない。

    {2 [next] が無いこと}

    他の言語のミドルウェアは「次」を呼ぶ作法を持ち、呼び忘れると壊れる。noma の
    ミドルウェアはただの関数で、「次」を呼ぶとはただの関数適用である:

    {[
      let timing inner req =
        let t0 = Eio.Time.now clock in
        let res = inner req in          (* これが next。ただの関数適用 *)
        Log.event Info "timing" [ ("ms", F (Eio.Time.now clock -. t0)) ];
        res
    ]}

    [async] も monad の bind も [next] という名の引数もない。呼び忘れは型が許さない —
    [Response.t] を作る方法は [inner] を呼ぶか自分で構築するかの 2 つしかないから。

    {2 ミドルウェアの契約}

    ミドルウェアは以下を守ること。[noma.test] の [check_middleware] がこれらを
    実行時に検査する (M5 を除く M1–M5 は機械的に判定できる):

    - {b M1} [inner] をちょうど 0 回か 1 回だけ呼ぶ。本体は使い捨てなので、
      2 回呼ぶと 2 回目は空を読む。
    - {b M2} {!Abort.Aborted} と [Eio.Cancel.Cancelled] を捕まえない。前者を飲むと
      早期リターンが消え、後者を飲むと Eio のキャンセルが壊れて
      [timeout] の内側に [recover] を置いた構成が黙って効かなくなる。
    - {b M3} 正常な [inner] に対して自分から例外を投げない。
      ([inner] を呼ばない場合に [Response.t] を返すこと自体は型が保証している。)
    - {b M4} [Request.ctx] の既存の束縛を消さない (足すのは可)。
    - {b M5} 下流が返した [Response] の本体を消費しない。 *)

type handler = Request.t -> Response.t
type middleware = handler -> handler

val id : middleware
(** 何もしないミドルウェア。{!compose} の単位元。 *)

val compose : middleware list -> middleware
(** [compose ms] は [ms] を 1 本にまとめる。

    要求: なし。空リストは {!id}。
    保証: {b リストの先頭が最も外側}。[compose [a; b; c] h] は [a (b (c h))] と
          等しい。リクエストは上から下へ、レスポンスは下から上へ流れる。
    不変: [(middleware, compose, id)] はモノイドを成す —
          [compose [] = id] であり、結合律
          [compose [compose xs; compose ys] = compose (xs @ ys)] が成り立つ。
          [test/test_laws.ml] がこれを検査する。 *)

val ( @> ) : middleware -> handler -> handler
(** [m @> h] は [m h]。スタックの末尾にハンドラを置く読みやすい書き方。 *)
