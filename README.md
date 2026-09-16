# noma

> **HTTP リクエストは値であり、サーバーとはその値を写す関数である。**
> noma はこの 1 つの考えを OCaml 5 の direct style で最後まで貫く。

OCaml 5.4 + Eio 向けの、小さくてモダンな HTTP API ライブラリ。
Ring / Duct / Sinatra / Hono / Compojure の設計から学び、
[12factor](https://12factor.net/ja/) と Unix 哲学、そして
「イージーではなくシンプル」を軸に据えている。

```ocaml
let users () = Noma.Router.(s "users" /? nil)
let user  () = Noma.Router.(s "users" / int /? nil)

let router =
  Noma.Router.make
    [ Noma.Router.get  (users ()) (fun _req -> Noma.Response.json "[]")
    ; Noma.Router.get  (user  ()) (fun id _req -> Noma.Response.json (find id))
    ; Noma.Router.post (users ()) create
    ]

let () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  Logs.set_reporter (Noma.Log.json_reporter ());
  Noma_cohttp_eio.Server.run ~sw ~net:env#net ~port:8080
    ~stop:(Noma_cohttp_eio.Signal.stop_on ~sw [ Sys.sigterm ])
    (Noma.Router.handler router)
```

---

## 3 つの約束

### 1. 型はひとつ

```ocaml
type handler = Request.t -> Response.t
```

ルータも、ミドルウェアを積んだスタックも、mount したサブアプリも、テストの中の
ハンドラも、全部この型。**合成しても型が変わらない**ので、どれだけ大きく組んでも
「関数を 1 つ渡す」以上のことは起きない。

### 2. `next` が無い

他の言語のミドルウェアは「次」を呼ぶ作法を持ち、呼び忘れると壊れる:

```js
app.use(async (c, next) => { before(); await next(); after() })   // await 忘れ = バグ
```

noma のミドルウェアは `handler -> handler` のただの関数で、
**「次」を呼ぶとはただの関数適用**である:

```ocaml
let timing inner req =
  let t0 = Eio.Time.Mono.now clock in
  let res = inner req in              (* ← これが next。ただの関数適用 *)
  Log.event Info "timing" [ "ms", F (elapsed t0) ];
  res
```

`async` も monad の bind も `next` という名の引数もない。呼び忘れは型が許さない —
`Response.t` を作る方法は `inner` を呼ぶか自分で構築するかの 2 つしかないから。
**Eio が IO を direct style にした結果、初めて OCaml でこれが書ける。**

### 3. 出口はふたつだけ

正常系は 1 本道。そこから外れる方法は `abort` ただ 1 つ:

```ocaml
let current_user req =
  match Request.header req "authorization" with
  | None -> Noma.abort (Response.unauthorized ())   (* 5 段深くても直接出口へ *)
  | Some tk -> verify tk
```

`Result` の bind 地獄も、型に現れない例外の氾濫も要らない。

---

## 境界はひとつ

```
       値 → 値 の世界 ── socket を知らない。テストに socket が要らない
 ┌────────────────────────────────────────────────────┐
 │ Request.t ──▶ middleware ──▶ router ──▶ handler ──▶ Response.t │
 └────────────────────────────────────────────────────┘
                      ▲                      │
 ══════════════════ adapter ══════════════════   ← 副作用はここだけ
                 (noma-cohttp-eio)
                      │                      ▼
                   socket                 socket
```

`noma` 本体は **socket を一切知らない**。HTTP/1.1 のワイヤコードは
`noma-cohttp-eio` にしかない。だからハンドラのテストはこれで済む:

```ocaml
let res = app (Noma.Request.make ~meth:`GET "/users/42") in
assert (Http.Status.to_int (Noma.Response.status res) = 200)
```

---

## noma がしないこと

`cat` があなたのファイル形式を知らないように:

| しない | 理由 |
|---|---|
| JSON ライブラリを選ばない | `Response.json` は直列化済み文字列を取る。yojson が要るなら `noma-yojson` を足す |
| DB を知らない | 依存はハンドラの引数。noma に登録する場所を作らない |
| テンプレートを持たない | HTML は `Response.html : string -> t`。生成はあなたの仕事 |
| セッションを持たない | 12factor VI。ステートレスを崩す機能を既定で置かない |
| ログの宛先を選ばない | stdout に 1 行 1 JSON だけ。ローテーションは systemd / Docker の仕事 |
| `X-Forwarded-For` を信じない | 誤設定がそのまま IP 偽装になるものを、便利さで既定にしない |

**足さないことが設計である。**

---

## 契約による設計

「最強の契約は表明ではなく型」という順で 4 段に分けている。

### 段 1 — 不変条件を型で保つ

`Request.t` / `Response.t` / `Body.t` は**すべて抽象型**。レコードも変種も公開しない。

```ocaml
(* これは書けない。書けないようにするのが契約である *)
{ status = `No_content; body = String "hi" }
```

守る不変条件:

| 不変条件 | 破れると |
|---|---|
| `Status.body_allowed s = false ⟹ body = empty` | RFC 違反の応答がワイヤに出る |
| `path` のセグメント数は `target` と常に等しい | `%2F` でセグメントを増やされ、認可の迂回になる |
| ヘッダ名の照合は大小文字を区別しない | `Authorization` の取りこぼし |

見返りに「**フィールドを足しても永久に非破壊**」が付いてくる。

### 段 2 — 署名で保つ

**呼び手の状態**に事前条件を持つ関数には、事前条件を持たない兄弟を用意する
（`get` / `find`、`load_exn` / `load`、`sw` / `sw_opt`）。
引数の値域に対する事前条件は、型で表せるものは型にする:

```ocaml
val redirect :
  ?status:[ `Moved_permanently | `Found | `See_other
          | `Temporary_redirect | `Permanent_redirect ] -> string -> t
