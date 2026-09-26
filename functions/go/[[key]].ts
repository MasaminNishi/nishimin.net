// 物理媒体（QR / NFC）で配るリンクの中継リダイレクタ。
// 媒体には https://nishimin.net/go/<id> を焼き、実際の飛び先は site.nix に持たせる。
//
// 存在理由は間接参照そのもの。印刷して配った QR やカードは後から書き換えられないが、
// site.nix を直せば配布済みの媒体の飛び先を変えられる。「302 するだけ」に
// 見えても消さないこと。
//
// アクセス数は記録していない。Pages Functions の console.log は
// `wrangler pages deployment tail` を張っている間しか流れず保存されないため、
// 書いても読めるものにならない。必要になったら Analytics Engine か KV を足す。
//
// 遷移先は /go.json の許可リストからのみ選ぶ。`?to=<任意 URL>` のような
// 受け口は作らない（オープンリダイレクタになるため）。
//
// キャッチオール ([[key]]) なので /go・/go/<id>・/go/a/b のすべてをここで受ける。
// 知らない id は既定の飛び先へ落とす。印刷物の id が古くなっても 404 にせず
// どこかへ着地させるため。

interface GoTargets {
  /** id に当たらなかったときの飛び先。site.nix の go.home。 */
  default: string;
  /** id -> URL の許可リスト。 */
  targets: Record<string, string>;
}

const FALLBACK: GoTargets = { default: "/", targets: {} };

// isolate が生きている間は使い回す。
let cached: GoTargets | undefined;

async function loadTargets(
  context: EventContext<unknown, string, Record<string, unknown>>,
): Promise<GoTargets> {
  if (cached) return cached;

  const url = new URL("/go.json", context.request.url);
  const request = new Request(url.toString(), { method: "GET" });

  try {
    const assets = context.env?.ASSETS;
    const response = assets ? await assets.fetch(request) : await context.next(request);
    if (!response.ok) return FALLBACK;

    cached = (await response.json()) as GoTargets;
    return cached;
  } catch {
    return FALLBACK;
  }
}

export const onRequest: PagesFunction = async (context) => {
  const url = new URL(context.request.url);

  // /go では params.key が無く、/go/a/b では配列になる。
  const raw: string | string[] | undefined = context.params.key;
  const key = Array.isArray(raw) ? raw.join("/") : raw;

  const { default: fallback, targets } = await loadTargets(context);
  const target = (key ? targets[key] : undefined) ?? fallback;

  return new Response(null, {
    status: 302,
    headers: {
      Location: new URL(target, url.origin).toString(),
      // 配布済みの媒体の飛び先を後から変えられるようにするため、302 をキャッシュさせない。
      // ここを緩めると site.nix を直しても、一度アクセスした端末は古い先へ飛び続ける。
      "Cache-Control": "no-store",
    },
  });
};
