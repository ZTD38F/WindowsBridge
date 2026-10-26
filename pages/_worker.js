// Cloudflare Pages advanced-mode route for an immutable, auditable installer.
// Browser requests continue to the website; explicit /install.* and CLI root receive the pinned file redirect.
const INSTALLER = "https://raw.githubusercontent.com/ZTD38F/WindowsBridge/47dca7c44d25aa9b26faf763b36d6c786d3ae6da/install.ps1";
const INSTALL_PATH = "/install.ps1";
const CLI_UA = /(?:WindowsPowerShell\/|PowerShell\/|curl\/|Wget\/|HTTPie\/|Termux|python-requests\/)/i;

export default {
  async fetch(request, env) {
    const pathname = new URL(request.url).pathname;
    if ((request.method === "GET" || request.method === "HEAD") &&
        (pathname === INSTALL_PATH || (pathname === "/" && CLI_UA.test(request.headers.get("user-agent") || "")))) {
      return new Response(null, {status: 302, headers: {
        "Location": INSTALLER,
        "Cache-Control": "no-store",
        "X-Content-Type-Options": "nosniff",
        "Referrer-Policy": "no-referrer",
      }});
    }
    return env.ASSETS.fetch(request);
  },
};