(* 3xx 以外を渡す方法が無い *)
```

### 段 3 — 文書で保つ

全公開 `val` に `要求:` / `保証:` / `不変:` を書く。
`tools/lint_contracts.sh` が CI で欠落を検出する。

### 段 4 — 検査器で保つ

ミドルウェアの契約は最も重要で、最も破られやすい。だから
**実行できる検査器として出荷する**:

```ocaml
let () = Noma_test.check_middleware ~name:"my_mw" My.middleware
```

| | ミドルウェアの義務 | 破れると |
|---|---|---|
| **M1** | `inner` を 0 回か 1 回だけ呼ぶ | 本体は使い捨て。2 回目は空を読む |
| **M2** | `Noma.Aborted` と `Eio.Cancel.Cancelled` を捕まえない | 早期リターンが消える / Eio のキャンセルが壊れ `timeout` が効かなくなる |
| **M3** | 正常な `inner` に対して例外を投げない | 応答なしで接続が落ちる |
| **M4** | `Request.ctx` の既存の束縛を消さない | 上流の `request_id` が下流で消える |
| **M5** | 下流が返した本体を消費しない | 長さを測るために読むとクライアントに空が届く |

検査器に載せるのは**機械的に判定できる契約だけ**。
「status を理由なく変えない」は `recover` の 例外→500 と区別できないので載せない —
区別できないものを載せると、正しいミドルウェアが落ちて検査器が信用を失う。

### 段 5 — アダプタの契約

core を読まずに `noma-httpun` を書けるだけの契約を `noma.mli` に明記してある:

| | アダプタの義務 |
|---|---|
| **A1** | `Noma.run_handler` をリクエストごとに 1 回設置する |
| **A2** | リクエストごとに新しい `Switch` を張り、復帰後に閉じる |
| **A3** | ハンドラが本体を読み切らなかったら drain するか接続を閉じる |
| **A4** | `Status.body_allowed` が false なら本体も枠付けヘッダも書かない |
| **A5** | `Request.client` に実ペアアドレスを入れる |
| **A6** | 長さ既知なら `content-length`、不明なら `chunked` |

---

## 拡張性と変更耐性

| 拡張点 | 開き方 |
|---|---|
| ミドルウェア | ただの `handler -> handler`。登録機構が無い = 制約も無い |
| アダプタ | 契約 A1–A6 を満たせば誰でも書ける (core は adapter に依存しない) |
| パスの型 | `Router.custom ~serialize ~parse ~label` |
| 設定の型 | `Config.custom ~name` |
| ログの宛先 | `Logs.reporter` をそのまま使う |
| 直列化 | `Response.json` が文字列を取る。`noma-yojson` も自作も対等 |
| サブアプリ | `Router.mount : string -> handler -> route` |

**変更に強くするための規則は 3 つだけ:**

1. **公開するのは関数だけ。型の中身は公開しない。** → 追加が永久に非破壊
2. **拡張は optional 引数で行う。** → 既存の呼び出しはそのまま
3. **アダプタが要る内部は `Private` に隔離し、semver 対象外と明記する。**

---

## 12factor 対応

| | noma での実現 |
|---|---|
| I codebase | 単一 repo / opam pin |
| II dependencies | core の依存は `http` `hmap` `uri` `eio` `logs` `routes` `mtime` のみ |
| III config | `Noma.Config`。env のみ。**欠落は全部まとめて**起動時に報告して落ちる |
| IV backing services | noma は DB を知らない。依存はハンドラの引数 |
| V build/release/run | `Config.load` は run 時のみ |
| VI processes | ステートレス。セッション機構を意図的に持たない |
| VII port binding | `run ~port` で自立して listen |
| VIII concurrency | `~max_connections` / `~additional_domains` / `Eio.Executor_pool` |
| IX disposability | SIGTERM → `~stop` で drain + `~drain_deadline` |
| X dev/prod parity | 同じ `run`。差は env だけ |
| XI logs | stdout へ 1 イベント 1 行 JSON |
| XII admin | ハンドラはただの関数。別 executable から直接呼べる |

`Config` が applicative であって monad でないのは III のためである:

```
$ dune exec example/todo/main.exe
設定に問題があります:
  PORT: 整数として読めません (実際の値: "eight")
  TODO_TOKEN: 未設定です (文字列 が必要)
