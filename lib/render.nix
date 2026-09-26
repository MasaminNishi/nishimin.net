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

  # 各種 URL。site.url からの導出はここに集約する。
  urls = {
    keys = "${site.url}/keys";
    securityTxt = "${site.url}/.well-known/security.txt";
    humansTxt = "${site.url}/humans.txt";
    nostrJson = "${site.url}/.well-known/nostr.json";
    wkd = "${site.url}/.well-known/openpgpkey/hu/${site.pgp.wkdHash}";
  };

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
        (row "gpg (WKD)" (green commands.gpg))
        (row "fingerprint" site.pgp.fingerprint)
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
    pgpFingerprint = x site.pgp.fingerprint;
    wkdUrl = x urls.wkd;
    securityTxtUrl = x urls.securityTxt;
    humansTxtUrl = x urls.humansTxt;
    nostrJsonUrl = x urls.nostrJson;
    cmdSsh = x commands.ssh;
    cmdGpg = x commands.gpg;
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
  securityTxt = ''
    Contact: mailto:${site.email}
    Expires: ${site.securityTxt.expires}
    Encryption: ${urls.wkd}
    Encryption: openpgp4fpr:${lib.toLower site.pgp.fingerprint}
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
      Standards: HTML5, CSS3, RFC 9116, NIP-05, OpenPGP WKD
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
