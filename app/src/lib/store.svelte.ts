import { call, on, applyLook, type AppInfo, type Settings, type Perms, type Model, type Shortcut, type OfflineStatus, type Channel, type UpdateStatus } from "./api";

export const app = $state({
  info: null as AppInfo | null,
  s: null as Settings | null,
  perms: { accessibility: true, mic: "granted" } as Perms,
  level: 0,
  compare: null as Model | null,
  recording: false,
  mics: [] as string[],
  models: {} as Partial<Record<Channel, OfflineStatus>>,
  update: { state: "idle" } as UpdateStatus,
});

export function save(patch: Partial<Settings>) {
  if (!app.s) return;
  app.s = { ...app.s, ...patch };
  call("set_settings", { settings: app.s });
}

export async function refreshPerms() {
  app.perms = await call<Perms>("perm_status");
}

export async function refreshMics() {
  app.mics = await call<string[]>("microphones");
}

export async function init() {
  const info = await call<AppInfo>("get_state");
  app.info = info;
  app.s = info.settings;
  app.perms = info.perms;
  app.models = info.models;
  app.update = info.update;
  const look = () => app.s && applyLook(info.platform, app.s.theme);
  look();
  matchMedia("(prefers-color-scheme: dark)").addEventListener("change", look);
  on<Settings>("settings", (s) => {
    app.s = s;
    look();
  });
  on<number>("level", (v) => (app.level = v));
  on<{ ch: Channel; status: OfflineStatus }>("model", (v) => (app.models[v.ch] = v.status));
  on<UpdateStatus>("update", (v) => (app.update = v));
  on<Model>("compare", (m) => (app.compare = m));
  on<Shortcut | null>("recorded", () => (app.recording = false));
  refreshMics();
}
