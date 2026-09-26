# プロフィールデータの単一ソース。
# index.html / ansi.txt / plain.txt / humans.txt / nostr.json / security.txt /
# links.json は全てこのファイルから生成される（lib/render.nix）。
#
# <...> の値はプレースホルダ。差し替え手順は README.md を参照。
{
  domain = "nishimin.net";
  url = "https://nishimin.net";

  handle = "<HANDLE>";
  realName = "<REAL_NAME>";
  tagline = "<1行バイオ>";
  location = "Japan";
  email = "dev@nishimin.net";

  # curl でトップに出す ASCII アート。
  # `figlet -f smslant -w 120 "nishimin.net"` で生成（figlet は devShell に入っている）。
  banner = ''
            _     __   _       _                 __
      ___  (_)__ / /  (_)_ _  (_)__    ___  ___ / /_
     / _ \/ (_-</ _ \/ /  ' \/ / _ \_ / _ \/ -_) __/
    /_//_/_/___/_//_/_/_/_/_/_/_//_(_)_//_/\__/\__/
  '';

  # 主要リンク。id は /touch?c=<id> の遷移先キーにもなる（許可リスト）。
  links = [
    {
      id = "github";
      label = "GitHub";
      url = "https://github.com/<GITHUB_USER>";
    }
    {
      id = "x";
      label = "X";
      url = "https://x.com/<X_USER>";
    }
    {
      id = "nostr";
      label = "Nostr";
      url = "https://njump.me/<NPUB>";
    }
  ];

  # 使用技術。humans.txt と index.html の両方に出る。
  stack = [
    "Cloudflare Pages / Pages Functions"
    "Nix Flakes (静的サイトは nix build で生成)"
    "TypeScript (edge runtime)"
    "NixOS"
  ];

  nostr = {
    # NIP-05 で返すのは 64 文字の hex 公開鍵。npub1... ではない。
    # 変換: nak decode <npub> / nostr-tool などで hex 化する。
    pubkeyHex = "<NOSTR_HEX_PUBKEY>";
  };

  pgp = {
    # `gpg --fingerprint dev@nishimin.net` の 40 桁（スペースなし）。
    fingerprint = "<PGP_FINGERPRINT_40_HEX>";
    # WKD direct method のハッシュ。local-part "dev" を小文字化 → SHA-1 → z-base-32。
    # `gpg-wks-client --print-wkd-hash dev@nishimin.net` で照合できる。
    wkdHash = "gudx35f8m3ns6jx87gkuda1nmtsb53nd";
    # 公開鍵バイナリ（static/.well-known/openpgpkey/hu/<wkdHash>）を配置済みなら true。
    # false の間は WKD の hu ファイルを配信しない（空ファイルを置くとクライアントが壊れるため）。
    publishWkd = false;
  };

  securityTxt = {
    # RFC 9116 で必須。未来日であること。CI が失効を検査する。毎年更新すること。
    expires = "2027-09-26T00:00:00.000Z";
    preferredLanguages = "ja, en";
  };

  touch = {
    # /touch のデフォルト遷移先。?c=<id> が links の id に一致すればそちらへ。
    default = "/";
  };
}
