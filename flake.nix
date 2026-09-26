{
  description = "nishimin.net — 技術者向けアイデンティティハブ & エッジエンドポイント";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs =
    { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      inherit (pkgs) lib;

      # プロフィールの単一ソースと、そこから各ファイルを組み立てる純関数群。
      site = import ./site.nix;
      rendered = import ./lib/render.nix { inherit lib site; };

      # 配信する静的ツリー。static/ をそのままコピーし、site.nix 由来の
      # 生成物を上から置く。wrangler.jsonc の pages_build_output_dir はこれを指す。
      siteDrv =
        pkgs.runCommand "nishimin-net-site"
          {
            inherit (rendered)
              indexHtml
              ansiTxt
              plainTxt
              nostrJson
              securityTxt
              atprotoDid
              humansTxt
              linksJson
              ;
            # 複数行の内容をシェルのクォートを介さずファイルとして渡す。
            passAsFile = [
              "indexHtml"
              "ansiTxt"
              "plainTxt"
              "nostrJson"
              "securityTxt"
              "atprotoDid"
              "humansTxt"
              "linksJson"
            ];
          }
          ''
            mkdir -p "$out/.well-known"
            cp -r ${./static}/. "$out/"
            chmod -R u+w "$out"

            cp "$indexHtmlPath"   "$out/index.html"
            cp "$ansiTxtPath"     "$out/ansi.txt"
            cp "$plainTxtPath"    "$out/plain.txt"
            cp "$humansTxtPath"   "$out/humans.txt"
            cp "$linksJsonPath"   "$out/links.json"
            cp "$nostrJsonPath"   "$out/.well-known/nostr.json"
            cp "$securityTxtPath" "$out/.well-known/security.txt"
            cp "$atprotoDidPath"  "$out/.well-known/atproto-did"

            # テンプレートの置換漏れはここで落とす。
            if grep -nE '@[a-z][a-zA-Z0-9_]*@' "$out/index.html"; then
              echo "error: index.html に未置換のプレースホルダが残っています" >&2
              echo "  lib/render.nix の htmlVars に対応するキーを足してください" >&2
              exit 1
            fi

            # WKD の hu は GPG 公開鍵のバイナリ。空ファイルを配るとクライアントが壊れるので、
            # 鍵を用意できていない間は配信しない。
            hu="$out/.well-known/openpgpkey/hu/${site.pgp.wkdHash}"
            ${
              if site.pgp.publishWkd then
                ''
                  if [ ! -s "$hu" ]; then
                    echo "error: pgp.publishWkd = true ですが $hu がありません" >&2
                    echo "  nix run .#wkd-export で書き出してから再ビルドしてください" >&2
                    exit 1
                  fi
                ''
              else
                ''
                  rm -rf "$out/.well-known/openpgpkey/hu"
                  echo "note: pgp.publishWkd = false のため WKD の公開鍵は配信しません"
                ''
            }
          '';

      # writeShellApplication をそのまま nix run できる app にする薄いラッパ。
      mkApp = name: description: drv: {
        type = "app";
        program = "${drv}/bin/${name}";
        meta.description = description;
      };

      # betterleaks pre-commit hook の実体。.githooks/pre-commit から
      # `nix run .#betterleaks-pre-commit` で呼ばれ、毎回 flake 定義の最新版が動く。
      betterleaks-pre-commit = pkgs.writeShellApplication {
        name = "betterleaks-pre-commit";
        runtimeInputs = [ pkgs.betterleaks ];
        text = "exec betterleaks git --pre-commit --redact --staged --no-banner";
      };
    in
    {
      formatter.${system} = pkgs.nixfmt;

      packages.${system} = {
        default = siteDrv;
        site = siteDrv;
        inherit betterleaks-pre-commit;
      };

      checks.${system} = {
        # サイトがビルドできること（置換漏れ・WKD 整合性のチェックを含む）。
        site = siteDrv;

        nixfmt = pkgs.runCommand "nixfmt" { nativeBuildInputs = [ pkgs.nixfmt ]; } ''
          find ${self} -name '*.nix' -exec nixfmt --check {} +
          touch $out
        '';

        statix = pkgs.runCommand "statix" { nativeBuildInputs = [ pkgs.statix ]; } ''
          statix check ${self}
          touch $out
        '';

        # シークレットスキャン。公開鍵は意図的にコミットするので .betterleaks.toml で除外している。
        betterleaks = pkgs.runCommand "betterleaks" { nativeBuildInputs = [ pkgs.betterleaks ]; } ''
          betterleaks dir ${self} --no-banner --no-color --redact -l error
          touch $out
        '';
      };

      apps.${system} = {
        # nix run .#dev — ビルドしてローカルエミュレータを :8788 で起動
        dev = mkApp "dev" "ビルドしてローカルエミュレータを http://localhost:8788 で起動する" (
          pkgs.writeShellApplication {
            name = "dev";
            runtimeInputs = [
              pkgs.wrangler
              pkgs.git
            ];
            text = ''
              cd "$(git rev-parse --show-toplevel)"
              export WRANGLER_SEND_METRICS=false
              nix build .#site --out-link result
              exec wrangler pages dev --port 8788 "$@"
            '';
          }
        );

        # nix run .#deploy — 本番へダイレクトアップロード
        # （Cloudflare 側のビルド環境に Nix は無いので Git 連携ビルドは使わない）
        deploy = mkApp "deploy" "nix build の成果物を Cloudflare Pages へダイレクトアップロードする" (
          pkgs.writeShellApplication {
            name = "deploy";
            runtimeInputs = [
              pkgs.wrangler
              pkgs.git
            ];
            text = ''
              cd "$(git rev-parse --show-toplevel)"
              export WRANGLER_SEND_METRICS=false
              nix build .#site --out-link result
              # プロジェクト名は wrangler.jsonc の name が正。ここでは重複して指定しない。
              exec wrangler pages deploy "$@"
            '';
          }
        );

        # nix run .#fix — フォーマット + lint 自動修正（コミット前に実行する）
        fix = mkApp "fix" "nixfmt と statix で自動整形・自動修正する" (
          pkgs.writeShellApplication {
            name = "fix";
            runtimeInputs = [
              pkgs.nixfmt
              pkgs.statix
              pkgs.git
            ];
            text = ''
              cd "$(git rev-parse --show-toplevel)"
              find . -name '*.nix' -not -path './.git/*' -exec nixfmt {} +
              statix fix .
              echo "nixfmt + statix 完了"
            '';
          }
        );

        # nix run .#wkd-export — GPG 公開鍵を WKD の hu ファイルとして書き出す
        wkd-export = mkApp "wkd-export" "GPG 公開鍵を WKD の hu ファイルへ書き出す" (
          pkgs.writeShellApplication {
            name = "wkd-export";
            runtimeInputs = [
              pkgs.gnupg
              pkgs.git
            ];
            text = ''
              cd "$(git rev-parse --show-toplevel)"
              email="${site.email}"
              expected="${site.pgp.wkdHash}"

              actual="$(gpg-wks-client --print-wkd-hash "$email" | awk '{print $1}')"
              if [ "$actual" != "$expected" ]; then
                echo "error: WKD ハッシュが site.nix と一致しません" >&2
                echo "  site.nix: $expected" >&2
                echo "  実際:     $actual" >&2
                exit 1
              fi

              dest="static/.well-known/openpgpkey/hu/$expected"
              mkdir -p "$(dirname "$dest")"
              gpg --export --no-armor "$email" > "$dest"

              if [ ! -s "$dest" ]; then
                echo "error: $email の公開鍵を export できませんでした" >&2
                rm -f "$dest"
                exit 1
              fi

              echo "書き出しました: $dest"
              echo "site.nix の pgp.publishWkd を true にして再ビルドしてください"
            '';
          }
        );

        # nix run .#install-hooks — betterleaks pre-commit hook を有効化（clone 後に一度だけ）
        install-hooks = mkApp "install-hooks" "betterleaks の pre-commit hook を有効化する" (
          pkgs.writeShellApplication {
            name = "install-hooks";
            runtimeInputs = [ pkgs.git ];
            text = ''
              cd "$(git rev-parse --show-toplevel)"
              git config core.hooksPath .githooks
              echo "core.hooksPath -> .githooks (betterleaks pre-commit hook 有効)"
            '';
          }
        );

        betterleaks-pre-commit =
          mkApp "betterleaks-pre-commit" "staged 差分をシークレットスキャンする（hook 本体）"
            betterleaks-pre-commit;
      };

      devShells.${system}.default = pkgs.mkShell {
        packages = with pkgs; [
          wrangler # Pages のローカルエミュレータ / デプロイ
          nodejs_22 # wrangler のデバッグ用
          jq
          curl
          gnupg # gpg-wks-client --print-wkd-hash
          age # age-keygen
          openssh # ssh-keygen
          figlet # site.nix の banner の再生成
          nixfmt
          statix
        ];

        # wrangler の対話的なテレメトリ確認を抑止する。
        WRANGLER_SEND_METRICS = "false";

        shellHook = ''
          echo ""
          echo "  nishimin.net — 開発環境"
          echo ""
          echo "    nix run .#dev          ビルドして http://localhost:8788 で起動"
          echo "    nix run .#deploy       本番へダイレクトアップロード"
          echo "    nix run .#fix          nixfmt + statix 自動修正（コミット前）"
          echo "    nix flake check        フォーマット / lint / 秘密スキャン / ビルド"
          echo "    nix run .#wkd-export   GPG 公開鍵を WKD の hu へ書き出す"
          echo "    nix run .#install-hooks  pre-commit hook を有効化（clone 後に一度）"
          echo ""
          echo "  プロフィールの編集は site.nix の 1 箇所だけ。"
          echo ""
        '';
      };
    };
}
