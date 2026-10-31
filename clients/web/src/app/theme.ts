// Dark mode per device: on or off. Without a choice the system setting applies.

const KEY = "aj_appearance";
const system = matchMedia("(prefers-color-scheme: dark)");
const listeners: (() => void)[] = [];
let memory: string | null = null; // when storage is blocked: applies until reload

function stored() {
  if (memory) return memory;
  try {
    return localStorage.getItem(KEY);
  } catch {
    return null;
  }
}

export function isDark() {
  const v = stored();
  return v === "dark" ? true : v === "light" ? false : system.matches;
}

/** The moon button: dark mode on ↔ off. */
export function toggleDark() {
  const v = isDark() ? "light" : "dark";
  try {
    localStorage.setItem(KEY, v);
  } catch {
    memory = v;
  }
  listeners.forEach((f) => f());
}

export function onAppearance(f: () => void) {
  listeners.push(f);
  system.addEventListener("change", f);
}
