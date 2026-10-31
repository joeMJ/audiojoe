// Base language English; German translation. Keys are the English texts.
// The German table is generated from po/de.po (tools/i18n.py).

import de from "./de.g.json";

const isDe = navigator.language.toLowerCase().startsWith("de");
const lang: Record<string, string> = isDe ? de : {};
// Lets the browser hyphenate German labels correctly.
document.documentElement.lang = isDe ? "de" : "en";

export function t(s: string, vars: Record<string, string | number> = {}): string {
  let out = lang[s] ?? s;
  for (const [k, v] of Object.entries(vars)) out = out.replace(`{${k}}`, String(v));
  return out;
}

export function ago(iso: string): string {
  const s = (Date.now() - Date.parse(iso)) / 1000;
  if (s < 90) return t("just now");
  if (s < 3600) return t("{n} min ago", { n: Math.round(s / 60) });
  if (s < 86400 * 2) return t("{n} h ago", { n: Math.round(s / 3600) });
  return t("{n} days ago", { n: Math.round(s / 86400) });
}

export function clock(ms: number): string {
  const s = Math.max(0, Math.floor(ms / 1000));
  const h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60), sec = s % 60;
  const mm = h ? String(m).padStart(2, "0") : String(m);
  return `${h ? h + ":" : ""}${mm}:${String(sec).padStart(2, "0")}`;
}

export function bytes(n: number): string {
  if (n >= 2 ** 30) return `${(n / 2 ** 30).toFixed(1)} GB`;
  if (n >= 2 ** 20) return `${Math.round(n / 2 ** 20)} MB`;
  return `${Math.round(n / 1024)} kB`;
}
