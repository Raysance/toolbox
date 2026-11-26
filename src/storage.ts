import { LocalStorage } from "@raycast/api";
import { readFile, unlink } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";
import { Account, parseImport } from "./totp";

const STORAGE_KEY = "accounts-v1";
const IMPORT_FILE = join(homedir(), "Library", "Application Support", "Local 2FA", "import.txt");

export async function saveAccounts(accounts: Account[]): Promise<void> {
  const serialized = JSON.stringify(accounts);
  await LocalStorage.setItem(STORAGE_KEY, serialized);
  if (await LocalStorage.getItem<string>(STORAGE_KEY) !== serialized) throw new Error("Could not save accounts");
}

export async function loadAccounts(): Promise<Account[]> {
  const saved = await LocalStorage.getItem<string>(STORAGE_KEY);
  if (saved) return JSON.parse(saved) as Account[];
  let text: string;
  try { text = await readFile(IMPORT_FILE, "utf8"); }
  catch { throw new Error("No accounts have been imported yet"); }
  const accounts = parseImport(text);
  await saveAccounts(accounts);
  await unlink(IMPORT_FILE);
  return accounts;
}
