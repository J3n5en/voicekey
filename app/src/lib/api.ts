import { invoke } from "@tauri-apps/api/core";
import { listen, type UnlistenFn } from "@tauri-apps/api/event";
import doubao from "../assets/logos/doubao.png";
import wetype from "../assets/logos/wetype.png";
import qwen from "../assets/logos/qwen.png";

export type Channel = "doubao" | "wetype" | "qwen" | "offline" | "all";
export type QwenOutput = "asr" | "polish" | "translate";
export interface Shortcut { code: number; mods: number; name: string }
export interface Settings {
  channel: Channel; holdKey: string; tapShortcut: Shortcut | null; silence: number; streaming: boolean;
  liveText: boolean; mic: string; qwenOutput: QwenOutput; multi: Channel[]; lastPick: Channel | null; autostart: boolean; theme: string; onboarded: boolean;
}
export interface OfflineStatus { state: "missing" | "downloading" | "ready" | "failed"; progress?: number; error?: string }
export interface Perms { accessibility: boolean; mic: "granted" | "denied" | "undetermined" }
export interface AppInfo {
  settings: Settings; platform: "mac" | "win"; arch: string; version: string;
  holdKeys: { id: string; name: string }[]; channels: Channel[];
  offline: { supported: boolean; status: OfflineStatus }; perms: Perms;
}
export type RowState = "listen" | "wait" | "final" | "error" | "skip";
export interface Row { channel: Channel; text: string; state: RowState; ms: number | null }
export interface Model { recording: boolean; rows: Row[]; sel: number }

export const call = invoke;
export const on = <T>(name: string, f: (p: T) => void): Promise<UnlistenFn> => listen<T>(name, (e) => f(e.payload));

export const CH: Record<Channel, { name: string; short: string; desc: string; tags: string[]; logo: string }> = {
  doubao: { name: "豆包输入法", short: "豆包", desc: "响应快、中英混说准确，适合日常输入。", tags: ["在线", "流式", "推荐"], logo: doubao },
  wetype: { name: "微信输入法", short: "微信", desc: "口语化表达识别稳定，数字自动规整。", tags: ["在线", "流式"], logo: wetype },
  qwen: { name: "千问输入法", short: "千问", desc: "支持原文、润色、译成英文三种输出。", tags: ["在线", "润色", "翻译"], logo: qwen },
  offline: { name: "离线（本地模型）", short: "离线", desc: "完全在本机运行，断网可用，不上传音频。", tags: ["离线", "约 190MB"], logo: doubao },
  all: { name: "多渠道", short: "多渠道", desc: "勾选的渠道同时识别、实时出字，说完在光标处挑选最满意的一条上屏。", tags: ["并行", "流式候选"], logo: "" },
};

/** 根据平台与主题设置 html class */
export function applyLook(platform: string, theme: string) {
  const root = document.documentElement;
  root.classList.toggle("mac", platform === "mac");
  root.classList.toggle("win", platform === "win");
  const dark = theme === "dark" || (theme === "system" && matchMedia("(prefers-color-scheme: dark)").matches);
  root.classList.toggle("dark", dark);
}

export function esc(s: string) {
  return s.replace(/[&<>]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;" })[c]!);
}

/** 定稿与中间结果比对，标出新增/改动的字 */
export function diffMark(a: string, b: string): string {
  const A = [...a], B = [...b], n = A.length, m = B.length;
  const d = Array.from({ length: n + 1 }, () => new Uint16Array(m + 1));
  for (let i = n - 1; i >= 0; i--) for (let j = m - 1; j >= 0; j--)
    d[i][j] = A[i] === B[j] ? d[i + 1][j + 1] + 1 : Math.max(d[i + 1][j], d[i][j + 1]);
  const keep = new Set<number>();
  let i = 0, j = 0;
  while (i < n && j < m) {
    if (A[i] === B[j]) { keep.add(j); i++; j++; } else if (d[i + 1][j] >= d[i][j + 1]) i++; else j++;
  }
  return B.map((c, k) => (keep.has(k) || /[，。、,. ]/.test(c) ? esc(c) : `<span class="chg">${esc(c)}</span>`)).join("");
}
