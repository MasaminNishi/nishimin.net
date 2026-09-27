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

### 7. コミットメッセージの作成

変更内容を分析し、上記フォーマットに従ってコミットメッセージを作成する。

- Type を判定する
- Subject を「XXのため、YYをZZ」の形式で書く
- Description に背景・変更概要・アプローチを記載する

### 8. ステージングとコミット

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

### 9. 確認

`git status` で結果を確認する。

## 注意事項

- コミットメッセージはすべて日本語で書く（Type・`Bump flake.lock` は英語）
- `git add -A` は使わず、関連ファイルを明示的に指定する
- pre-commit hook（betterleaks）が失敗した場合は原因を修正し、
  新しいコミットを作成する（`--amend` しない）
- push はしない（ユーザーに委ねる）
- 意味の異なる変更は分けてコミットする。1 コミット 1 目的
