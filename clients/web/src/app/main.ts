// Entry point of the web app: design tokens, sign-in, shell, sync, offline check.

import tokens from "../../../../design/tokens.json";
import { api, ApiError, onConnection } from "./api";
import { checkOffline, dropPlayed, onOfflineChange } from "./downloads";
import { t } from "./i18n";
import { cueLast, onPlayer, setDevice } from "./player";
import { onRemote, onSyncState, startSync, stopSync } from "./sync";
import { isDark, onAppearance } from "./theme";
import { mountShell, refresh, renderCache, renderTop } from "./ui";
import "./app.css";

const root = document.getElementById("app")!;
const SIGNED_IN = "aj_signed_in"; // device name; lets the app start offline

function applyTokens() {
  const set = () => {
    const c = isDark() ? tokens.color.dark : tokens.color.light;
    const s = document.documentElement.style;
    for (const [k, v] of Object.entries(c)) s.setProperty(`--${k}`, v);
    s.setProperty("--radius", `${tokens.size.radius}px`);
    s.setProperty("--touch", `${tokens.size.touchCar}px`);
  };
  set();
  onAppearance(set);
}

const remembered = () => {
  try {
    return localStorage.getItem(SIGNED_IN);
  } catch {
    return null;
  }
};
const remember = (v: string | null) => {
  try {
    if (v) localStorage.setItem(SIGNED_IN, v);
    else localStorage.removeItem(SIGNED_IN);
  } catch {
    /* private mode */
  }
};

function loginScreen(message = "") {
  const field = (label: string, input: HTMLInputElement): HTMLElement[] => {
    const l = document.createElement("label");
    l.textContent = label;
    return [l, input];
  };
  const input = (props: Partial<HTMLInputElement>): HTMLInputElement => {
    const i = document.createElement("input");
    Object.assign(i, props);
    return i;
  };
  const user = input({ autocomplete: "username", autocapitalize: "none", spellcheck: false });
  const pass = input({ type: "password", autocomplete: "current-password" });
  const code = input({ inputMode: "numeric", autocomplete: "one-time-code", maxLength: 6, pattern: "[0-9]*" });
  const device = input({ value: remembered() || "Tesla" });
  const err = document.createElement("div");
  err.className = "err";
  err.textContent = message;
  const btn = document.createElement("button");
  btn.className = "big";
  btn.textContent = t("Sign in");
  btn.type = "submit";
  const form = document.createElement("form");
  form.className = "login";
  const h1 = document.createElement("h1");
  h1.textContent = "audiojoe";
  form.append(h1, ...field(t("User name"), user), ...field(t("Password"), pass),
    ...field(t("Code from the authenticator app"), code), ...field(t("Device name"), device), btn, err);
  form.onsubmit = async (e) => {
    e.preventDefault();
    btn.disabled = true;
    err.textContent = "";
    try {
      await api("POST", "/auth/login", { username: user.value.trim(), password: pass.value, totp: code.value.trim(), device: device.value.trim() || "Browser" });
      pass.value = "";
      await startApp();
    } catch (x) {
      const s = (x as ApiError).status;
      err.textContent = s === 429 ? t("Too many attempts. Please wait 15 minutes.") : s === 0 ? t("Server not reachable.") : t("Sign-in failed. Check name, password and code.");
      btn.disabled = false;
    }
  };
  root.replaceChildren(form);
  user.focus();
}

async function logout() {
  try {
    await api("POST", "/auth/logout");
  } catch {
    /* offline: cookie stays until it expires */
  }
  remember(null);
  stopSync();
  loginScreen();
}

let started = false;
async function startApp() {
  let device = remembered();
  try {
    const me = await api<{ user: string; device: string }>("GET", "/me");
    device = me.device;
    remember(device);
  } catch (e) {
    // Signed out on the server, or no session: sign in. Offline with a known session: go on.
    if ((e as ApiError).status !== 0 || !device) return loginScreen();
  }
  setDevice(device ?? "");
  mountShell(root, () => void logout());
  if (started) return;
  started = true;
  startSync();
  onConnection(renderTop);
  onSyncState(renderTop);
  onPlayer(() => {
    refresh("player");
    void renderCache();
  });
  onRemote((p) => {
    refresh("data");
    if (p.finished) void dropPlayed();
  });
  onOfflineChange(() => {
    refresh("offline");
    renderTop();
  });
  void checkOffline();
  void cueLast();
  void dropPlayed();
  try {
    await navigator.storage?.persist?.();
  } catch {
    /* refused – handled by checkOffline */
  }
}

applyTokens();
if ("serviceWorker" in navigator) void navigator.serviceWorker.register("/sw.js");
void startApp();
