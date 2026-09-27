# nishimin.net

技術者向けアイデンティティハブ。SSH 公開鍵と Nostr の識別子を
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
nix develop            # 開発シェル（wrangler, jq, curl, dig, age, figlet …）
nix run .#dev          # ローカル用にビルドして http://localhost:8788 で起動
nix flake check        # site / site-dev / typescript / nixfmt / statix / betterleaks
nix run .#fix          # nixfmt + statix 自動修正（コミット前に実行）
nix run .#test         # ローカルにサーバを立ててエンドポイントを検証する
nix run .#clean        # 生成物を削除（result 系 / .wrangler）。-n でドライラン
nix run .#install-hooks  # betterleaks pre-commit hook を有効化（clone 後に一度だけ）
```

### プロフィールの編集

**`site.nix` の 1 箇所だけ**を書き換える。`index.html` / `ansi.txt` / `plain.txt` /
`humans.txt` / `go.json` / `nostr.json` / `security.txt` は
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

SSH 公開鍵と Nostr は設定済み。
差し替え・追加の手順は以下。

### SSH 公開鍵

```bash
ssh-keygen -t ed25519 -C "dev@nishimin.net"   # まだ鍵が無い場合
cat ~/.ssh/id_ed25519.pub > static/keys
```

### Nostr (NIP-05)

`site.nix` の `nostr.pubkeyHex` には **64 文字の hex 公開鍵**を書く。`npub1...` ではない。

```bash
nak decode npub1...     # hex に変換
```

### Nostr プロフィール画像 (kind:0)

NIP-05 (`/.well-known/nostr.json`) は名前解決専用で、プロフィール画像は含めない。
プロフィール画像は **kind:0 metadata の `picture`** で管理する。

このリポジトリでは画像の配信だけを担う。

- 既定の画像パス: `/image/avatar.webp`
- 画像ファイル: `static/image/avatar.webp`
- 設定値: `site.nix` の `nostr.picturePath`

Nostr クライアント側では、`picture` に次の URL を設定して publish する:

`https://nishimin.net/image/avatar.webp`

注: kind:0 の更新は秘密鍵での署名が必要なため、このリポジトリだけでは反映完了しない。

### security.txt の Expires

RFC 9116 で必須かつ未来日でなければならない。`site.nix` の `securityTxt.expires` を
毎年更新すること。CI が失効を検査し、残り 30 日を切ると警告を出す。

## デプロイ

Cloudflare Pages の **Git 連携ビルドは使わない**。Cloudflare 側のビルド環境に Nix が
無いため、`nix build` した成果物を wrangler のダイレクトアップロードで送っている。

`main` への push で本番、PR でプレビューが自動デプロイされる。手元から送る場合:

```bash
nix run .#deploy
```

`deploy` は **アップロード前にローカルで検証し、アップロード後にデプロイ先へ
smoke を当てる**。検証が落ちたらアップロードしない。
検証を飛ばしたいときは `nix develop --command wrangler pages deploy` を直接叩く。

### 初回公開

一度だけ行う手順。すべて手元で実行する。

#### 1. API トークンを発行する

Cloudflare ダッシュボード → My Profile → API Tokens → Create Token。
権限は **Account / Cloudflare Pages / Edit**。手順 5 のドメイン紐付けで
権限不足になる場合は **Zone / DNS / Edit** も足す。

#### 2. 認証情報を設定する

```bash
export CLOUDFLARE_API_TOKEN=...   # 手順 1 のトークン
export CLOUDFLARE_ACCOUNT_ID=...  # ダッシュボード URL に含まれる 32 桁
```

wrangler はこの 2 つを読むので `wrangler login` は要らない。
同じトークンを手順 6 の CI にも使う。

#### 3. Pages プロジェクトを作る

`wrangler pages deploy` はプロジェクトが無いと対話的に作成を尋ねる。
CI は非対話なので、先に作っておく。

```bash
nix develop --command wrangler pages project create nishimin-net --production-branch main
```

#### 4. 初回デプロイ

```bash
nix run .#deploy
```

ローカル検証 → アップロード → デプロイ先の検証まで通しで走る。
検証が落ちたらアップロードしない。

#### 5. カスタムドメインを紐付ける

wrangler にドメイン用のコマンドが無いので API を直接叩く。

