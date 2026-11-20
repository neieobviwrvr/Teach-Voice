// Winziger lokaler Webserver fürs Dashboard, ohne Abhängigkeiten.
//
//   node dashboard/serve.mjs          -> http://127.0.0.1:5180
//   node dashboard/serve.mjs 8080     -> anderer Port
//
// Liefert nur die Dateien aus diesem Ordner aus und lauscht nur auf
// 127.0.0.1 (nicht im WLAN sichtbar). Ein echter http-Ursprung statt
// file:// sorgt dafür, dass Login, sessionStorage und CORS normal laufen.
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { dirname, extname, join, normalize, sep } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = dirname(fileURLToPath(import.meta.url));
const PORT = Number(process.argv[2]) || 5180;
const TYPES = { ".html": "text/html; charset=utf-8", ".js": "text/javascript; charset=utf-8", ".css": "text/css; charset=utf-8", ".svg": "image/svg+xml", ".png": "image/png", ".ico": "image/x-icon" };

createServer(async (req, res) => {
  try {
    const path = decodeURIComponent(new URL(req.url, "http://localhost").pathname);
    const file = normalize(join(ROOT, path === "/" ? "index.html" : path));
    const type = TYPES[extname(file)];
    if (!file.startsWith(ROOT + sep) || !type || file.endsWith("serve.mjs")) {
      res.writeHead(404).end("Nicht gefunden");
      return;
    }
    const body = await readFile(file);
    res.writeHead(200, {
      "Content-Type": type,
      "Cache-Control": "no-store",
      "X-Content-Type-Options": "nosniff",
      "Referrer-Policy": "no-referrer",
      "X-Frame-Options": "DENY",
    });
    res.end(body);
  } catch {
    res.writeHead(404).end("Nicht gefunden");
  }
}).listen(PORT, "127.0.0.1", () => {
  console.log(`Teach Dashboard: http://127.0.0.1:${PORT}  (Demo ohne Login: http://127.0.0.1:${PORT}/?demo)`);
});
