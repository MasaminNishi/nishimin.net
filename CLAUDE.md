# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```bash
nix develop              # 開発シェル（wrangler, jq, curl, gnupg, age, openssh, figlet, nixfmt, statix）
nix run .#dev            # nix build → wrangler pages dev を http://localhost:8788 で起動
nix run .#fix            # nixfmt + statix 自動修正（コミット前に実行する）
nix flake check          # nixfmt / statix / betterleaks / サイトのビルド
nix build .#site         # 静的ツリーを result/ に生成
nix run .#deploy         # Cloudflare Pages へダイレクトアップロード
nix run .#wkd-export     # GPG 公開鍵を WKD の hu ファイルへ書き出す
nix run .#install-hooks  # betterleaks pre-commit hook を有効化（clone 後に一度だけ）
```

**新しいファイルを追加したら `git add` すること。** flake は git の追跡下にないファイルを見ないので、
`git add` を忘れると `nix build` / `nix flake check` がそのファイルを認識しない。

### 自動テストは無い

テストフレームワークは導入していない。変更の検証はエンドポイントを実際に叩いて行う。
`nix run .#dev` を起動した状態で:

```bash
B=http://localhost:8788
curl -s $B/ -H 'User-Agent: Mozilla/5.0' | head -3   # ブラウザ → HTML
curl -s $B/                                          # curl → ANSI テキスト
curl -s "$B/?plain"                                  # ANSI なし
curl -sI $B/touch                                    # 302 + Location
curl -sI $B/.well-known/nostr.json                   # Access-Control-Allow-Origin: *
curl -s $B/keys                                      # ← ASCII アートが返ったら middleware のバグ
```

最後の 1 行が最重要の回帰テスト（後述の「curl 分岐」を参照）。

## Architecture

### データフロー — site.nix が単一ソース

```
site.nix ──> lib/render.nix ──> flake.nix の siteDrv ──> result/
                   ↑
       templates/index.html.in
                                 static/ ────────────────> result/（丸ごとコピー）
```

`lib/render.nix` は `site.nix` の attrset を受け取り、配信する各ファイルの**中身（文字列）を返す純関数群**。
`flake.nix` の `siteDrv` がそれを `passAsFile` でファイル化し、`static/` のコピーの上に置く。

`result/` 配下の以下は**すべて生成物**。直接編集してはいけない:

| 生成物 | 生成元 |
|---|---|
| `index.html` | `templates/index.html.in` + `lib/render.nix` の `htmlVars` |
| `ansi.txt` / `plain.txt` | `lib/render.nix` の `mkProfile`（同じ行データから色あり/なしを生成） |
| `humans.txt`, `links.json` | `lib/render.nix` |
| `.well-known/nostr.json`, `security.txt` | `lib/render.nix` |

プロフィールの変更は `site.nix` の 1 箇所で済ませる。表示の整形ロジックを変えるときだけ `lib/render.nix` を触る。

### 入力と出力のディレクトリ

- `static/` — 入力。そのまま配信されるファイル（CSS, `_headers`, 公開鍵, WKD policy）
- `result/` — `nix build` の出力（`/nix/store` へのシンボリックリンク）。gitignore 済み。
  `wrangler.jsonc` の `pages_build_output_dir` がここを指す
- `functions/` — リポジトリ直下に置いたまま。wrangler は **cwd の `functions/`** を読むので
  `result/` には入れない

### デプロイ経路

**Cloudflare Pages の Git 連携ビルドは使わない。** Cloudflare 側のビルド環境に Nix が無いため。
`.github/workflows/deploy.yml` が `nix flake check` → `nix build` → `wrangler pages deploy` を行う
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

### `/touch` はオープンリダイレクタにしない

遷移先は `site.nix` の `links[].id` をキーにした許可リスト（`/links.json` 経由）からのみ選ぶ。
`?to=<任意 URL>` のような受け口を追加しないこと。

### npm 依存を持ち込まない

`package.json` は無い。`functions/*.ts` は wrangler 内蔵の esbuild がそのままトランスパイルする。
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

`flake.nix` の `siteDrv` は 2 つの失敗経路を持つ（どちらも動作確認済み）:

1. `index.html` に未置換の `@key@` が残っていたらビルド失敗
   → `lib/render.nix` の `htmlVars` にキーを足す
2. `site.nix` の `pgp.publishWkd = true` なのに `hu/<hash>` が無ければビルド失敗
   → `nix run .#wkd-export` で書き出す

`publishWkd = false` の間は `hu/` を配信しない。空ファイルを置くと WKD クライアントが壊れるため。

### security.txt の Expires

RFC 9116 で必須かつ未来日。`site.nix` の `securityTxt.expires` を毎年更新する。
Nix は純粋で現在時刻を扱えないので、失効検査は CI（`.github/workflows/deploy.yml`）が行い、
残り 30 日を切ると警告を出す。

## 鍵・ID の状態

`site.nix` と `static/keys` は `<...>` のプレースホルダのまま。
差し替え手順（SSH / GPG+WKD / Nostr hex）は `README.md` にある。

`dev@nishimin.net` の WKD ハッシュは `gudx35f8m3ns6jx87gkuda1nmtsb53nd`
（`gpg-wks-client --print-wkd-hash` で照合済み）。