```bash
# -f は付けない。付けるとエラー時に Cloudflare が返す原因コードが見えなくなる。
curl -sS -X POST \
  "https://api.cloudflare.com/client/v4/accounts/$CLOUDFLARE_ACCOUNT_ID/pages/projects/nishimin-net/domains" \
  -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name":"nishimin.net"}' | jq .
```

返ってくる `zone_tag` を控える。**DNS レコードは自動では作られない**（API 経由で
追加した場合。`status: pending` / `CNAME record not set` になる）ので、自分で作る。

```bash
curl -sS -X POST \
  "https://api.cloudflare.com/client/v4/zones/<ZONE_TAG>/dns_records" \
  -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"type":"CNAME","name":"nishimin.net","content":"nishimin-net.pages.dev","proxied":true}' | jq .
```

`proxied: true` は必須。apex の CNAME は Cloudflare の CNAME フラッタニングで
成立するため、プロキシを通さないと機能しない。

ここで 403 が返ったらトークンに **Zone / DNS / Edit** が足りていない。

反映を確認する:

```bash
dig +short nishimin.net
nix run .#smoke -- https://nishimin.net
```

ドメインの検証状態は次で見られる（`status` が `active` になれば完了）:

```bash
curl -sS \
  "https://api.cloudflare.com/client/v4/accounts/$CLOUDFLARE_ACCOUNT_ID/pages/projects/nishimin-net/domains" \
  -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" | jq '.result[] | {name, status, verification_data}'
```

#### 6. GitHub リポジトリと secrets

**secrets を入れてから push する。** 先に push すると secrets が無い状態で
CI のデプロイステップが落ちる。

```bash
gh repo create nishimin.net --public --source=. --remote=origin   # または --private
gh secret set CLOUDFLARE_API_TOKEN     # 値はプロンプトで入力（履歴に残さない）
gh secret set CLOUDFLARE_ACCOUNT_ID
git push -u origin main
```

以降は `main` への push で本番、PR でプレビューが自動デプロイされる。

## エンドポイント

| パス | 内容 |
| --- | --- |
| `/` | ブラウザには HTML、`curl` には ANSI テキスト |
| `/?plain` | ANSI エスケープなしのテキスト |
| `/ansi.txt`, `/plain.txt` | 上記の実体（単体でも取得できる） |
| `/keys` | SSH 公開鍵 |
| `/humans.txt` | 制作者・使用技術 |
| `/go.json` | `/go/<id>` の遷移先許可リスト |
| `/go`, `/go/<id>` | 物理媒体（QR / NFC）用リダイレクタ（302） |
| | `<id>` は `site.nix` の `links[].id` と組み込みの `home` |
| `/image/avatar.webp` | Nostr kind:0 `picture` 用アイコン画像 |
| `/.well-known/nostr.json` | NIP-05（CORS `*`） |
| `/.well-known/security.txt` | RFC 9116 |

### 設計上の注意

- **`functions/_middleware.ts` の curl 分岐はルートパスに限定している。**
  ここを外すと `curl -L /keys >> ~/.ssh/authorized_keys` が ASCII アートを
  書き込んでしまい、`/.well-known/*` の Content-Type と CORS も壊れる。
- **`/go` は「302 するだけ」に見えても消さないこと。**
  印刷して配った QR やカードは後から書き換えられない。飛び先を `site.nix` 側に
  持たせることで、配布済みの媒体の遷移先をあとから変えられる。これが存在理由。
  アクセス数は記録していない（Pages Functions の `console.log` は保存されないため）。
- **`/go` は任意 URL へのリダイレクトを受け付けない。**
  `site.nix` の `links[].id` と組み込みの `home` だけ。オープンリダイレクタを作らないため。
- 同じ URL で HTML とテキストを出し分けるので、ルートパスの応答には
  `Vary: User-Agent` を付けている。
- **betterleaks に allowlist を足さないこと。** `paths` 指定の allowlist は findings を
  除外するのではなく、そのファイルをスキャン対象から丸ごと外す。`static/keys` を
  allowlist に入れると、そこに貼り間違えた秘密鍵が無検査で通る（実測確認済み）。
  公開鍵は既定ルールに引っかからないので allowlist は元々不要。
