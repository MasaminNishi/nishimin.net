---
name: commit
description: 規約に沿った日本語コミットメッセージでコミットする
user-invocable: true
---

# Git コミット

変更内容を分析し、規約に沿った日本語コミットメッセージで Git コミットを作成する。

## コミットメッセージフォーマット

```
<Type>: <Subject>

<Description>

Co-Authored-By: <実行中のモデル名> <noreply@anthropic.com>
```

- `Co-Authored-By` のモデル名は実行時に自分のモデル名（例: `Claude Opus 5`）を使う

## Type 一覧

| Type | 用途 |
|------|------|
| `feat` | 公開エンドポイントや挙動の追加・変更・削除 |
| `fix` | 不具合の修正 |
| `content` | `site.nix` の掲載内容（プロフィール・リンク・鍵・識別子）の更新 |
| `style` | 見た目（HTML 構造・CSS）の変更 |
| `refactor` | 表示も挙動も変えない内部整理 |
| `test` | smoke テスト・`flake checks` の追加・修正 |
| `docs` | `README.md` / `CLAUDE.md` の更新 |
| `chore` | flake 基盤・CI・依存・開発用コマンド |

`feat` と `content` の使い分けは「サイトの仕組みを変えたか、載せる情報を変えたか」。
`site.nix` の `links` や `nostr.pubkeyHex` を書き換えただけなら `content`、
`/go` のようなエンドポイントを増減させたなら `feat`。


## バージョン

`site.nix` の `version` がサイトのバージョン。公開物に影響する変更を入れたら
**同じコミットで上げる**。humans.txt・HTML のフッター・curl 出力に出る。

| 変更の性質 | 上げ方 | 例 |
|---|---|---|
| 公開済みの経路を壊す | MAJOR | `/go/<id>` の削除・改名、`/keys` のパス変更、エンドポイントの廃止 |
| 公開物に見える追加・変更 | MINOR | エンドポイント追加、リンク追加、表示の変更、掲載内容の更新 |
| 公開物の見た目も挙動も変わらない修正 | PATCH | 内部整理、壊れていた挙動の修正 |
| 公開物に影響しない | 上げない | `test` / `docs` / `chore` |

MAJOR の判断は**配布済みの媒体を壊すか**で決める。`/go/<id>` は印刷した QR に
焼く前提で、`/keys` は他人の `authorized_keys` に入る。これらのパスを変えると
手元では直せないものが壊れるので MAJOR。

リビジョン（コミットハッシュ）は git から自動で入るので、手で触る必要はない。
作業ツリーが汚れていると `-dirty` が付き、フッターのリンクは張られない。
## Subject のルール

- **基本フォーマット**: `XXのため、YYをZZ` （Why → What の順）
  - XX: 変更の理由（なぜこの変更が必要か）
  - YY: 変更の対象
  - ZZ: 作業内容を漢語の体言止めで表現（作成、修正、追加、削除、変更、移動、統一、導入、整理、分離、etc.）
- **省略形**: 理由が自明な場合は `YYをZZ` でよい
- **例**:
  - `feat: 配布済み媒体の飛び先を変えられるようにするため、/go を追加`
  - `fix: authorized_keys が壊れるのを防ぐため、curl 分岐をルートパスに限定`
  - `content: プロフィールと公開鍵を実データへ差し替え`
  - `style: デザインを別途詰めるため、CSS を剥がしてブラウザ標準の描画に変更`
  - `refactor: ローカル確認をしやすくするため、本番と dev の URL を分離`
  - `test: 回帰を自動で拾うため、エンドポイントのスモークテストを追加`
  - `docs: 判断の経緯を残すため、CLAUDE.md にビルド時ガードを追記`
  - `chore: 生成物を消す nix run .#clean を追加`
- **文字数**: 20〜50文字程度を目安にする

## flake.lock 特例

`flake.lock` のみが変更対象の場合、Type・Subject は固定とする:

```
Bump flake.lock
```

## Description のルール

- **積極的に書く**。Subject だけでは伝わらない背景・判断・経緯を補足する
- 以下の観点で記載する:
  - **Why（なぜ）**: 変更の動機・背景
  - **What（何を）**: 変更の概要。複数ファイルにまたがる場合は箇条書きで整理する
  - **How（どのように）**: 採用したアプローチや、却下した代替案があれば記載する
- 実測で確かめたこと（壊して発火を確認した、など）があれば書く。
  このリポジトリは「気づけない壊れ方」を潰すことに重きを置いているため、
  検証したという事実そのものが次に読む人の判断材料になる
- 日本語で書く
- 空行で Subject と区切る

## 手順

### 1. 変更内容の確認

以下を並列で実行する:

- `git status`（未追跡ファイルの確認）
- `git diff` および `git diff --staged`（差分の確認）
- `git log --oneline -5`（直近のコミットメッセージの確認）

### 2. 新規ファイルの git add

新規作成したファイルがある場合、`nix run .#fix` 実行前に `git add` しておく。
flake は git の追跡下にないファイルを見ないため、未追跡のままでは
フォーマッタもチェックも対象外になる。

### 3. フォーマット・lint の修正

```bash
nix run .#fix
```

### 4. フォーマット後の差分再確認

`nix run .#fix` がフォーマッタの差分を生む場合がある。実行後に再度確認する:

```bash
git diff
```

### 5. チェックを通す

```bash
nix flake check
```

`site` / `site-dev` のビルド、`typescript`（`tsc --noEmit`）、`apps-build`（app の
shellcheck）、`nixfmt` / `statix`、`betterleaks` が走る。型エラーや app の
シェルスクリプト違反はここで拾う。

### 6. 挙動を変えた場合はエンドポイントを検証する

`functions/`、`lib/render.nix`、`static/_headers`、`site.nix` の `links` などを
触った場合は実際に叩いて確かめる:

```bash
nix run .#test
```

毎コミットには課さない（wrangler 起動のぶん重い）。CI はデプロイ前に必ず実行する。

### 7. バージョンの確認

公開物に影響する変更なら、同じコミットで `site.nix` の `version` を上げる。
判断基準は上の「バージョン」節。影響しない変更（test / docs / chore）なら触らない。

### 8. コミットメッセージの作成

変更内容を分析し、上記フォーマットに従ってコミットメッセージを作成する。

- Type を判定する
- Subject を「XXのため、YYをZZ」の形式で書く
- Description に背景・変更概要・アプローチを記載する

### 9. ステージングとコミット

- 関連ファイルを `git add` でステージングする（認証情報は除外）
- HEREDOC 形式でコミットする:

```bash
git commit -m "$(cat <<'EOF'
<Type>: <Subject>

<Description>

Co-Authored-By: <実行中のモデル名> <noreply@anthropic.com>
EOF
)"
```

### 10. 確認

`git status` で結果を確認する。

## 注意事項

- コミットメッセージはすべて日本語で書く（Type・`Bump flake.lock` は英語）
- `git add -A` は使わず、関連ファイルを明示的に指定する
- pre-commit hook（betterleaks）が失敗した場合は原因を修正し、
  新しいコミットを作成する（`--amend` しない）
- push はしない（ユーザーに委ねる）
- 意味の異なる変更は分けてコミットする。1 コミット 1 目的
