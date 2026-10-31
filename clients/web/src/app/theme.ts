// Appearance per device: automatic (follows the system), light or dark.

export type Appearance = "auto" | "light" | "dark";

const KEY = "aj_appearance";
const ORDER: Appearance[] = ["auto", "light", "dark"];
const listeners: (() => void)[] = [];

export function appearance(): Appearance {
  if (memory) return memory;
  try {
    const v = localStorage.getItem(KEY) as Appearance | null;
    return v && ORDER.includes(v) ? v : "auto";
  } catch {
    return "auto";
  }
}

/** Next step of the moon button: automatic → light → dark → automatic. */
export function nextAppearance() {
  const v = ORDER[(ORDER.indexOf(appearance()) + 1) % ORDER.length];
  try {
    localStorage.setItem(KEY, v);
  } catch {
    /* private mode: applies until reload */
    memory = v;
  }
  listeners.forEach((f) => f());
}

let memory: Appearance | null = null;

export function isDark(systemDark: boolean) {
  const a = appearance();
  return a === "dark" || (a === "auto" && systemDark);
}

export function onAppearance(f: () => void) {
  listeners.push(f);
}
