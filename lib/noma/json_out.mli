(** 出力専用の最小 JSON エンコーダ。

    noma は JSON ライブラリを選ばない (README の「しないこと」) が、構造化ログを
    1 行 1 オブジェクトで出すには書き出しだけは必要になる。読み取りは提供しない
    ので、パーサを持つライブラリへの依存を core に持ち込まずに済む。 *)

type value =
  | S of string
  | I of int
  | F of float
  | B of bool
  | Null
      (** ログの 1 フィールドが取りうる値。入れ子は持たない — 1 行 1 イベントの
          平坦な形に留めるのが 12factor XI の運用しやすさに効く。 *)

val escape_string : Buffer.t -> string -> unit
(** [escape_string buf s] は [s] を JSON 文字列リテラル (前後の二重引用符込み) として
    [buf] に書く。

    要求: なし ([s] は任意のバイト列でよい)。
    保証: 出力は RFC 8259 の文字列リテラルとして妥当。制御文字 (< 0x20) は
          [\u]+4 桁 16 進 に、二重引用符と逆斜線は退避する。0x20 以上のバイトは
          そのまま通すので、入力が妥当な UTF-8 なら出力も妥当な UTF-8。 *)

val write_object : Buffer.t -> (string * value) list -> unit
(** [write_object buf fields] は [fields] を JSON オブジェクトとして [buf] に書く。

    要求: なし。キーの重複も許す (JSON として妥当であり、検査はしない)。
    保証: 出力に改行を含まない — 1 行 1 イベントを守るため。
          非有限な float ([nan] / [infinity]) は JSON に表現がないので [null]
          として書く。 *)

val object_to_string : (string * value) list -> string
(** [write_object] を文字列で返す版。

    保証: 改行を含まない。 *)
