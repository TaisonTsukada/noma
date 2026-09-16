(** 環境変数から設定を読む (12factor III)。

    {b モナドではなく applicative} である。これが要点で、欠けている変数を
    1 つずつ知らせるのではなく{b 全部まとめて}報告して起動時に落ちる。
    設定漏れは直すのに何度も再起動する類の作業になりがちで、1 回で全部判る方が
    圧倒的に速い。[( let* )] を提供しないのは、前の値に依存して次を読む形にすると
    この性質が壊れるからである。

    {[
      type t = { port : int; database_url : string; log_level : Logs.level }

      let config =
        let open Noma.Config in
        let+ port = default 8080 (int "PORT")
        and+ database_url = secret (string "DATABASE_URL")
        and+ log_level =
          default Logs.Info
            (enum [ ("debug", Logs.Debug); ("info", Logs.Info) ] "LOG_LEVEL")
        in
        { port; database_url; log_level }

      let () = match Noma.Config.load config with
        | Ok c -> run c
        | Error problems -> List.iter prerr_endline problems; exit 1
    ]}

    環境変数しか読まない。ファイルも、実行環境ごとの分岐も持たない — それらは
    12factor III が避けようとしているものそのものである。 *)

type 'a t

(** {1 読み取り} *)

val string : string -> string t
(** [string name] は環境変数 [name] を文字列として読む。

    要求: なし。
    保証: 未設定なら [load] がその旨を報告する。空文字列は「設定されている」と
          みなす — 空を意図的に渡す運用があるため。 *)

val int : string -> int t
(** 整数として読む。

    保証: 整数として読めない値は、名前と実際の値を含めて報告される。 *)

val float : string -> float t
(** 浮動小数として読む。

    保証: 読めない値は名前と実際の値を含めて報告される。 *)

val bool : string -> bool t
(** 真偽値として読む。

    保証: [true/false/1/0/yes/no/on/off] を大小文字を問わず受ける。
          それ以外は受け付けられる書き方を添えて報告する。 *)

val enum : (string * 'a) list -> string -> 'a t
(** [enum alts name] は [alts] の候補から選ぶ。

    要求: [alts] は空でないこと (違反は [Invalid_argument])。
    保証: 一致は大小文字を問わない。外れた値は{b 候補の一覧を添えて}報告する。 *)

val custom : name:string -> (string -> ('a, string) result) -> string t -> 'a t
(** 任意の型に変換する。noma が用意していない型を足す拡張点。

    要求: 変換は例外を投げず [Error] を返すこと。
    保証: [Error msg] は [name] と併せて報告される。[name] は
          ["URL"] のような型の呼び名。 *)

(** {1 組み合わせ} *)

val default : 'a -> 'a t -> 'a t
(** [default v c] は [c] が未設定のとき [v]。

    保証: {b 未設定のときだけ}既定値を使う。設定されていて読めない値は
          既定値で隠さずに報告する — 打ち間違いが黙って既定値に化けるのが
          設定事故の典型だからである。 *)

val optional : 'a t -> 'a option t
(** [optional c] は未設定を [None] にする。

    保証: [default] と同じく、読めない値は報告する。 *)

val secret : string t -> string t
(** 値を秘匿として印を付ける。

    保証: {!describe} の出力で値が伏字になる。読み取り結果そのものは変わらない。 *)

val ( let+ ) : 'a t -> ('a -> 'b) -> 'b t
(** applicative の map。 *)

val ( and+ ) : 'a t -> 'b t -> ('a * 'b) t
(** applicative の積。{b これが「全部まとめて報告する」性質の源}である。 *)

(** {1 読み込み} *)

val load : ?getenv:(string -> string option) -> 'a t -> ('a, string list) result
(** 環境から読む。

    要求: なし。[getenv] 省略時は [Sys.getenv_opt]。テストから環境を汚さずに
          検証するために差し替えられる。
    保証: {b 問題があれば全部を一度に返す}。1 件ずつではない。
          [Error] のリストは人が読める 1 行ずつの文面で、変数名を含む。 *)

val load_exn : ?getenv:(string -> string option) -> 'a t -> 'a
(** 事前条件を持つ {!load}。

    要求: 設定に問題がないこと。あれば全件を並べた [Failure] を送出する。
          起動時に落としたいだけならこちらが簡潔。 *)

val describe : ?getenv:(string -> string option) -> 'a t -> (string * string) list
(** 参照する変数と、現在の値の説明を返す。起動時ログや疎通確認用。

    要求: なし。
    保証: {!secret} を付けた変数の値は伏字になる。未設定は ["(未設定)"]、
          既定値が使われる場合はその旨が判る文面になる。 *)
