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

      # プロフィールの単一ソース。
      site = import ./site.nix;

      # 配信する静的ツリーを作る。static/ をそのままコピーし、site.nix 由来の
      # 生成物を上から置く。
      #
      # url を差し替えられるようにしてあるのは、ローカル確認のため。
      # 本番 URL が埋まったままだと curl 出力やコピペ用コマンドが本番を指してしまい
      # 動作確認しづらい（HTML の href は相対なのでどちらでも動く）。
      mkSite =
        { name, url }:
        let
          rendered = import ./lib/render.nix {
            inherit lib;
            site = site // {
              inherit url;
            };
          };
        in
        pkgs.runCommand name
          {
            inherit (rendered)
              indexHtml
              ansiTxt
              plainTxt
              nostrJson
              securityTxt
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

      # 本番用。site.nix の url をそのまま使う。
      siteDrv = mkSite {
        name = "nishimin-net-site";
        inherit (site) url;
      };

      # ローカル確認用。nix run .#dev がこちらを result-dev に出す。
      # 出力先を本番用と分けてあるので、dev のあとに手で wrangler pages deploy しても
      # localhost 入りの成果物が本番に上がることはない。
      siteDevDrv = mkSite {
        name = "nishimin-net-site-dev";
        url = "http://localhost:8788";
      };

      # writeShellApplication をそのまま nix run できる app にする薄いラッパ。
      mkApp = name: description: drv: {
        type = "app";
        program = "${drv}/bin/${name}";
        meta.description = description;
      };

      # betterleaks pre-commit hook の実体。.githooks/pre-commit から
      # `nix run .#betterleaks-pre-commit` で呼ばれ、毎回 flake 定義の最新版が動く。
      #
      # --staged が staged 差分を見る正しいフラグ。--pre-commit（unstaged の git diff を
      # 見る）を併記すると後者が勝ち、git add 済みの内容が 0 バイト扱いになって
      # 素通りする。実測で確認済みなので --pre-commit を足さないこと。
      betterleaks-pre-commit = pkgs.writeShellApplication {
        name = "betterleaks-pre-commit";
        runtimeInputs = [ pkgs.betterleaks ];
        text = "exec betterleaks git --staged --redact --no-banner";
      };
    in
    {
      formatter.${system} = pkgs.nixfmt;

      packages.${system} = {
        default = siteDrv;
        site = siteDrv;
        site-dev = siteDevDrv;
        inherit betterleaks-pre-commit;
      };

      checks.${system} = {
        # サイトがビルドできること（置換漏れ・WKD 整合性のチェックを含む）。
        site = siteDrv;

        # ローカル確認用のビルドも壊れていないこと。これが無いと site-dev が
        # 壊れても CI は緑のままで、次に nix run .#dev したときに初めて気づく。
        site-dev = siteDevDrv;

        # functions/*.ts の型チェック。wrangler の esbuild は型を見ずに
        # トランスパイルするので、ここで見ないと誰も見ない。
        typescript = pkgs.runCommand "typescript" { nativeBuildInputs = [ pkgs.typescript ]; } ''
          export HOME="$TMPDIR"
          tsc --noEmit --project ${self}/tsconfig.json
          touch $out
        '';

        nixfmt = pkgs.runCommand "nixfmt" { nativeBuildInputs = [ pkgs.nixfmt ]; } ''
          find ${self} -name '*.nix' -exec nixfmt --check {} +
          touch $out
        '';

        statix = pkgs.runCommand "statix" { nativeBuildInputs = [ pkgs.statix ]; } ''
          statix check ${self}
          touch $out
        '';

        # シークレットスキャン。allowlist は置かない（公開鍵は既定ルールに引っかからず、
        # paths 指定の allowlist はそのファイルをスキャン対象から丸ごと外してしまうため）。
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
              # 本番 URL ではなく localhost:8788 が埋まった成果物を使う。
              nix build .#site-dev --out-link result-dev
              exec wrangler pages dev result-dev --port 8788 "$@"
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
