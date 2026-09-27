# site.nix の attrset から、配信する各ファイルの中身（文字列）を組み立てる純関数群。
# ここが唯一の整形ロジック。ANSI 版とプレーン版は同じ行データから生成するので
# 内容が二重管理にならない。
{ lib, site }:

let
  inherit (builtins) stringLength concatStringsSep toJSON;

  # Nix の文字列リテラルには \e が無いので JSON 経由で ESC (U+001B) を得る。
  esc = builtins.fromJSON ''"\u001b"'';

  # 右側に空白を足して幅を揃える。ANSI 付与前の素の文字列に対して使うこと
  # （エスケープシーケンスを桁数に数えてしまうため）。
  padTo =
    n: s:
    let
      deficit = n - stringLength s;
    in
    s + lib.concatStrings (lib.genList (_: " ") (if deficit > 0 then deficit else 0));

  # サイト内のパス。HTML の href はこちらを使う。相対にしておくと
  # ローカル (localhost:8788) でも本番でもリンクがそのまま機能する。
  paths = {
    keys = "/keys";
    securityTxt = "/.well-known/security.txt";
    humansTxt = "/humans.txt";
    nostrJson = "/.well-known/nostr.json";
    nostrPicture = site.nostr.picturePath;
  };

  # 絶対 URL。コピペして使うコマンド例と curl 出力で使う。
  # site.url は dev ビルドでは http://localhost:8788 に差し替わる。
  urls = lib.mapAttrs (_: p: "${site.url}${p}") paths;

  # curl で叩いてそのまま使えるコマンド例。HTML と ANSI の両方で同じ文字列を使う。
  commands = {
    ssh = "curl -L ${urls.keys} >> ~/.ssh/authorized_keys";
  };

  # ---------------------------------------------------------------------------
  # curl 向けプロフィール（ANSI / プレーン共通の組み立て）
  # ---------------------------------------------------------------------------

  mkProfile =
    { color }:
    let
      sgr = code: s: if color then "${esc}[${code}m${s}${esc}[0m" else s;

      bold = sgr "1";
      heading = sgr "1;33";
      dim = sgr "2";
      cyan = sgr "36";
      green = sgr "32";

      # 各セクションをまずデータとして組む。ここから最長ラベルを測るので、
      # 行を足してもラベル幅が自動で追随する（桁数を決め打つと、長いラベルを
      # 入れたときに詰め物が入らず値と密着して黙って崩れる）。
      sections = [
        {
          title = "LINKS";
          rows = map (l: {
            inherit (l) label;
            value = cyan l.url;
          }) site.links;
        }
        {
          title = "KEYS";
          rows = [
            {
              label = "ssh";
              value = green commands.ssh;
            }
          ];
        }
        {
          title = "IDENTITY";
          rows = [
            {
              label = "nostr";
              value = "_@${site.domain}  ${dim urls.nostrJson}";
            }
            {
              label = "picture";
              value = cyan urls.nostrPicture;
            }
          ];
        }
        {
          title = "MISC";
          rows = [
            {
              label = "security";
              value = cyan urls.securityTxt;
            }
            {
              label = "humans";
              value = cyan urls.humansTxt;
            }
          ];
        }
      ];

      # 最長ラベル + 2 桁。値との間に必ず 2 つ以上の空白が入る。
      labelWidth =
        2 + lib.foldl' lib.max 0 (map (r: stringLength r.label) (lib.concatMap (s: s.rows) sections));

      renderSection =
        s:
        [
          ""
          "  ${heading s.title}"
        ]
        ++ map (r: "    ${dim (padTo labelWidth r.label)}${r.value}") s.rows;

      lines = [
        ""
        (green (lib.removeSuffix "\n" site.banner))
        ""
        "  ${bold site.handle} ${dim "-"} ${site.tagline}"
        "  ${dim "${site.realName} · ${site.location} · ${site.email}"}"
      ]
      ++ lib.concatMap renderSection sections
      ++ [
        ""
        (dim "  ブラウザで開くと HTML が返ります: ${site.url}")
      ]
      ++ lib.optional color (dim "  色を消す: curl '${site.url}/?plain'")
      ++ [ "" ];
    in
    concatStringsSep "\n" lines;

  # ---------------------------------------------------------------------------
  # HTML 断片
  # ---------------------------------------------------------------------------

  # プレースホルダ値は <HANDLE> のように山括弧を含むので、必ずエスケープする。
  x = lib.escapeXML;

  linksHtml = concatStringsSep "\n" (
    map (l: "        <li><a rel=\"me\" href=\"${x l.url}\">${x l.label}</a></li>") site.links
  );

  stackHtml = concatStringsSep "\n" (map (s: "        <li>${x s}</li>") site.stack);

  htmlVars = {
    handle = x site.handle;
    realName = x site.realName;
    tagline = x site.tagline;
    location = x site.location;
    email = x site.email;
    domain = x site.domain;
    url = x site.url;
    links = linksHtml;
    stack = stackHtml;
    nostrHex = x site.nostr.pubkeyHex;
    # href は相対。ローカルでも本番でもそのままリンクが機能する。
    securityTxtHref = x paths.securityTxt;
    humansTxtHref = x paths.humansTxt;
    nostrJsonHref = x paths.nostrJson;
    nostrPictureHref = x paths.nostrPicture;
    cmdSsh = x commands.ssh;
  };

  # @key@ を一括置換する。attrNames / attrValues は同じ順序で返るので対応が崩れない。
  renderTemplate =
    template: vars:
    builtins.replaceStrings (map (k: "@${k}@") (
      builtins.attrNames vars
    )) (builtins.attrValues vars) template;

  # links[].id は /go/<id> の許可リストのキーになる。lib.listToAttrs は先勝ちなので、
  # 重複すると後の要素が go.json から黙って消える。画面と curl 出力には両方出るため
  # 見た目では気づけないので、ここで落とす。
  linkIds = map (l: l.id) site.links;
  duplicateIds = lib.unique (lib.filter (id: lib.count (i: i == id) linkIds > 1) linkIds);

  # home は自サイト自身を指す組み込みの id。links 側で同じ id を使うと
  # どちらが勝つか分かりにくいので予約する。
  reservedIds = [ "home" ];
  clashingIds = lib.intersectLists linkIds reservedIds;

