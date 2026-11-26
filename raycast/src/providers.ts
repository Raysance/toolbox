export type ProviderID = "qq" | "gmail" | "sjtu" | "custom";

export const providers = {
  qq: {
    name: "QQ Mail", host: "imap.qq.com", secretTitle: "QQ App Password", placeholder: "16-character app password",
    helpTitle: "Get QQ App Password", helpURL: "https://help.mail.qq.com/detail/106/985",
  },
  gmail: {
    name: "Gmail", host: "imap.gmail.com", secretTitle: "Google App Password", placeholder: "16-character app password",
    helpTitle: "Get Google App Password", helpURL: "https://myaccount.google.com/apppasswords",
  },
  sjtu: {
    name: "SJTU", host: "mail.sjtu.edu.cn", secretTitle: "jAccount Password", placeholder: "SJTU jAccount password",
    helpTitle: "SJTU Mail Setup", helpURL: "https://net.sjtu.edu.cn/info/1191/2694.htm",
  },
  custom: {
    name: "Other IMAP", host: "", secretTitle: "Password / App Password", placeholder: "Mail client password",
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
