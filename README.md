# nishimin.net

技術者向けアイデンティティハブ。SSH 公開鍵 / OpenPGP / Nostr の識別子を
標準パスで配信し、`curl` で叩くと ANSI カラーのプロフィールを返す。

GUI 操作は使わない。ルーティング・ヘッダ・エッジロジック・開発環境・デプロイのすべてが
リポジトリ内のコードで完結している。

```
$ curl https://nishimin.net          # 端末にはプレーンテキスト
$ curl -L https://nishimin.net/keys >> ~/.ssh/authorized_keys
```

## 構成

| ホスティング | Cloudflare Pages（ダイレクトアップロード） |
| --- | --- |
| エッジロジック | Cloudflare Pages Functions (TypeScript) |
| 静的サイト生成 | Nix derivation (`nix build .#site`) |
| 開発環境 | Nix Flake (`nix develop`) |
| デプロイ | GitHub Actions → `wrangler pages deploy` |

npm / pnpm の依存は持たない。`functions/*.ts` は wrangler 内蔵の esbuild が
そのままトランスパイルする。

## 開発

```bash
nix develop            # 開発シェル（wrangler, jq, curl, gnupg, age, figlet …）
nix run .#dev          # ローカル用にビルドして http://localhost:8788 で起動
nix flake check        # site / site-dev / typescript / nixfmt / statix / betterleaks
nix run .#fix          # nixfmt + statix 自動修正（コミット前に実行）
nix run .#install-hooks  # betterleaks pre-commit hook を有効化（clone 後に一度だけ）
```

### プロフィールの編集

**`site.nix` の 1 箇所だけ**を書き換える。`index.html` / `ansi.txt` / `plain.txt` /
`humans.txt` / `links.json` / `nostr.json` / `security.txt` は
すべてそこから `lib/render.nix` が生成する。

ASCII アートのバナーを変えるときは:

```bash
figlet -f smslant -w 120 "nishimin.net"   # 出力を site.nix の banner に貼る
```

### ディレクトリ

```
site.nix                  プロフィールデータの単一ソース
lib/render.nix            site.nix → 各ファイルの中身を組み立てる純関数群
templates/index.html.in   @key@ プレースホルダ入りの HTML
static/                   そのまま配信されるファイル（_headers, 公開鍵, 404.html …）
functions/                Pages Functions（エッジで動く TypeScript）
types/cloudflare.d.ts     Cloudflare 型の最小自前宣言（npm 依存を避けるため）
result/                   nix build .#site の成果物（本番用）
result-dev/               nix build .#site-dev の成果物（URL が localhost:8788）
```

## 鍵・識別子の差し替え

SSH 公開鍵と Nostr は設定済み。GPG は未設定（`publishWkd = false` のため非公開）。
差し替え・追加の手順は以下。

### SSH 公開鍵

```bash
ssh-keygen -t ed25519 -C "dev@nishimin.net"   # まだ鍵が無い場合
cat ~/.ssh/id_ed25519.pub > static/keys
```

### OpenPGP (WKD)

WKD は「メールアドレスの local-part を SHA-1 → z-base-32 した名前のファイルに、
公開鍵のバイナリを置く」という仕組み。`dev@nishimin.net` のハッシュは
`gudx35f8m3ns6jx87gkuda1nmtsb53nd` で、`site.nix` に記録済み。

```bash
gpg --quick-generate-key "Your Name <dev@nishimin.net>" ed25519 sign,cert 2y
gpg --fingerprint dev@nishimin.net            # → site.nix の pgp.fingerprint へ
nix run .#wkd-export                          # hu ファイルを書き出す
```

そのあと `site.nix` の `pgp.publishWkd` を `true` にする。これは PGP 表示全体の
スイッチで、`false` の間は次のすべてが出ない。鍵が無いのにプレースホルダだけが
公開される状態を防ぐため。

- WKD の `hu/` ファイル（空ファイルを置くと WKD クライアントが壊れる）
- `index.html` と curl 出力の PGP セクション（フィンガープリント、`gpg --locate-keys`）
- `security.txt` の `Encryption:` 行

`publishWkd = true` なのに鍵が無ければ `nix build` が失敗する。

確認:

```bash
gpg --locate-keys dev@nishimin.net
```

### Nostr (NIP-05)

`site.nix` の `nostr.pubkeyHex` には **64 文字の hex 公開鍵**を書く。`npub1...` ではない。

```bash
nak decode npub1...     # hex に変換
```

### security.txt の Expires

RFC 9116 で必須かつ未来日でなければならない。`site.nix` の `securityTxt.expires` を
毎年更新すること。CI が失効を検査し、残り 30 日を切ると警告を出す。

## デプロイ

Cloudflare Pages の **Git 連携ビルドは使わない**。Cloudflare 側のビルド環境に Nix が
無いため、`nix build` した成果物を wrangler のダイレクトアップロードで送っている。

GitHub Actions に以下の secrets を登録する:

| secret | 取得元 |
| --- | --- |
| `CLOUDFLARE_API_TOKEN` | Cloudflare → My Profile → API Tokens（Cloudflare Pages: Edit 権限） |
| `CLOUDFLARE_ACCOUNT_ID` | Cloudflare のダッシュボード URL に含まれる ID |

`main` への push で本番、PR でプレビューがデプロイされる。手元から送る場合:

```bash
nix run .#deploy
```

## エンドポイント

| パス | 内容 |
| --- | --- |
| `/` | ブラウザには HTML、`curl` には ANSI テキスト |
| `/?plain` | ANSI エスケープなしのテキスト |
| `/ansi.txt`, `/plain.txt` | 上記の実体（単体でも取得できる） |
| `/keys` | SSH 公開鍵 |
| `/humans.txt` | 制作者・使用技術 |
| `/links.json` | `/touch` の遷移先許可リスト |
| `/touch` | 物理媒体（QR / NFC）用リダイレクタ（302） |
| `/touch?c=<id>` | `site.nix` の `links[].id` へリダイレクト |
| `/.well-known/nostr.json` | NIP-05（CORS `*`） |
| `/.well-known/security.txt` | RFC 9116 |
| `/.well-known/openpgpkey/hu/<hash>` | WKD 公開鍵（`publishWkd = true` のとき） |

### 設計上の注意

- **`functions/_middleware.ts` の curl 分岐はルートパスに限定している。**
  ここを外すと `curl -L /keys >> ~/.ssh/authorized_keys` が ASCII アートを
  書き込んでしまい、`/.well-known/*` の Content-Type と CORS も壊れる。
- **`/touch` は「/ に 302 するだけ」に見えても消さないこと。**
  印刷して配った QR やカードは後から書き換えられない。飛び先を `site.nix` 側に
  持たせることで、配布済みの媒体の遷移先をあとから変えられる。これが存在理由。
  アクセス数は記録していない（Pages Functions の `console.log` は保存されないため）。
- **`/touch` は任意 URL へのリダイレクトを受け付けない。**
  `site.nix` の `links[].id` をキーにした許可リストのみ。オープンリダイレクタを作らないため。
- 同じ URL で HTML とテキストを出し分けるので、ルートパスの応答には
  `Vary: User-Agent` を付けている。
- **betterleaks に allowlist を足さないこと。** `paths` 指定の allowlist は findings を
  除外するのではなく、そのファイルをスキャン対象から丸ごと外す。`static/keys` を
  allowlist に入れると、そこに貼り間違えた秘密鍵が無検査で通る（実測確認済み）。
  公開鍵は既定ルールに引っかからないので allowlist は元々不要。
