// User-Agent を見て、curl 等の CLI クライアントにはプレーンテキストを返す。
//
// 重要: この middleware は functions/ 直下にあるため全パスに対して呼ばれる。
// 分岐をルートパスに限定しないと、`curl -L /keys >> ~/.ssh/authorized_keys` が
// ASCII アートを書き込んでしまい、/.well-known/* の Content-Type や CORS も壊れる。
// 下の早期 return がその防波堤。

/** curl / wget / HTTPie など、端末から叩かれているか。 */
function isTerminalClient(userAgent: string): boolean {
  const ua = userAgent.trim().toLowerCase();
  return /^(curl|wget|httpie)\//.test(ua) || ua.includes("curl/");
}

type Context = EventContext<unknown, string, Record<string, unknown>>;

/**
 * 静的アセットを取得する。
 * curl 用の本文を TS にハードコードせず nix 生成の成果物から読むことで、
 * site.nix の単一ソース性を保つ。
 */
async function fetchAsset(context: Context, path: string): Promise<Response> {
  const assetUrl = new URL(path, context.request.url);
  const assetRequest = new Request(assetUrl.toString(), { method: "GET" });

  // Pages が ASSETS バインディングを注入していればそれを使う。
  // ローカルの wrangler pages dev では注入されないので next() にフォールバックする。
  const assets = context.env?.ASSETS;
  return assets ? assets.fetch(assetRequest) : context.next(assetRequest);
}

// ---------------------------------------------------------------------------
// セキュリティヘッダの引き継ぎ
//
// static/_headers の /* ルールは Cloudflare の「静的アセット配信」にしか適用されず、
// Function が自前で組み立てた Response には乗らない。そこで静的アセットの応答から
// ヘッダを引き写す。こうすればヘッダの定義は static/_headers の 1 箇所のままで済み、
// あちらに足したルールが自動でこちらにも効く。
// ---------------------------------------------------------------------------

/** 応答ごとに固有なので引き継いではいけないヘッダ。 */
const NOT_INHERITED = new Set([
  "content-type",
  "content-length",
  "content-encoding",
  "etag",
  "last-modified",
  "cache-control",
  "vary",
  "location",
]);

/**
 * static/_headers の /* ブロックに必ず入っているヘッダ。
 * これが付いていれば静的アセット配信を通った＝適用済みと判断できる。
 * _headers からこの行を消すとここの判定が壊れるので、消さないこと。
 */
const APPLIED_MARKER = "x-content-type-options";

function inheritableFrom(response: Response): [string, string][] {
  return [...response.headers].filter(([name]) => !NOT_INHERITED.has(name.toLowerCase()));
}

// isolate が生きている間は使い回す。
let cachedHeaders: [string, string][] | undefined;

async function securityHeaders(context: Context, donor?: Response): Promise<[string, string][]> {
  if (donor) return inheritableFrom(donor);
  if (!cachedHeaders) {
    cachedHeaders = inheritableFrom(await fetchAsset(context, "/robots.txt"));
  }
  return cachedHeaders;
}

/**
 * Function が作った Response に _headers 由来のヘッダを載せる。
 * 静的アセットの応答（既に適用済み）はそのまま素通しする。
 */
async function withSecurityHeaders(
  context: Context,
  response: Response,
  donor?: Response,
): Promise<Response> {
  if (response.headers.has(APPLIED_MARKER)) return response;

  const patched = new Response(response.body, response);
  for (const [name, value] of await securityHeaders(context, donor)) {
    patched.headers.set(name, value);
  }
  return patched;
}

/**
 * 同じ URL で HTML とテキストを出し分けるので、キャッシュに User-Agent を
 * 考慮させないと片方が取り違えて配信される。
 */
function withVary(response: Response): Response {
  const patched = new Response(response.body, response);
  patched.headers.set("Vary", "User-Agent");
  return patched;
}

export const onRequest: PagesFunction = async (context) => {
  const { request } = context;
  const url = new URL(request.url);

  // ルートパス以外には一切介入しない。
  // （/touch のような Function の応答にはヘッダだけ足す）
  if (url.pathname !== "/" && url.pathname !== "/index.html") {
    return withSecurityHeaders(context, await context.next());
  }

  if (!isTerminalClient(request.headers.get("user-agent") ?? "")) {
    return withVary(await context.next());
  }

  // ?plain で ANSI エスケープなしに切り替える。
  const assetPath = url.searchParams.has("plain") ? "/plain.txt" : "/ansi.txt";
  const asset = await fetchAsset(context, assetPath);

  // 生成物が見つからなければ通常の HTML にフォールバックする。
  if (!asset.ok) {
    return withVary(await context.next());
  }

  const body = request.method === "HEAD" ? null : await asset.text();

  const response = new Response(body, {
    status: 200,
    headers: {
      "Content-Type": "text/plain; charset=utf-8",
      "Cache-Control": "public, max-age=300",
      Vary: "User-Agent",
    },
  });

  // 取得済みのアセット応答をそのままドナーにするので、追加のリクエストは要らない。
  return withSecurityHeaders(context, response, asset);
};