```

1 つずつ直して再起動を繰り返す必要がない。

---

## 同梱のミドルウェア

| | 内容 |
|---|---|
| `recover` | 例外 → 500。トレースはログにのみ。**必須** |
| `request_id` | 受け継ぐか採番して ctx と応答ヘッダへ |
| `logger` | 1 リクエスト 1 行 JSON。単調時計しか受けない |
| `timeout` | 超過で 503 |
| `body_limit` | `content-length` の事前判定と読み出し時の実測の両方 |
| `cors` | preflight 応答含む。`credentials + Any` は事前条件で弾く |
| `secure_headers` | nosniff / referrer-policy / frame-options。HSTS は明示で |

`recover` が**必須**なのは、cohttp-eio がハンドラの例外を捕まえないため。
未捕捉のまま抜けると**応答を返さずに接続が切れる**。

---

## 値制限について

`routes` のパス値は値制限で弱多相になる。ルータ定義と `href` の両方で使うなら
イータ展開して関数にすること:

```ocaml
let user () = Noma.Router.(s "users" / int /? nil)   (* ← () を付ける *)

Noma.Router.get (user ()) show
Noma.Router.href (user ()) 42   (* "/users/42" *)
```

---

## v0.1 の非対象 (意図的)

HTTP/2 · WebSocket · SSE / push 本体 · テンプレート · セッション · ORM ·
認証の実装本体 (土台のみ) · スキーマ検証 / OpenAPI · `forwarded` ミドルウェア。

「変更に強くするための規則」により、これらはすべて **v0.1 の API を壊さずに**
後から入る。

---

## 開発

```bash
opam install --deps-only --with-test .
dune build @all
dune runtest              # 131 テスト
./tools/lint_contracts.sh # 契約 lint
dune build @doc

dune exec example/hello/main.exe
PORT=8080 TODO_TOKEN=s3cret dune exec example/todo/main.exe
```

## ライセンス

MIT
