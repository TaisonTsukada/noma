(** HTTP メッセージ本体。

    抽象型である。レコードも変種も公開しないので、v0.2 で push 型 (SSE) の本体を
    足してもユーザーコードは 1 行も壊れない (「変更に強くするための規則 1」)。

    {2 読了状態について}

    [t] は「基となる flow がどこまで読まれたか」を追跡しない。{!of_source} は
    任意の [Eio.Flow.source] を包むだけで、利用者がその flow を直接読んだかを
    知る術がないからである。追跡できるふりをしない。

    追跡するのは {!to_string} を呼んだかどうかだけで、これは二度読みという
    実際に起きる取り違えを捕らえるためのもの。接続の同期のために「本体が最後まで
    読まれたか」を知る必要があるアダプタは、自前で EOF を追跡する source を
    かぶせてから {!of_source} に渡すこと (アダプタ契約 A3)。 *)

type t

exception Too_large of int
(** [Too_large max] — 本体が [max] バイトを超えた。 *)

exception Already_consumed
(** {!of_source} 由来の本体に対して {!to_string} が二度呼ばれた。 *)

val empty : t
(** 空の本体。長さは [Some 0]。 *)

val of_string : string -> t
(** [of_string s] は [s] を本体とする。

    保証: [length] は [Some (String.length s)] を返し、{!to_string} は
          何度呼んでもよい (長さが既知なので読み捨てが起きない)。 *)

val of_source : _ Eio.Flow.source -> t
(** [of_source src] は [src] を本体とする。

    要求: [src] は一度しか読めない使い捨ての流れでよい。
    保証: [length] は [None] を返す (長さ不明 → アダプタは chunked を選ぶ)。
          {!to_string} は一度しか呼べない。 *)

val length : t -> int option
(** 送出前に長さが判っているか。

    保証: [Some n] なら本体はちょうど [n] バイト。[None] は「不明」であって
          「空」ではない。 *)

val is_empty : t -> bool
(** [is_empty t] は [t] が確実に空であるとき [true]。

    保証: [length t = Some 0] と同値。長さ不明の流れに対しては [false]。 *)

val to_string : max_size:int -> t -> string
(** 本体全体を文字列として読む。

    要求: [max_size > 0] (違反は [Invalid_argument])。
    保証: 返る文字列は高々 [max_size] バイト。超えるときは読み切らずに
          [Too_large max_size] を送出する。
          {!of_source} 由来なら二度目の呼び出しは [Already_consumed]。
          {!of_string} 由来なら何度でも呼べる。 *)

(** アダプタ専用。semver の対象外で、マイナーバージョンでも変わりうる。 *)
module Private : sig
  type view = Empty | String of string | Stream of Eio.Flow.source_ty Eio.Resource.t

  val view : t -> view
  (** 保証: 同じ [t] に対して常に同じ構成子を返す (読了で変化しない)。 *)
end
