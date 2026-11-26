export type ProviderID = "qq" | "gmail" | "sjtu" | "custom";

export const providers = {
  qq: {
    name: "QQ 邮箱", host: "imap.qq.com", secretTitle: "QQ 授权码", placeholder: "16 位邮箱授权码",
    helpTitle: "获取 QQ 授权码", helpURL: "https://help.mail.qq.com/detail/106/985",
  },
  gmail: {
    name: "Gmail", host: "imap.gmail.com", secretTitle: "Google 应用密码", placeholder: "16 位应用专用密码",
    helpTitle: "获取 Google 应用密码", helpURL: "https://myaccount.google.com/apppasswords",
  },
  sjtu: {
    name: "SJTU", host: "mail.sjtu.edu.cn", secretTitle: "jAccount 密码", placeholder: "交大 jAccount 密码",
    helpTitle: "交大邮箱登录说明", helpURL: "https://net.sjtu.edu.cn/info/1191/2694.htm",
  },
  custom: {
    name: "其他 IMAP", host: "", secretTitle: "密码 / 授权码", placeholder: "邮箱客户端密码",
    helpTitle: "", helpURL: "",
  },
} as const;

export function detectProvider(email: string): ProviderID {
  const parts = email.trim().toLowerCase().split("@");
  if (parts.length !== 2 || !parts[0]) return "custom";
  const domain = parts[1];
  if (domain === "qq.com" || domain === "foxmail.com") return "qq";
  if (domain === "gmail.com" || domain === "googlemail.com") return "gmail";
  if (domain === "sjtu.edu.cn") return "sjtu";
  return "custom";
}

export function providerForHost(host?: string): ProviderID {
  return (Object.keys(providers) as ProviderID[]).find((id) => providers[id].host === host?.trim().toLowerCase()) ?? "custom";
}

export function normalizeSecret(provider: ProviderID, value: string): string {
  return provider === "gmail" || provider === "qq" ? value.replace(/\s+/g, "") : value;
}

export function unsupportedAddress(email: string): boolean {
  return email.trim().toLowerCase().endsWith("@365.sjtu.edu.cn");
}
