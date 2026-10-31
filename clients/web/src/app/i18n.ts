// Base language English; German translation. Keys are the English texts.
// (Will be generated from po/de.po once the strings settle.)

const de: Record<string, string> = {
  "Now playing": "Jetzt läuft",
  "Continue": "Weiter\u00adhören",
  "Podcasts": "Podcasts",
  "Music": "Musik",
  "Offline": "Offline",
  "Server reachable": "Server erreichbar",
  "Offline · cache": "Offline · Cache",
  "Positions synced": "Stände aktuell",
  "{n} waiting to sync": "{n} warten auf Abgleich",
  "Sign in": "Anmelden",
  "User name": "Benutzername",
  "Password": "Kennwort",
  "Code from the authenticator app": "Code aus der Authenticator-App",
  "Device name": "Gerätename",
  "Sign-in failed. Check name, password and code.": "Anmeldung fehlgeschlagen. Name, Kennwort und Code prüfen.",
  "Too many attempts. Please wait 15 minutes.": "Zu viele Versuche. Bitte 15 Minuten warten.",
  "Server not reachable.": "Server nicht erreichbar.",
  "Nothing is playing.": "Es läuft nichts.",
  "Source": "Quelle",
  "Here": "Hier",
  "unchanged": "unverändert",
  "from cache": "aus dem Cache",
  "converted": "umgerechnet",
  "Taken over from {device} · {ago}": "Übernommen von {device} · {ago}",
  "Last on {device} · {ago}": "Zuletzt auf {device} · {ago}",
  "Play": "Abspielen",
  "Resume": "Weiter",
  "Play all": "Alle abspielen",
  "Save offline": "Offline",
  "Remove": "Entfernen",
  "New": "Neu",
  "Subscribed": "Abonniert",
  "Back": "Zurück",
  "Nothing to continue.": "Nichts zum Weiterhören.",
  "No podcasts subscribed. Add them in the desktop or phone app.": "Keine Podcasts abonniert. Hinzufügen in der Desktop- oder Telefon-App.",
  "No sources. Add them in the desktop or phone app.": "Keine Quellen. Hinzufügen in der Desktop- oder Telefon-App.",
  "in cache": "im Cache",
  "online only": "nur online",
  "Used {used} of about {quota}": "Belegt {used} von ca. {quota}",
  "The browser may clear this storage when space runs low; missing titles are downloaded again automatically.":
    "Der Browser kann diesen Speicher bei Platzmangel leeren; fehlende Titel werden automatisch nachgeladen.",
  "Nothing saved offline yet.": "Noch nichts offline gespeichert.",
  "waiting": "wartet",
  "loading {p}": "lädt {p}",
  "ready": "fertig",
  "failed": "fehlgeschlagen",
  "missing – will reload": "fehlt – wird nachgeladen",
  "Sign out this device": "Dieses Gerät abmelden",
  "just now": "gerade eben",
  "{n} min ago": "vor {n} Min.",
  "{n} h ago": "vor {n} Std.",
  "{n} days ago": "vor {n} Tagen",
  "Error": "Fehler",
};

const isDe = navigator.language.toLowerCase().startsWith("de");
const lang = isDe ? de : {};
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