in
assert lib.assertMsg (duplicateIds == [ ]) ''
  site.nix の links[].id が重複しています: ${concatStringsSep ", " duplicateIds}
  /go/<id> の遷移先が先勝ちで上書きされ、後ろの定義は無視されます。
'';
assert lib.assertMsg (clashingIds == [ ]) ''
  site.nix の links[].id に予約語が使われています: ${concatStringsSep ", " clashingIds}
  これらは /go/<id> の組み込みの遷移先なので、links 側では使えません。
'';
{
  ansiTxt = mkProfile { color = true; };
  plainTxt = mkProfile { color = false; };

  indexHtml = renderTemplate (builtins.readFile ../templates/index.html.in) htmlVars;

  # NIP-05。"_" は「ドメイン自体」を指す予約名。
  nostrJson = ''
    {
      "names": {
        "_": ${toJSON site.nostr.pubkeyHex}
      }
    }
  '';

  # RFC 9116。Expires は必須かつ未来日であること（CI が検査する）。
  securityTxt = ''
    Contact: mailto:${site.email}
    Expires: ${site.securityTxt.expires}
    Preferred-Languages: ${site.securityTxt.preferredLanguages}
    Canonical: ${urls.securityTxt}
  '';

  humansTxt = ''
    /* TEAM */
      Developer: ${site.realName} (${site.handle})
      Site: ${site.url}
      Contact: ${builtins.replaceStrings [ "@" ] [ " [at] " ] site.email}
      Location: ${site.location}

    /* SITE */
      Standards: HTML5, RFC 9116, NIP-05
      Components: なし（依存ゼロ・JavaScript なし）
      Software: ${concatStringsSep ", " site.stack}
  '';

  # /go/<id> の遷移先許可リスト。オープンリダイレクタにしないため、
  # 任意 URL ではなくこの id -> url の対応表だけを受け付ける。
  #
  # home は組み込み。links に入れると表示用のリンク一覧にも出てしまうので、
  # ここでだけ足す（links は curl 出力と HTML のリンク一覧も兼ねている）。
  goJson = toJSON {
    default = site.go.home;
    targets = {
      home = site.go.home;
    }
    // lib.listToAttrs (
      map (l: {
        name = l.id;
        value = l.url;
      }) site.links
    );
  };
}
