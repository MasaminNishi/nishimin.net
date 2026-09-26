# site.nix の attrset から、配信する各ファイルの中身（文字列）を組み立てる純関数群。
# ここが唯一の整形ロジック。ANSI 版とプレーン版は同じ行データから生成するので
# 内容が二重管理にならない。
{ lib, site }:

let
  inherit (builtins) stringLength concatStringsSep toJSON;

  # Nix の文字列リテラルには \e が無いので JSON 経由で ESC (U+001B) を得る。
  esc = builtins.fromJSON ''"\u001b"'';

  # PGP の一括スイッチ。false の間は鍵が無いので、フィンガープリントや
  # gpg --locate-keys のコマンド例といった「使えない情報」を一切出さない。
  inherit (site.pgp) publishWkd;

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
    wkd = "/.well-known/openpgpkey/hu/${site.pgp.wkdHash}";
  };

  # 絶対 URL。コピペして使うコマンド例と curl 出力で使う。
  # site.url は dev ビルドでは http://localhost:8788 に差し替わる。
  urls = lib.mapAttrs (_: p: "${site.url}${p}") paths;

  # curl で叩いてそのまま使えるコマンド例。HTML と ANSI の両方で同じ文字列を使う。
  commands = {
    ssh = "curl -L ${urls.keys} >> ~/.ssh/authorized_keys";
    gpg = "gpg --locate-keys ${site.email}";
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

      # 見出し行。
      section = title: "  ${heading title}";

      # ラベル + 値の行。ラベルは 13 桁に揃える。
      row = label: value: "    ${dim (padTo 13 label)}${value}";

      linkRows = map (l: row l.label (cyan l.url)) site.links;

      pgpRows = lib.optionals publishWkd [
        (row "gpg (WKD)" (green commands.gpg))
        (row "fingerprint" site.pgp.fingerprint)
      ];

      lines = [
        ""
        (green (lib.removeSuffix "\n" site.banner))
        ""
        "  ${bold site.handle} ${dim "-"} ${site.tagline}"
        "  ${dim "${site.realName} · ${site.location} · ${site.email}"}"
        ""
        (section "LINKS")
      ]
      ++ linkRows
      ++ [
        ""
        (section "KEYS")
        (row "ssh" (green commands.ssh))
      ]
      ++ pgpRows
      ++ [
        ""
        (section "IDENTITY")
        (row "nostr" "_@${site.domain}  ${dim urls.nostrJson}")
        ""
        (section "MISC")
        (row "security" (cyan urls.securityTxt))
        (row "humans" (cyan urls.humansTxt))
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
    map (
      l: "        <li><a class=\"link\" rel=\"me\" href=\"${x l.url}\">${x l.label}</a></li>"
    ) site.links
  );

  stackHtml = concatStringsSep "\n" (map (s: "        <li>${x s}</li>") site.stack);

  # publishWkd = false のときは空文字列。テンプレート側の @pgpBlock@ が消える。
  pgpHtml =
    if publishWkd then
      ''
        <h3>OpenPGP</h3>
        <pre><code>${x commands.gpg}</code></pre>
        <dl>
          <dt>Fingerprint</dt>
          <dd><code>${x site.pgp.fingerprint}</code></dd>
          <dt>WKD</dt>
          <dd><a href="${x urls.wkd}">${x urls.wkd}</a></dd>
        </dl>''
    else
      "";

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
    pgpBlock = pgpHtml;
    nostrHex = x site.nostr.pubkeyHex;
    # href は相対。ローカルでも本番でもそのままリンクが機能する。
    securityTxtHref = x paths.securityTxt;
    humansTxtHref = x paths.humansTxt;
    nostrJsonHref = x paths.nostrJson;
    cmdSsh = x commands.ssh;
  };

  # @key@ を一括置換する。attrNames / attrValues は同じ順序で返るので対応が崩れない。
  renderTemplate =
    template: vars:
    builtins.replaceStrings (map (k: "@${k}@") (
      builtins.attrNames vars
    )) (builtins.attrValues vars) template;

in
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
  # Encryption は任意なので、鍵が無い間は行ごと出さない。
  securityTxt = ''
    Contact: mailto:${site.email}
    Expires: ${site.securityTxt.expires}
  ''
  + lib.optionalString publishWkd ''
    Encryption: ${urls.wkd}
    Encryption: openpgp4fpr:${lib.toLower site.pgp.fingerprint}
  ''
  + ''
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
      Standards: HTML5, CSS3, RFC 9116, NIP-05${lib.optionalString publishWkd ", OpenPGP WKD"}
      Components: なし（依存ゼロ・JavaScript なし）
      Software: ${concatStringsSep ", " site.stack}
  '';

  # /touch の遷移先許可リスト。オープンリダイレクタにしないため、
  # 任意 URL ではなくこの id -> url の対応表だけを受け付ける。
  linksJson = toJSON {
    default = site.touch.default;
    targets = lib.listToAttrs (
      map (l: {
        name = l.id;
        value = l.url;
      }) site.links
    );
  };
}
