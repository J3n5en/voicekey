import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import { runInNewContext } from "node:vm";
import { compileModule } from "svelte/compiler";
import ts from "typescript";

const source = readFileSync(new URL("./store.svelte.ts", import.meta.url), "utf8");
const js = ts.transpileModule(source, {
  compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.ESNext },
}).outputText;
const compiled = compileModule(js, { generate: "server" }).js.code
  .replace(/^import .*;$/gm, "")
  .replace(/^export /gm, "");

function store() {
  const listeners = new Map();
  const requests = [];
  const api = runInNewContext(`${compiled}\n({ app, init, refreshMics });`, {
    on: async (name, handler) => { listeners.set(name, handler); },
    call: (name) => {
      if (name === "get_state") return Promise.resolve({ settings: { mic: "", theme: "system" } });
      assert.equal(name, "microphones");
      return new Promise((resolve) => requests.push(resolve));
    },
    applyLook: () => {},
    matchMedia: () => ({ addEventListener: () => {} }),
  });
  return { ...api, requests, listeners };
}

test("connected microphone event updates the store without reopening the audio page", async () => {
  const s = store();
  const ready = s.init();
  await new Promise(setImmediate);
  assert.ok(s.listeners.has("microphones"));
  s.requests.shift()(["Built-in"]);
  await ready;
  s.listeners.get("microphones")(["Built-in", "Bluetooth LE"]);
  assert.deepEqual(Array.from(s.app.mics), ["Built-in", "Bluetooth LE"]);
});

test("late initial response cannot overwrite a newer device event", async () => {
  const s = store();
  const ready = s.init();
  await new Promise(setImmediate);
  s.listeners.get("microphones")(["Bluetooth"]);
  s.requests.shift()([]);
  await ready;
  assert.deepEqual(Array.from(s.app.mics), ["Bluetooth"]);
});

test("overlapping page/focus refresh keeps the latest response", async () => {
  const s = store();
  const first = s.refreshMics();
  const second = s.refreshMics();
  s.requests[1](["Bluetooth"]);
  await second;
  s.requests[0]([]);
  await first;
  assert.deepEqual(Array.from(s.app.mics), ["Bluetooth"]);
});
