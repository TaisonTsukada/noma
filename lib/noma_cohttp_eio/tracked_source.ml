(* リクエスト本体の読み具合を追跡する source。

   cohttp-eio の本体は遅延リーダで、keep-alive のループは未読の本体を drain
   しない。ハンドラが本体を読み切らずに応答すると (413 / 503 / POST への 404 /
   500 / abort — 応答が本体より先に決まるすべての経路) 残りのバイトが次の
   リクエスト行として解釈される。静かな汚染であり request smuggling に隣接する。

   Body 自身は読了状態を持たない (任意の flow を包むだけなので追跡できない) ので、
   アダプタが自前の追跡付き source をかぶせてから Request に渡す。包んだものしか
   Request から外に出ないため、追跡を漏らす経路が存在しない。 *)

type state = { inner : Eio.Flow.source_ty Eio.Resource.t; mutable eof : bool }

module Impl = struct
  type t = state

  let single_read t buf =
    if t.eof then raise End_of_file;
    match Eio.Flow.single_read t.inner buf with
    | n -> n
    | exception End_of_file ->
        t.eof <- true;
        raise End_of_file

  let read_methods = []
end

let ops = Eio.Flow.Pi.source (module Impl)

let create (inner : _ Eio.Flow.source) =
  let st = { inner :> Eio.Flow.source_ty Eio.Resource.t; eof = false } in
  (st, Eio.Resource.T (st, ops))

let at_eof st = st.eof

(* 残りを読み捨てる。[limit] バイトまで読んで EOF に達したら [true]。
   達しなければ [false] で、呼び手は接続を閉じる。 *)
let drain ~limit st =
  if st.eof then true
  else begin
    let buf = Cstruct.create 4096 in
    let rec go left =
      if left <= 0 then false
      else
        match Eio.Flow.single_read st.inner buf with
        | n -> go (left - n)
        | exception End_of_file ->
            st.eof <- true;
            true
    in
    go limit
  end
