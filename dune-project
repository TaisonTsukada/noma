(lang dune 3.20)
(name noma)
(generate_opam_files true)

(source (github taison-tsukada/noma))
(license MIT)
(authors "taison tsukada")
(maintainers "taison tsukada")

(package
 (name noma)
 (synopsis "A small, direct-style HTTP library for OCaml 5")
 (description
  "noma treats an HTTP request as a value and a server as a function that maps\n\
   it to a response. Handlers are `Request.t -> Response.t`; middleware is\n\
   `handler -> handler`. No monad, no callback, no `next`. The core knows\n\
   nothing about sockets - wire protocols live in adapter packages.")
 (tags ("http" "web" "eio" "effects"))
 (depends
  (ocaml (>= 5.1.0))
  (http (>= 6.0.0))
  (hmap (>= 0.8.1))
  (uri (>= 4.2.0))
  (eio (>= 1.0))
  (logs (>= 0.7.0))
  (routes (>= 2.0.0))
  (mtime (>= 2.0.0))
  (alcotest :with-test)
  (odoc :with-doc)))

(package
 (name noma-cohttp-eio)
 (synopsis "cohttp-eio adapter for noma")
 (description
  "Binds a noma handler to a socket using cohttp-eio. Implements the noma\n\
   adapter contract (A1-A6): per-request effect handler and switch, bounded\n\
   request head, keep-alive body drain-or-close, RFC-correct framing.")
 (tags ("http" "web" "eio"))
 (depends
  (ocaml (>= 5.1.0))
  (noma (= :version))
  (cohttp-eio (>= 6.0.0))
  (eio_main (>= 1.0))
  (alcotest :with-test)
  (odoc :with-doc)))

(package
 (name noma-yojson)
 (synopsis "Yojson helpers for noma")
 (description
  "Optional convenience layer binding Yojson to noma's string-based JSON\n\
   constructors. noma core deliberately does not choose a JSON library.")
 (tags ("http" "web" "json"))
 (depends
  (ocaml (>= 5.1.0))
  (noma (= :version))
  (yojson (>= 2.0.0))
  (alcotest :with-test)
  (odoc :with-doc)))
