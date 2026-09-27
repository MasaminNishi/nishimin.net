# プロフィールデータの単一ソース。
# index.html / ansi.txt / plain.txt / humans.txt / nostr.json / security.txt /
# go.json は全てこのファイルから生成される（lib/render.nix）。
#
# <...> の値はプレースホルダ。差し替え手順は README.md を参照。
{
  domain = "nishimin.net";
  url = "https://nishimin.net";

  handle = "MasaminNishi";
  realName = "m-nishijima";
  tagline = "プログラマー";
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

  # 主要リンク。id は /go/<id> の遷移先キーにもなる（許可リスト）。
  links = [
    {
      id = "github";
      label = "GitHub";
      url = "https://github.com/MasaminNishi";
    }
    {
      id = "nostr";
      label = "Nostr";
      url = "https://njump.me/npub1ju9z6qmlmxsw7kmnzkywhpfdszyk42enxxeh72ug2wyrqr7qmfcshx5p26";
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
    # 変換: nak decode <npub> などで hex 化する。
    pubkeyHex = "970a2d037fd9a0ef5b731588eb852d80896aab3331b37f2b885388300fc0da71";

    # kind:0 (metadata) の picture に設定する画像パス。
    # NIP-05 (/.well-known/nostr.json) とは別物で、反映にはクライアント側で
    # kind:0 イベントを署名して publish する必要がある。
    picturePath = "/image/avatar.webp";
  };

  securityTxt = {
    # RFC 9116 で必須。未来日であること。CI が失効を検査する。毎年更新すること。
    expires = "2027-09-26T00:00:00.000Z";
    preferredLanguages = "ja, en";
  };

  go = {
    # /go/<id> は QR / NFC など物理媒体に焼くリンクの中継先。配布済みの媒体は
    # 書き換えられないので、飛び先をここで持って後から変えられるようにしている。
    #
    # <id> には links[].id に加えて "home" が使える。home は自サイト自身なので
    # links には入れない（links は表示用のリンク一覧も兼ねているため、入れると
    # 自分のページに「Homepage」というリンクが並んでしまう）。
    # id を付けずに /go とだけ叩いた場合と、知らない id の場合もここへ落ちる。
    home = "/";
  };
}
