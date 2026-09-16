(** Yojson と noma を繋ぐ薄い層。

    noma 本体は JSON ライブラリを選ばない。[Response.json] は直列化済みの文字列を
    取るだけで、どのライブラリで文字列にするかは呼び手の自由である。これはその
    自由の使い方の一例にすぎず、[noma-jsonaf] も自作も対等に並ぶ。

    {[
      let show id _req =
        match Db.find id with
        | None -> Noma.abort (Noma.Response.not_found ())
        | Some u -> Noma_yojson.response (User.to_yojson u)
    ]} *)

val response :
  ?status:Http.Status.t -> ?headers:Http.Header.t -> Yojson.Safe.t -> Noma.Response.t
(** JSON を本体とする応答。

    要求: なし。
    保証: [content-type: application/json] を付ける (呼び手が [headers] で
          指定していればそちらを尊重する)。 *)

val of_request :
  max_size:int ->
  Noma.Request.t ->
  (Yojson.Safe.t, [ `Too_large of int | `Parse of string | `Consumed ]) result
(** リクエスト本体を JSON として読む。

    要求: [max_size > 0] (違反は [Invalid_argument])。
          本体は一度しか読めないので、1 リクエストにつき 1 回だけ呼ぶこと。
    保証: 例外を投げず [result] で返す。上限超過は [`Too_large]、
          JSON として読めない場合は [`Parse msg]、既に読まれていた場合は
          [`Consumed]。
    不変: [content-type] は{b 検査しない}。それを要求するかはアプリの判断であり、
          ライブラリが勝手に 415 を返す方が困る場面がある。 *)

val abort_on_error :
  (Yojson.Safe.t, [ `Too_large of int | `Parse of string | `Consumed ]) result ->
  Yojson.Safe.t
(** {!of_request} の結果を、失敗なら [Noma.abort] で切り上げる形に変える。

    要求: [Noma.run_handler] の内側で呼ぶこと (アダプタが必ず設置している)。
    保証: [`Too_large] は 413、[`Parse] と [`Consumed] は 400 で切り上げる。
          応答本体に内部の詳細は載せない。 *)
