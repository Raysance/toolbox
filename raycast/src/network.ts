export function networkSettings(preferences: { connectionMode?: string; proxyHost?: string; proxyPort?: string }) {
  const mode = preferences.connectionMode || "direct";
  if (!["direct", "system", "socks5", "http"].includes(mode)) throw new Error("Choose a valid connection mode");
  if (mode === "direct" || mode === "system") return { mode, proxyHost: "127.0.0.1", proxyPort: 7897 };
  const proxyHost = (preferences.proxyHost || "127.0.0.1").trim();
  const port = (preferences.proxyPort || "7897").trim();
  const proxyPort = Number(port);
  if (!proxyHost || /[\s/@\x00-\x1f\x7f]/.test(proxyHost) || !/^\d+$/.test(port) || proxyPort < 1 || proxyPort > 65535) {
    throw new Error("Enter a proxy host and a port from 1 to 65535 in InboxCode settings");
  }
  return { mode, proxyHost, proxyPort };
}
