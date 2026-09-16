let response ?status ?headers json =
  Noma.Response.json ?status ?headers (Yojson.Safe.to_string json)

let of_request ~max_size req =
  if max_size <= 0 then invalid_arg "Noma_yojson.of_request: max_size は正であること";
  match Noma.Body.to_string ~max_size (Noma.Request.body req) with
  | exception Noma.Body.Too_large n -> Error (`Too_large n)
  | exception Noma.Body.Already_consumed -> Error `Consumed
  | s -> (
      match Yojson.Safe.from_string s with
      | json -> Ok json
      | exception Yojson.Json_error msg -> Error (`Parse msg))

let abort_on_error = function
  | Ok json -> json
  | Error (`Too_large _) -> Noma.abort (Noma.Response.payload_too_large ())
  | Error (`Parse _) -> Noma.abort (Noma.Response.bad_request ~msg:"Malformed JSON" ())
  | Error `Consumed ->
      Noma.abort (Noma.Response.bad_request ~msg:"Request body already read" ())
