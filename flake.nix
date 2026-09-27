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
              goJson
              ;
            # 複数行の内容をシェルのクォートを介さずファイルとして渡す。
            passAsFile = [
              "indexHtml"
              "ansiTxt"
              "plainTxt"
              "nostrJson"
              "securityTxt"
              "humansTxt"
              "goJson"
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
            cp "$goJsonPath"      "$out/go.json"
            cp "$nostrJsonPath"   "$out/.well-known/nostr.json"
            cp "$securityTxtPath" "$out/.well-known/security.txt"

            # テンプレートの置換漏れはここで落とす。
            if grep -nE '@[a-z][a-zA-Z0-9_]*@' "$out/index.html"; then
              echo "error: index.html に未置換のプレースホルダが残っています" >&2
              echo "  lib/render.nix の htmlVars に対応するキーを足してください" >&2
              exit 1
            fi
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

      # エンドポイントの検証。本番にもローカルにも同じものを当てられる。
      # 期待値は site.nix から生成しているので、リンクを増やせば検査も増える。
      smokeApp = pkgs.writeShellApplication {
        name = "smoke";
        runtimeInputs = [
          pkgs.curl
          pkgs.jq
          pkgs.coreutils
          pkgs.gnugrep
          pkgs.gnused
        ];
        text = ''
          base="''${1:-http://localhost:8788}"
          base="''${base%/}"

          failures=0
          ok() { printf '  \033[32mok\033[0m    %s\n' "$1"; }
          ng() {
            printf '  \033[31mFAIL\033[0m  %s\n' "$1"
            failures=$((failures + 1))
          }

          # 壊れたサイトに当てたときに set -e で途中終了しないよう、
          # 失敗しても値を返して検査を続けさせる（診断情報を残すため）。
          status_of() { curl -sS -o /dev/null -w '%{http_code}' --max-time 20 "$@" || true; }
          headers_of() { curl -sSI --max-time 20 "$@" || true; }
          body_of() { curl -sS --max-time 20 "$@" || true; }

          esc="$(printf '\033')"
          has_ansi() { grep -qF "''${esc}["; }

          # ヘッダが無いときに grep が 1 を返し、pipefail で途中終了してしまうので
          # 空文字を返させる。壊れたサイトでも最後まで検査を続けるため。
          header_value() {
            headers_of "$1" | grep -i "^$2:" | cut -d: -f2- | sed 's/^ *//' | tr -d '\r' || true
          }

          expect_status() {
            got="$(status_of "$base$1")"
            if [ "$got" = "$2" ]; then ok "$1 -> $2"; else ng "$1 -> $got（期待 $2）"; fi
          }

          expect_redirect() {
            st="$(status_of "$base$1")"
            loc="$(header_value "$base$1" location)"
            if [ "$st" = "302" ] && [ "$loc" = "$2" ]; then
              ok "$1 -> 302 $2"
            else
              ng "$1 -> $st $loc（期待 302 $2）"
            fi
          }

          echo "smoke: $base"
          echo

          # --- ルートの出し分け ---
          ct="$(header_value "$base/" content-type)"
          case "$ct" in
            *text/plain*) ok "/ (curl) は text/plain" ;;
            *) ng "/ (curl) の Content-Type が $ct" ;;
          esac

          if body_of "$base/" | has_ansi; then
            ok "/ (curl) に ANSI がある"
          else
            ng "/ (curl) に ANSI が無い"
          fi

          if body_of "$base/?plain" | has_ansi; then
            ng "/?plain に ANSI が残っている"
          else
            ok "/?plain は ANSI なし"
          fi

          ct="$(curl -sSI --max-time 20 -H 'User-Agent: Mozilla/5.0' "$base/" |
            grep -i '^content-type:' | cut -d: -f2- | tr -d '\r')"
          case "$ct" in
            *text/html*) ok "/ (browser) は text/html" ;;
            *) ng "/ (browser) の Content-Type が $ct" ;;
          esac

          case "$(header_value "$base/" vary)" in
            *User-Agent*) ok "/ に Vary: User-Agent" ;;
            *) ng "/ に Vary: User-Agent が無い" ;;
          esac

          # --- 最重要の回帰 ---
          # curl 分岐がルート以外へ漏れると、ここに ASCII アートが返る。
          # そのまま authorized_keys へ追記されるので、これだけは必ず守る。
          keys="$(body_of "$base/keys")"
          if printf '%s' "$keys" | has_ansi; then
            ng "/keys に ANSI が混じっている（middleware の curl 分岐が漏れている）"
          elif printf '%s\n' "$keys" | grep -q '^ssh-'; then
            ok "/keys は SSH 公開鍵（curl 分岐は漏れていない）"
          else
            ng "/keys が SSH 公開鍵ではない"
          fi

          # --- 識別子 ---
          case "$(header_value "$base/.well-known/nostr.json" access-control-allow-origin)" in
            "*") ok "nostr.json に CORS *" ;;
            *) ng "nostr.json に CORS * が無い" ;;
          esac

          hex="$(body_of "$base/.well-known/nostr.json" | jq -r '.names._ // empty' 2>/dev/null || true)"
          if [ "$hex" = "${site.nostr.pubkeyHex}" ]; then
            ok "nostr.json の hex が site.nix と一致"
          else
            ng "nostr.json の hex が不一致: $hex"
          fi

          exp="$(body_of "$base/.well-known/security.txt" | sed -n 's/^Expires:[[:space:]]*//p')"
          exp_epoch="$(date -u -d "$exp" +%s 2>/dev/null || true)"
          now_epoch="$(date -u +%s)"
          if [ -z "$exp" ]; then
            ng "security.txt に Expires が無い（RFC 9116 で必須）"
          elif [ -z "$exp_epoch" ]; then
            ng "security.txt の Expires を日付として解釈できない: $exp"
          elif [ "$exp_epoch" -le "$now_epoch" ]; then
            ng "security.txt の Expires ($exp) が失効している"
          else
            ok "security.txt の Expires は有効（残り $(( (exp_epoch - now_epoch) / 86400 )) 日）"
          fi

          expect_status /humans.txt 200
          expect_status /robots.txt 200

          # --- /go の遷移先。site.nix の links から生成している ---
          expect_redirect /go "$base/"
          expect_redirect /go/home "$base/"
          ${lib.concatMapStringsSep "\n          " (l: "expect_redirect /go/${l.id} \"${l.url}\"") site.links}
          expect_redirect /go/__unknown__ "$base/"

          case "$(header_value "$base/go/https://evil.example.com" location)" in
            *evil.example.com*) ng "オープンリダイレクタになっている" ;;
            *) ok "/go は任意 URL を受け付けない" ;;
          esac

          expect_status /__nonexistent__ 404

          # --- セキュリティヘッダ。静的アセットにも Function の応答にも乗ること ---
          for path in / /go /keys; do
            n="$(headers_of "$base$path" | grep -ciE '^(x-frame-options|x-content-type-options|referrer-policy|permissions-policy|strict-transport-security|content-security-policy):' || true)"
            if [ "$n" -eq 6 ]; then
              ok "$path にセキュリティヘッダ 6 本"
            else
              ng "$path のセキュリティヘッダが $n/6 本"
            fi
          done

          echo
          if [ "$failures" -eq 0 ]; then
            echo "すべて通過"
          else
            echo "$failures 件失敗" >&2
            exit 1
          fi
        '';
      };

      # 本番用の成果物をローカルに立てて smoke を回す。deploy からも呼ぶ。
      testApp = pkgs.writeShellApplication {
        name = "test";
        runtimeInputs = [
          pkgs.wrangler
          pkgs.git
          pkgs.curl
          pkgs.coreutils
        ];
        text = ''
          cd "$(git rev-parse --show-toplevel)"
          export WRANGLER_SEND_METRICS=false

          # 開発用の 8788 とぶつからないよう別ポートを使う。
          port=8799
          if curl -s -o /dev/null --max-time 1 "http://localhost:$port/" 2>/dev/null; then
            echo "error: ポート $port が既に使われています" >&2
            exit 1
          fi

          # 実際にデプロイするのと同じ成果物を検証する。
          nix build .#site --out-link result

          log="$(mktemp)"
          pid=""
          cleanup() {
            if [ -n "$pid" ]; then kill "$pid" 2>/dev/null || true; fi
            rm -f "$log"
          }
          trap cleanup EXIT

          wrangler pages dev result --port "$port" >"$log" 2>&1 &
          pid=$!

          for _ in $(seq 1 60); do
            if curl -s -o /dev/null --max-time 1 "http://localhost:$port/"; then break; fi
            sleep 1
          done

          if ! curl -s -o /dev/null --max-time 2 "http://localhost:$port/"; then
            echo "error: wrangler が起動しませんでした" >&2
            cat "$log" >&2
            exit 1
          fi

          "${smokeApp}/bin/smoke" "http://localhost:$port"
        '';
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
        # サイトがビルドできること（テンプレートの置換漏れチェックを含む）。
        site = siteDrv;

        # apps のシェルスクリプトが実際にビルドできること。
        # writeShellApplication は shellcheck を通すので、構文ミスや危うい書き方を
        # ここで拾える。nix flake check は apps の評価しかしないため、これが無いと
        # スクリプトが壊れていても緑のまま通ってしまう（実際に一度通してしまった）。
        apps-build = pkgs.runCommand "apps-build" { } ''
          ${lib.concatMapStringsSep "\n" (app: "test -x ${app.program}") (lib.attrValues self.apps.${system})}
          touch $out
        '';

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

        # nix run .#smoke -- <url> — 任意の URL に対してエンドポイントを検証する
        # （サーバは自分で起動しておくこと。既定は http://localhost:8788）
        smoke = mkApp "smoke" "エンドポイントを検証する（既定 http://localhost:8788）" smokeApp;

        # nix run .#test — ローカルにサーバを立てて smoke を回す
        test = mkApp "test" "ローカルにサーバを立てて smoke を回す" testApp;

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
        # nix run .#deploy — 検証してから本番へダイレクトアップロードし、結果をまた検証する
        # （Cloudflare 側のビルド環境に Nix は無いので Git 連携ビルドは使わない）
        deploy = mkApp "deploy" "検証してから Cloudflare Pages へダイレクトアップロードする" (
          pkgs.writeShellApplication {
            name = "deploy";
            runtimeInputs = [
              pkgs.wrangler
              pkgs.git
              pkgs.coreutils
              pkgs.gnugrep
            ];
            text = ''
              cd "$(git rev-parse --show-toplevel)"
              export WRANGLER_SEND_METRICS=false

              # 壊れた成果物を本番に上げないよう、アップロードする前に
              # 同じものをローカルに立てて検証する。CI と同じ守り方を手元にも置く。
              # 飛ばしたいときは nix develop --command wrangler pages deploy を直接叩く。
              echo "== アップロード前の検証 =="
              "${testApp}/bin/test"

              echo
              echo "== アップロード =="
              nix build .#site --out-link result

              # デプロイ先の URL を拾って、本番にもう一度 smoke を当てるため出力を保持する。
              out="$(mktemp)"
              trap 'rm -f "$out"' EXIT

              # プロジェクト名は wrangler.jsonc の name が正。ここでは重複して指定しない。
              # set -o pipefail なので wrangler が失敗すればここで止まり、smoke は走らない。
              wrangler pages deploy "$@" 2>&1 | tee "$out"

              url="$(grep -oE 'https://[A-Za-z0-9.-]+\.pages\.dev' "$out" | tail -1 || true)"

              echo
              if [ -z "$url" ]; then
                echo "デプロイ URL を出力から拾えませんでした。手動で検証してください:" >&2
                echo "  nix run .#smoke -- https://<デプロイ先>" >&2
                exit 1
              fi

              # デプロイ直後はエッジの切り替えが終わっておらず、Function が効かない・
              # アセットが 404 になる状態を踏む（実際に CI で 8 件落ちた）。
              # 目印は 2 つ。ルートが text/plain を返すこと（middleware が生きている）と、
              # 静的アセットが引けること。両方揃えば配信は切り替わっている。
              echo "== デプロイ先の反映を待つ: $url =="
              live=0
              for _ in $(seq 1 30); do
                if curl -sSI --max-time 10 "$url/" 2>/dev/null |
                  grep -qi '^content-type:.*text/plain' &&
                  [ "$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "$url/humans.txt")" = "200" ]; then
                  live=1
                  break
                fi
                sleep 2
              done

              if [ "$live" -eq 1 ]; then
                echo "反映を確認しました。"
              else
                echo "warning: 60 秒待っても反映を確認できませんでした。そのまま検証します。" >&2
              fi

              echo
              echo "== デプロイ先の検証: $url =="
              "${smokeApp}/bin/smoke" "$url"
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

        # nix run .#clean — gitignore 対象の生成物を消す
        clean = mkApp "clean" "ビルド生成物と wrangler のローカル状態を削除する" (
          pkgs.writeShellApplication {
            name = "clean";
            runtimeInputs = [
              pkgs.git
              pkgs.coreutils
              pkgs.procps
              pkgs.gnugrep
              pkgs.gnused
            ];
            text = ''
              cd "$(git rev-parse --show-toplevel)"

              # 削除対象は明示列挙する。git clean -X で .gitignore 全体を消す方式にすると、
              # .direnv のような「消しても壊れないが、消すと次回が遅くなるだけ」のキャッシュまで
              # 巻き込む。消し忘れより消しすぎのほうが困るので、こちらを既定にしている。
              shopt -s nullglob
              candidates=(result result-* .wrangler)
              shopt -u nullglob

              # 消さないと決めているもの。下のドリフト検出でも無視する。
              keep=(.direnv)

              targets=()
              for p in "''${candidates[@]}"; do
                if [ -e "$p" ] || [ -L "$p" ]; then
                  # 追跡ファイルを絶対に消さないための保険。列挙を打ち間違えてもここで止まる。
                  if ! git check-ignore -q "$p"; then
                    echo "error: $p は .gitignore の対象ではありません。中止します。" >&2
                    exit 1
                  fi
                  targets+=("$p")
                fi
              done

              # .gitignore にあるのに、消す対象にも残す対象にも入っていないものを知らせる。
              # 明示列挙にした代償（列挙が古くなること）に気づけるようにするため。
              drift="$(
                git clean -Xdn | sed 's/^Would remove //; s#/$##' |
                  grep -vxF -f <(printf '%s\n' "''${candidates[@]}" "''${keep[@]}") || true
              )"

              if [ ''${#targets[@]} -eq 0 ]; then
                echo "消すものはありません。"
              else
                echo "以下を削除します:"
                for p in "''${targets[@]}"; do
                  if [ -L "$p" ]; then
                    printf '  %-12s -> %s\n' "$p" "$(readlink "$p")"
                  else
                    printf '  %-12s %s\n' "$p" "$(du -sh "$p" | cut -f1)"
                  fi
                done
              fi

              for k in "''${keep[@]}"; do
                if [ -e "$k" ]; then
                  echo "  ($k は残します。消しても壊れないが次回が遅くなるだけのキャッシュ)"
                fi
              done

              if [ -n "$drift" ]; then
                echo
                echo "note: .gitignore にありますが clean の対象外です。"
                echo "      消すべきなら flake.nix の candidates に、残すなら keep に足してください。"
                while IFS= read -r line; do echo "  $line"; done <<<"$drift"
              fi

              if [ ''${#targets[@]} -eq 0 ]; then
                exit 0
              fi

              if [ "''${1:-}" = "-n" ] || [ "''${1:-}" = "--dry-run" ]; then
                echo
                echo "(ドライラン。実際には削除していません)"
                exit 0
              fi

              # wrangler が .wrangler を掴んだまま消すと不可解な壊れ方をするので止める。
              #
              # pgrep -f は「コマンドライン全体に文字列が含まれる」で一致するため、
              # この文字列を書いた別のシェルまで拾ってしまう（実際に誤検出した）。
              # argv の要素そのものが cli.js のパスかどうかで判定する。
              running=""
              for cmdline in /proc/[0-9]*/cmdline; do
                pid="''${cmdline#/proc/}"
                pid="''${pid%/cmdline}"
                if tr '\0' '\n' <"$cmdline" 2>/dev/null |
                  grep -qx '.*/wrangler-dist/cli\.js'; then
                  running="$running $pid"
                fi
              done

              if [ -e .wrangler ] && [ -n "$running" ]; then
                echo >&2
                echo "error: wrangler が動いています。止めてから実行してください。" >&2
                for pid in $running; do
                  ps -o args= -p "$pid" 2>/dev/null | cut -c1-100 | sed 's/^/  /' >&2
                done
                exit 1
              fi

              rm -rf "''${targets[@]}"

              echo
              echo "削除しました。result 系は nix build の GC root なので、"
              echo "外れたぶんは nix-collect-garbage で回収できるようになります。"
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
          dnsutils # ドメイン紐付け後の DNS 確認（dig）
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
          echo "    nix run .#clean        生成物を削除（result 系 / .wrangler）"
          echo "    nix flake check        ビルド / 型 / フォーマット / lint / 秘密スキャン"
          echo "    nix run .#install-hooks  pre-commit hook を有効化（clone 後に一度）"
          echo ""
          echo "  プロフィールの編集は site.nix の 1 箇所だけ。"
          echo ""
        '';
      };
    };
}
