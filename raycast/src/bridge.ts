import { environment, getPreferenceValues } from "@raycast/api";
import { networkSettings } from "./network";
import { execFile } from "node:child_process";
import { access } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";
import { createConnection } from "node:net";
import { promisify } from "node:util";

export interface MailAccount {
  id: string;
  name: string;
  username: string;
  host: string;
  port: number;
  folder: string;
  enabled: boolean;
}
export interface LatestCode {
  id: string;
  accountID: string;
  account: string;
  username: string;
  provider: string;
  sender: string;
  code: string;
  kind?: "code" | "link";
  receivedAt: number;
}
export interface Snapshot {
  accounts: { account: MailAccount; online: boolean; error?: string; lookupState?: "idle" | "queued" | "connecting" | "checking" | "searching"; cacheReady?: boolean; fetchedMessages?: number }[];
  codes: LatestCode[];
  paused: boolean;
  autoCopy: boolean;
  showPopup: boolean;
  launchAtLogin: boolean;
  error?: string;
}
export interface Request {
  action: string;
  account?: MailAccount;
  password?: string;
  id?: string;
  value?: boolean;
}
const socketPath = join(homedir(), "Library", "Application Support", "MailCode", "bridge.sock");
const run = promisify(execFile);
let starting: Promise<void> | undefined;

export function rawRequest(request: Request, timeout = 10_000): Promise<Snapshot> {
  return new Promise((resolve, reject) => {
    const socket = createConnection(socketPath);
    let data = Buffer.alloc(0);
    let settled = false;
    const fail = (error: Error) => {
      if (settled) return;
      settled = true;
      socket.destroy();
      reject(error);
    };
    socket.setTimeout(timeout, () => fail(new Error("Connection timed out. Please try again.")));
    socket.on("error", fail);
    socket.on("end", () => { if (!settled) fail(new Error("Background helper disconnected")); });
    socket.on("connect", () => {
      try { socket.write(JSON.stringify({ ...request, network: networkSettings(getPreferenceValues()) }) + "\n"); }
      catch (error) { fail(error instanceof Error ? error : new Error("Invalid network settings")); }
    });
    socket.on("data", (chunk: Buffer) => {
      data = Buffer.concat([data, chunk]);
      if (data.length > 1_048_576) { fail(new Error("Background response is too large")); return; }
      const newline = data.indexOf(10);
      if (newline < 0) return;
      try {
        const response = JSON.parse(data.subarray(0, newline).toString("utf8")) as Snapshot;
        if (response.error) { fail(new Error(response.error)); return; }
        settled = true;
        socket.destroy();
        resolve(response);
      } catch (error) { fail(error instanceof Error ? error : new Error("Invalid background response")); }
    });
  });
}

async function ensureRunning() {
  try { await rawRequest({ action: "list" }, 1200); return; } catch { /* Launch the bundled helper if absent. */ }
  if (!starting) {
    starting = (async () => {
      const application = join(environment.assetsPath, "MailCode.app");
      await access(join(application, "Contents", "MacOS", "MailCode"));
      await run("/usr/bin/open", ["-g", application, "--args", "--background"], { timeout: 10_000 });
      for (let attempt = 0; attempt < 30; attempt++) {
        await new Promise((resolve) => setTimeout(resolve, 200));
        try { await rawRequest({ action: "list" }, 1000); return; } catch { /* Wait for launch. */ }
      }
      throw new Error("Could not start InboxCode. Reopen this command.");
    })().finally(() => { starting = undefined; });
  }
  await starting;
}
export async function request(value: Request): Promise<Snapshot> {
  networkSettings(getPreferenceValues());
  await ensureRunning();
  return rawRequest(value, value.action === "refresh" ? 180_000 : value.action === "save" ? 90_000 : 10_000);
}
