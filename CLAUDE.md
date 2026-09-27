# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```bash
nix develop              # 開発シェル（wrangler, jq, curl, dig, age, openssh, figlet, nixfmt, statix）
nix run .#dev            # site-dev をビルドし wrangler pages dev を http://localhost:8788 で起動
nix run .#fix            # nixfmt + statix 自動修正（コミット前に実行する）
nix run .#clean          # gitignore 対象の生成物を削除（-n でドライラン）
nix run .#test           # ローカルにサーバを立ててエンドポイントを検証する
nix run .#smoke -- <url> # 任意の URL を検証（既定 http://localhost:8788）
nix flake check          # site / site-dev / typescript / nixfmt / statix / betterleaks
nix build .#site         # 本番用の静的ツリーを result/ に生成
nix build .#site-dev     # ローカル確認用（URL が localhost:8788）を result-dev/ に生成
nix run .#deploy         # 検証 → アップロード → デプロイ先の検証まで通しで実行
nix run .#install-hooks  # betterleaks pre-commit hook を有効化（clone 後に一度だけ）
```

**新しいファイルを追加したら `git add` すること。** flake は git の追跡下にないファイルを見ないので、
`git add` を忘れると `nix build` / `nix flake check` がそのファイルを認識しない。

**コミットメッセージ規約は `/commit`**（`.claude/skills/commit/SKILL.md`）。
Type は feat / fix / content / style / refactor / test / docs / chore の 8 種。
コミット前に `nix run .#fix` と `nix flake check` を通す。

### エンドポイントの検証

```bash
nix run .#test              # 本番用の成果物をローカル（:8799）に立てて検証
nix run .#smoke -- <url>    # 既に動いているサーバや本番を検証
```

検査内容は `flake.nix` の `smokeApp` にある。**期待値は `site.nix` から生成している**ので、
`links` を増やせば `/go/<id>` の検査も自動で増える。

いちばん重要なのは **`/keys` に ANSI が混じっていないこと**。curl 分岐がルート以外へ
漏れると、`curl -L /keys >> ~/.ssh/authorized_keys` が ASCII アートを書き込む。
これは公開後に他人の環境を壊すので、必ずこの検査を通すこと。

CI（`.github/workflows/deploy.yml`）はデプロイの直前に `nix run .#test` を実行する。
落ちたらデプロイまで進まない。

## Architecture

### データフロー — site.nix が単一ソース

```
site.nix ──> lib/render.nix ──> flake.nix の mkSite ──> result/     (本番)
                   ↑                                  └─> result-dev/ (localhost)
       templates/index.html.in
                                 static/ ──────────────> 両方へ丸ごとコピー
```

`lib/render.nix` は `site.nix` の attrset を受け取り、配信する各ファイルの**中身（文字列）を返す純関数群**。
`flake.nix` の `mkSite { name, url }` がそれを `passAsFile` でファイル化し、`static/` のコピーの上に置く。
`url` を引数にしてあるのは、ローカル確認時に curl 出力とコピペ用コマンドを
`http://localhost:8788` に向けるため（HTML の `href` は相対なのでどちらでも動く）。

`result/` 配下の以下は**すべて生成物**。直接編集してはいけない:

| 生成物 | 生成元 |
|---|---|
| `index.html` | `templates/index.html.in` + `lib/render.nix` の `htmlVars` |
| `ansi.txt` / `plain.txt` | `lib/render.nix` の `mkProfile`（同じ行データから色あり/なしを生成） |
| `humans.txt`, `go.json` | `lib/render.nix` |
| `.well-known/nostr.json`, `security.txt` | `lib/render.nix` |

プロフィールの変更は `site.nix` の 1 箇所で済ませる。表示の整形ロジックを変えるときだけ `lib/render.nix` を触る。

### 入力と出力のディレクトリ

- `static/` — 入力。そのまま配信されるファイル（`_headers`, 公開鍵, `robots.txt`, `404.html`）
- `result/` — `nix build .#site`（本番用）の出力。`/nix/store` へのシンボリックリンクで gitignore 済み。
  `wrangler.jsonc` の `pages_build_output_dir` がここを指す
- `result-dev/` — `nix build .#site-dev`（ローカル確認用）の出力。`nix run .#dev` が使う
- `functions/` — リポジトリ直下に置いたまま。wrangler は **cwd の `functions/`** を読むので
  `result/` には入れない

### デプロイ経路

**Cloudflare Pages の Git 連携ビルドは使わない。** Cloudflare 側のビルド環境に Nix が無いため。
`.github/workflows/deploy.yml` が `nix flake check` → `nix build` → `nix run .#test` →
`wrangler pages deploy` を行う
（ダイレクトアップロード）。`main` push で本番、PR でプレビュー。

## 破ると壊れるルール

