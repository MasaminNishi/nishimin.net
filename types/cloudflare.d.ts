// Cloudflare Pages Functions の型の最小宣言。
//
// 本来は @cloudflare/workers-types を使うが、このリポジトリは Nix でビルドし
// npm の依存を一切持たない方針なので、実際に使う分だけをここで宣言する。
// 実行時の型付けではなくエディタ支援のためのもの（wrangler は esbuild で
// 型を無視してトランスパイルする）。

interface Fetcher {
  fetch(input: Request | string, init?: RequestInit): Promise<Response>;
}

interface EventContext<Env, Params extends string, Data> {
  request: Request;
  functionPath: string;
  // ASSETS は Pages が常に注入する静的アセットへのバインディング。
  env: Env & { ASSETS?: Fetcher };
  params: Record<Params, string | string[]>;
  data: Data;
  next(input?: Request | string, init?: RequestInit): Promise<Response>;
  waitUntil(promise: Promise<unknown>): void;
  passThroughOnException(): void;
}

type PagesFunction<
  Env = unknown,
  Params extends string = string,
  Data extends Record<string, unknown> = Record<string, unknown>,
> = (context: EventContext<Env, Params, Data>) => Response | Promise<Response>;
