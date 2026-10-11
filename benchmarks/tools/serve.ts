import { createServer } from "node:http";

export interface Served {
  shutdown(): Promise<void>;
}

export function listen(
  options: { port: number; hostname?: string },
  handler: (request: Request) => Promise<Response>,
): Promise<Served> {
  const server = createServer(async (req, res) => {
    let response: Response;
    try {
      const url = new URL(req.url ?? "/", `http://${req.headers.host ?? "127.0.0.1"}`);
      response = await handler(new Request(url, { method: req.method }));
    } catch {
      response = new Response("Internal Server Error", { status: 500 });
    }
    res.statusCode = response.status;
    response.headers.forEach((value, name) => res.setHeader(name, value));
    res.end(Buffer.from(await response.arrayBuffer()));
  });
  return new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(options.port, options.hostname, () => {
      server.off("error", reject);
      resolve({
        shutdown: () =>
          new Promise<void>((done, fail) => {
            server.close((error) => (error ? fail(error) : done()));
            server.closeAllConnections();
          }),
      });
    });
  });
}
