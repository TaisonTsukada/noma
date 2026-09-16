# CHANGES

## v0.1.0 (未リリース)

最初の版。

- `Noma.Request` / `Noma.Response` / `Noma.Body` — すべて抽象型。
  RFC の不変条件 (本体を持てない status、パスのセグメント数) を型で保つ。
- `Noma.handler` = `Request.t -> Response.t`、`Noma.middleware` = `handler -> handler`。
  `compose` / `id` はモノイドを成す。
- `Noma.abort` — 唯一の effect。継続は `discontinue` するので資源が正しく解放され、
  握り潰されたことを検知できる。
- `Noma.Router` — 型付きコンビネータ。`resolve` (決定) と `handler` (方針) を分離。
  405 + allow / HEAD→GET / OPTIONS 自動応答 / 308 正規化 / `mount` / `href`。
- `Noma.Config` — applicative。欠落を全部まとめて報告する (12factor III)。
- `Noma.Log` — stdout に 1 イベント 1 行 JSON (12factor XI)。
- `Noma.Middleware` — recover / request_id / logger / timeout / body_limit /
  cors / secure_headers の 7 本。
- `noma.test` — ミドルウェア契約 M1–M5 の実行できる検査器。
- `noma-cohttp-eio` — アダプタ契約 A1–A6 を満たす。頭部バッファの上限、
  keep-alive の本体 drain-or-close、RFC 準拠の枠付け、SIGTERM での graceful shutdown。
- `noma-yojson` — Yojson との接続例。
