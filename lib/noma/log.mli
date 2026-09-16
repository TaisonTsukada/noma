(** 構造化ログ — stdout に 1 イベント 1 行の JSON (12factor XI)。

    noma はログの宛先を選ばない。ファイルもローテーションも持たず、
    プロセスは stdout に書くだけにする。集約・保存・回転は systemd / Docker /
    ログ基盤の仕事である。

    実体は [Logs] の薄い層なので、noma の reporter を使わずに自前の reporter を
    設置してもよい。その場合 noma のイベントは {!fields_tag} 付きの通常の
    Logs メッセージとして届く。 *)

type value = Json_out.value = S of string | I of int | F of float | B of bool | Null

val src : Logs.src
(** noma 自身のログソース (["noma"])。アプリのログと分離して閾値を設定できる。 *)

val fields_tag : (string * value) list Logs.Tag.def
(** {!event} が構造化フィールドを運ぶのに使う Logs タグ。

    保証: {!event} で送られたメッセージには必ずこのタグが付く。
          自前の reporter はこれを [Logs.Tag.find] して構造を取り出せる。 *)

val event : ?src:Logs.src -> Logs.level -> string -> (string * value) list -> unit
(** [event level name fields] は 1 件の構造化イベントを記録する。

    要求: なし。[name] は ["http.request"] のようなドット区切りの識別子を想定する。
    保証: [fields] は {!fields_tag} で運ばれ、{!json_reporter} 下では
          [name] と併せて 1 行の JSON オブジェクトになる。
    不変: 出力は 1 イベントにつき 1 行 — [fields] の値に改行が含まれていても
          退避されるので行は分かれない。 *)

val json_reporter : ?ppf:Format.formatter -> ?now:(unit -> float) -> unit -> Logs.reporter
(** 1 行 1 JSON オブジェクトを書く [Logs.reporter]。

    要求: なし。[ppf] 省略時は [Format.std_formatter] (= stdout)、
          [now] 省略時は [Unix.gettimeofday] (テストで固定時刻を注入できる)。
    保証: どの Logs ソースのメッセージも JSON 1 行になる。
          {!event} 由来なら [ts] [level] [src] [event] と [fields] を平坦に並べ、
          それ以外 (依存ライブラリの Logs 呼び出しなど) は [msg] に整形文字列を
          入れる。フィールド名が衝突した場合は予約名 ([ts] [level] [src] [event]
          [msg]) を優先する。 *)
