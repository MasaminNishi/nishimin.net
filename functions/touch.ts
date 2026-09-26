// 物理媒体（QR / NFC）で配るリンクの中継リダイレクタ。媒体には
// https://nishimin.net/touch を焼き、実際の飛び先は site.nix に持たせる。
//
// 存在理由は間接参照そのもの。印刷して配った QR やカードは後から書き換えられないが、
// site.nix を直せば配布済みの媒体の飛び先を変えられる。「/ に 302 するだけ」に
// 見えても消さないこと。
//
// アクセス数は記録していない。Pages Functions の console.log は
// `wrangler pages deployment tail` を張っている間しか流れず保存されないため、
// 書いても読めるものにならない。必要になったら Analytics Engine か KV を足す。
//
// 遷移先は site.nix の links[].id をキーにした許可リストからのみ選ぶ。
// `?to=<任意 URL>` のような受け口は作らない（オープンリダイレクタになるため）。

interface TouchTargets {
  /** 既定の遷移先。site.nix の touch.default。 */
  default: string;
  /** id -> URL の許可リスト。 */
  targets: Record<string, string>;
}

const FALLBACK: TouchTargets = { default: "/", targets: {} };

// isolate が生きている間は使い回す。
let cached: TouchTargets | undefined;

async function loadTargets(
  context: EventContext<unknown, string, Record<string, unknown>>,
): Promise<TouchTargets> {
  if (cached) return cached;

  const url = new URL("/links.json", context.request.url);
  const request = new Request(url.toString(), { method: "GET" });

  try {
    const assets = context.env?.ASSETS;
    const response = assets ? await assets.fetch(request) : await context.next(request);
    if (!response.ok) return FALLBACK;

    cached = (await response.json()) as TouchTargets;
    return cached;
  } catch {
    return FALLBACK;
  }
}

export const onRequest: PagesFunction = async (context) => {
  const url = new URL(context.request.url);
  const key = url.searchParams.get("c");

  const { default: fallback, targets } = await loadTargets(context);
  const target = (key !== null && targets[key]) || fallback;

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
