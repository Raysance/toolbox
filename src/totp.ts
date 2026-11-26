import { createHmac, createHash } from "node:crypto";

export interface Account {
  id: string;
  issuer: string;
  name: string;
  secret: string;
  algorithm: "SHA1" | "SHA256" | "SHA512";
  digits: 6 | 7 | 8;
  period: number;
}

export function decodeBase32(input: string): Buffer {
  const text = input.replace(/\s/g, "").toUpperCase();
  if (!/^[A-Z2-7]+=*$/.test(text)) throw new Error("Invalid setup key");
  const data = text.replace(/=+$/, "");
  if (![0, 2, 4, 5, 7].includes(data.length % 8)) throw new Error("Invalid setup key");
  const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
  let value = 0, bits = 0;
  const output: number[] = [];
  for (const char of data) {
    value = (value << 5) | alphabet.indexOf(char);
    bits += 5;
    if (bits >= 8) {
      bits -= 8;
      output.push((value >>> bits) & 255);
      value &= (1 << bits) - 1;
    }
  }
  if (value !== 0 || !output.length) throw new Error("Invalid setup key");
  return Buffer.from(output);
}

export function parseImport(text: string): Account[] {
  const lines = text.split(/[\r\n,]+/).map((line) => line.trim()).filter(Boolean);
  if (!lines.length || lines.length > 1000) throw new Error("No valid accounts in import");
  const accounts = new Map<string, Account>();
  for (const line of lines) {
    try {
      const url = new URL(line);
      if (url.protocol !== "otpauth:" || url.hostname !== "totp") throw new Error();
      const secret = (url.searchParams.get("secret") ?? "").replace(/\s/g, "").toUpperCase().replace(/=+$/, "");
      decodeBase32(secret);
      const algorithm = (url.searchParams.get("algorithm") ?? "SHA1").toUpperCase();
      const digits = Number(url.searchParams.get("digits") ?? "6");
      const period = Number(url.searchParams.get("period") ?? "30");
      if (!["SHA1", "SHA256", "SHA512"].includes(algorithm) || ![6, 7, 8].includes(digits) || !Number.isSafeInteger(period) || period < 1 || period > 3600) throw new Error();
      const label = decodeURIComponent(url.pathname.slice(1));
      const colon = label.indexOf(":");
      const issuer = url.searchParams.get("issuer") || (colon >= 0 ? label.slice(0, colon) : label) || "Account";
      const name = colon >= 0 ? label.slice(colon + 1) : label;
      const id = createHash("sha256").update(JSON.stringify([issuer, name, secret, algorithm, digits, period])).digest("hex");
      accounts.set(id, { id, issuer, name, secret, algorithm, digits, period } as Account);
    } catch {
      // Do not include the source URI or secret in errors or logs.
      throw new Error("The import contains an invalid or unsupported TOTP entry");
    }
  }
  return [...accounts.values()].sort((a, b) => a.issuer.localeCompare(b.issuer) || a.name.localeCompare(b.name));
}

export function totp(account: Account, timeMs = Date.now()): string {
  if (!Number.isFinite(timeMs) || timeMs < 0) throw new Error("Invalid time");
  const counter = BigInt(Math.floor(timeMs / 1000 / account.period));
  const message = Buffer.alloc(8);
  message.writeBigUInt64BE(counter);
  const digest = createHmac(account.algorithm.toLowerCase(), decodeBase32(account.secret)).update(message).digest();
  const offset = digest[digest.length - 1] & 15;
  const number = digest.readUInt32BE(offset) & 0x7fffffff;
  return String(number % 10 ** account.digits).padStart(account.digits, "0");
}

export function remaining(account: Account, timeMs = Date.now()): number {
  return account.period - (Math.floor(timeMs / 1000) % account.period);
}

export function formatCode(code: string): string {
  const split = Math.ceil(code.length / 2);
  return code.slice(0, split) + " " + code.slice(split);
}

export function toURI(account: Account): string {
  const label = account.issuer + ":" + account.name;
  const params = new URLSearchParams({
    secret: account.secret, issuer: account.issuer, algorithm: account.algorithm,
    digits: String(account.digits), period: String(account.period),
  });
  return `otpauth://totp/${encodeURIComponent(label)}?${params}`;
}

export function editAccount(original: Account, values: {
  issuer: string; name: string; secret: string; algorithm: string; digits: string; period: string;
}): Account {
  if (!values.issuer.trim() || !values.name.trim()) throw new Error("Enter a service and account name");
  // Validate edits through the same parser as imports, keeping the stable UI identity.
  const candidate = { ...original, ...values, issuer: values.issuer.trim(), name: values.name.trim(),
    digits: Number(values.digits), period: Number(values.period) } as Account;
  const [validated] = parseImport(toURI(candidate));
  return { ...validated, id: original.id };
}
