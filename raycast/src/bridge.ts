import { environment } from "@raycast/api";
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
  receivedAt: number;
}
export interface Snapshot {
  accounts: { account: MailAccount; online: boolean; error?: string }[];
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
    socket.setTimeout(timeout, () => fail(new Error("连接超时，请重试")));
    socket.on("error", fail);
    socket.on("end", () => { if (!settled) fail(new Error("后台连接已断开")); });
    socket.on("connect", () => socket.write(JSON.stringify(request) + "\n"));
    socket.on("data", (chunk: Buffer) => {
      data = Buffer.concat([data, chunk]);
      if (data.length > 1_048_576) { fail(new Error("后台响应过大")); return; }
      const newline = data.indexOf(10);
      if (newline < 0) return;
      try {
        const response = JSON.parse(data.subarray(0, newline).toString("utf8")) as Snapshot;
        if (response.error) { fail(new Error(response.error)); return; }
        settled = true;
        socket.destroy();
        resolve(response);
      } catch (error) { fail(error instanceof Error ? error : new Error("后台响应无效")); }
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
      throw new Error("后台未能启动，请重新打开此命令");
    })().finally(() => { starting = undefined; });
  }
  await starting;
}
export async function request(value: Request): Promise<Snapshot> {
  await ensureRunning();
  return rawRequest(value, value.action === "refresh" ? 180_000 : value.action === "save" ? 90_000 : 10_000);
}
