type handler = Request.t -> Response.t
type middleware = handler -> handler

let id h = h
let compose ms h = List.fold_right (fun m acc -> m acc) ms h
let ( @> ) m h = m h