### curl 分岐はルートパス限定（`functions/_middleware.ts`）

`_middleware.ts` は `functions/` 直下にあるため**全パスで呼ばれる**。User-Agent による
テキスト出し分けは `/` と `/index.html` に限定してあり、この早期 return を外すと:

- `curl -L /keys >> ~/.ssh/authorized_keys` が ASCII アートを書き込む
- `/.well-known/*` の `Content-Type` と CORS が壊れる

### `_headers` は静的アセットにしか適用されない

`static/_headers` の `/*` ルールは Cloudflare の静的アセット配信にのみ効き、
Function が自前で作った `Response` には乗らない（実測確認済み）。
そのため `_middleware.ts` が静的アセットの応答からヘッダを引き写している。

この仕組みは **`_headers` の `/*` ブロックに `X-Content-Type-Options` があること**を
「適用済みマーカー」として使っている（`APPLIED_MARKER`）。この行を消すと判定が壊れる。
ヘッダを足すときは `static/_headers` だけを編集すればよい（自動で Function 応答にも乗る）。

### `/go` の役割と制約

**「/ に 302 するだけ」に見えても消さないこと。** 印刷して配った QR やカードは後から
書き換えられないので、飛び先を `site.nix` に持たせて後から変更できるようにしてある。
これが `/go` の存在理由で、`Cache-Control: no-store` もそのためにある
（キャッシュされると配布済みの端末が古い先へ飛び続ける）。

アクセス数は記録していない。Pages Functions の `console.log` は
`wrangler pages deployment tail` を張っている間しか流れず保存されないため、
書いても読めるものにならない。必要になったら Analytics Engine か KV を足す。

遷移先は `/go.json` の許可リスト（`site.nix` の `links[].id` と組み込みの `home`）からのみ選ぶ。
`?to=<任意 URL>` のような受け口を追加しないこと。

### npm 依存を持ち込まない

`package.json` は無い。`functions/*.ts` は wrangler 内蔵の esbuild がそのままトランスパイルする。
esbuild は型を見ないので、型検査は `nix flake check` の `typescript`（`tsc --noEmit`）が担う。
Cloudflare の型は `types/cloudflare.d.ts` に必要な分だけ自前宣言してある
（`@cloudflare/workers-types` は引けない）。型を足すときはここに書く。

`nodePackages` は nixpkgs から削除済み（`error: nodePackages has been removed`）。
`pkgs.wrangler` / `pkgs.pnpm` を使う。

### Nix 文字列の ESC

ANSI エスケープは `builtins.fromJSON ''""''` で得ている。Nix の文字列リテラルに `\e` が無いため。
`lib/render.nix` を編集するとき、**生の ESC バイト（0x1B）をファイルに書き込むと
`fromJSON` が JSON パースエラーで落ちる**。リテラルの 6 文字 `` を保つこと。

### betterleaks — allowlist を足さない

`.betterleaks.toml` は**意図的に置いていない**。公開鍵を意図的にコミットするリポジトリなので
一度 allowlist を書いたが、実測の結果それが有害だと分かったため削除した。

- betterleaks 1.x は `ssh-ed25519` / `age1` の**公開鍵を検出しない**ので allowlist は元々不要
- `paths` 指定の allowlist は「findings を除外する」のではなく
  **そのファイルをスキャン対象から丸ごと外す**（`static/keys` に本物の `AGE-SECRET-KEY` を
  置くと、allowlist ありで `scanned 0 bytes`／なしで `leaks found: 1`）
- つまり秘密鍵を貼り間違える可能性が最も高いファイルが、まさに無検査になっていた

将来 allowlist が必要になっても `paths` だけで書かないこと。`[extend] useDefault = true` を
伴わない設定ファイルは既定ルールを丸ごと無効にする点にも注意。

### ビルド時ガード

ビルドを落とすガードが 2 つある（どちらも故意に壊して発火を確認済み）:

1. `index.html` に未置換の `@key@` が残っていたらビルド失敗
   → `lib/render.nix` の `htmlVars` にキーを足す
2. `site.nix` の `links[].id` が重複していたらビルド失敗（`lib/render.nix` の `assert`）
   → `lib.listToAttrs` は先勝ちなので、重複すると `/go/<id>` の遷移先が
     黙って消える。表示には両方出るため、止めないと気づけない

### security.txt の Expires

RFC 9116 で必須かつ未来日。`site.nix` の `securityTxt.expires` を毎年更新する。
Nix は純粋で現在時刻を扱えないので、失効検査は CI（`.github/workflows/deploy.yml`）が行い、
残り 30 日を切ると警告を出す。

## 鍵・ID の状態

SSH 公開鍵と Nostr の hex 公開鍵は実データが入っている。プレースホルダは残っていない。
差し替え手順（SSH / Nostr hex）は `README.md` にある。
