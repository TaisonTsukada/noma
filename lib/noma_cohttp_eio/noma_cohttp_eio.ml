(** noma を cohttp-eio に繋ぐアダプタ。

    noma 本体は socket を知らない。HTTP/1.1 のワイヤコードはこのパッケージにしか
    ない。差し替えたければ [noma.mli] のアダプタ契約 A1–A6 を満たす別の実装を
    書けばよく、core は 1 行も変わらない。

    {[
      let () =
        Eio_main.run @@ fun env ->
        Eio.Switch.run @@ fun sw ->
        Logs.set_reporter (Noma.Log.json_reporter ());
        Noma_cohttp_eio.Server.run ~sw ~net:env#net ~port:8080 app
    ]} *)

module Server = Server
module Signal = Signal
