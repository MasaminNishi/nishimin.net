// NFC カード用の中継リダイレクタ。カードには https://nishimin.net/touch を焼く。
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
  const { request } = context;
  const url = new URL(request.url);
  const key = url.searchParams.get("c");

  // アクセス元ログ。IP は残さない。
  console.log(
    JSON.stringify({
      event: "touch",
      at: new Date().toISOString(),
      key,
      country: request.cf?.country ?? null,
      userAgent: request.headers.get("user-agent"),
      referer: request.headers.get("referer"),
    }),
  );

  const { default: fallback, targets } = await loadTargets(context);
  const target = (key !== null && targets[key]) || fallback;

  return new Response(null, {
    status: 302,
    headers: {
      Location: new URL(target, url.origin).toString(),
      // タップごとにログを取りたいのでキャッシュさせない。
      "Cache-Control": "no-store",
    },
  });
};
