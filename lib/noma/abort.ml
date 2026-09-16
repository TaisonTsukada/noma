type _ Effect.t += Abort : Response.t -> 'a Effect.t

exception Aborted

let abort r = Effect.perform (Abort r)

let run_handler (h : Handler.handler) req =
  (* リクエストごとに確保する。fiber 間で共有してはならない。 *)
  let pending = ref None in
  Effect.Deep.match_with h req
    {
      retc =
        (fun res ->
          match !pending with
          | None -> res
          | Some r ->
              (* ここに来たということは、業務コードが Aborted を握り潰して
                 正常に戻ったということ。素の例外では検知できない唯一の事象。 *)
              Log.event Logs.Warning "noma.abort.swallowed"
                [ ("status", Log.I (Http.Status.to_int (Response.status r))) ];
              r);
      exnc =
        (function
        | Aborted -> Option.get !pending
        (* 分岐した fiber の中から abort した場合、effect はこの受け皿ではなく
           scheduler に抜けて Effect.Unhandled になり、Eio が親 fiber まで運ぶ。
           そこで回収する。Eio で並行に呼び出しを投げるのは普通のことなので、
           そこで落ちないようにしておく。 *)
        | Effect.Unhandled (Abort r) -> r
        | e -> raise e);
      effc =
        (fun (type a) (e : a Effect.t) ->
          match e with
          | Abort r ->
              Some
                (fun (k : (a, Response.t) Effect.Deep.continuation) ->
                  pending := Some r;
                  Effect.Deep.discontinue k Aborted)
          | _ -> None);
    }
