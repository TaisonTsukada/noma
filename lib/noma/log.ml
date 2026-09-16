type value = Json_out.value = S of string | I of int | F of float | B of bool | Null

let src = Logs.Src.create "noma" ~doc:"noma HTTP library"
let pp_fields ppf fields = Format.pp_print_string ppf (Json_out.object_to_string fields)

let fields_tag : (string * value) list Logs.Tag.def =
  Logs.Tag.def "noma.fields" ~doc:"noma の構造化ログフィールド" pp_fields

let event ?(src = src) level name fields =
  Logs.msg ~src level (fun m ->
      m ~tags:(Logs.Tag.add fields_tag fields Logs.Tag.empty) "%s" name)

(* 予約キー。衝突した利用者フィールドは落として予約側を残す (.mli の契約)。 *)
let reserved = [ "ts"; "level"; "src"; "event"; "msg" ]

let rfc3339 t =
  let tm = Unix.gmtime t in
  let frac = t -. Float.floor t in
  let ms = int_of_float (frac *. 1000.) in
  let ms = if ms < 0 then 0 else if ms > 999 then 999 else ms in
  Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02d.%03dZ" (tm.Unix.tm_year + 1900)
    (tm.Unix.tm_mon + 1) tm.Unix.tm_mday tm.Unix.tm_hour tm.Unix.tm_min tm.Unix.tm_sec ms

let json_reporter ?(ppf = Format.std_formatter) ?(now = Unix.gettimeofday) () =
  let report msg_src level ~over k msgf =
    let finish _ = over () in
    msgf @@ fun ?header:_ ?tags fmt ->
    Format.kasprintf
      (fun msg ->
        let fields = Option.bind tags (fun t -> Logs.Tag.find fields_tag t) in
        let base =
          [
            ("ts", S (rfc3339 (now ())));
            ("level", S (Logs.level_to_string (Some level)));
            ("src", S (Logs.Src.name msg_src));
          ]
        in
        let all =
          match fields with
          | Some f ->
              let f = List.filter (fun (k, _) -> not (List.mem k reserved)) f in
              base @ (("event", S msg) :: f)
          | None -> base @ [ ("msg", S msg) ]
        in
        Format.fprintf ppf "%s@." (Json_out.object_to_string all);
        finish ();
        k ())
      fmt
  in
  { Logs.report }
