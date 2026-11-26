import { Action, ActionPanel, Form, showToast, Toast, useNavigation } from "@raycast/api";
import { randomUUID } from "node:crypto";
import { useEffect, useRef, useState } from "react";
import { MailAccount, request } from "./bridge";
import { detectProvider, normalizeSecret, ProviderID, providerForHost, providers, unsupportedAddress } from "./providers";

export function AccountForm({ account, onSaved }: { account?: MailAccount; onSaved: () => Promise<void> }) {
  const [advanced, setAdvanced] = useState(false);
  const [busy, setBusy] = useState(false);
  const [username, setUsername] = useState(account?.username || "");
  const [choice, setChoice] = useState<ProviderID | "auto">(account ? providerForHost(account.host) : "auto");
  const providerID = choice === "auto" ? detectProvider(username) : choice;
  const provider = providers[providerID];
  const [host, setHost] = useState(account?.host || provider.host);
  const [port, setPort] = useState(String(account?.port || 993));
  const [folder, setFolder] = useState(account?.folder || "INBOX");
  const [name, setName] = useState(account?.name || "");
  const [password, setPassword] = useState("");
  const previousDefault = useRef<string>(provider.host);
  const { pop } = useNavigation();
  useEffect(() => {
    const previous = previousDefault.current;
    setHost((current) => !current || current === previous ? provider.host : current);
    previousDefault.current = provider.host;
  }, [provider.host]);

  async function submit() {
    if (busy) return;
    const address = username.trim();
    const server = host.trim();
    const secret = normalizeSecret(providerID, password);
    const portNumber = Number(port);
    if (unsupportedAddress(address)) {
      await showToast({ style: Toast.Style.Failure, title: "SJTU 365 Is Not Supported", message: "Use the SJTU preset for @sjtu.edu.cn" });
      return;
    }
    if (!address || !server || (!account && !secret) || !Number.isInteger(portNumber) || portNumber < 1 || portNumber > 65535) {
      await showToast({ style: Toast.Style.Failure, title: "Enter Email and Password", message: server ? undefined : "Enter the IMAP server in Advanced settings" });
      return;
    }
    if (account && !secret && (address !== account.username || server !== account.host || portNumber !== account.port)) {
      await showToast({ style: Toast.Style.Failure, title: "Re-enter Your Password After Changing the Account or Server" });
      return;
    }
    setBusy(true);
    const toast = await showToast({ style: Toast.Style.Animated, title: "Connecting Account" });
    try {
      await request({ action: "save", password: secret, account: {
        id: account?.id || randomUUID(), username: address, host: server, port: portNumber,
        name: name.trim(), folder: folder.trim() || "INBOX", enabled: account?.enabled ?? true,
      } });
      setPassword("");
      toast.style = Toast.Style.Success;
      toast.title = "Connected";
      await onSaved();
      pop();
    } catch (error) {
      toast.style = Toast.Style.Failure;
      toast.title = "Connection Failed";
      toast.message = error instanceof Error ? error.message : "Check your account settings";
    } finally { setBusy(false); }
  }
  const showServer = advanced || (username.includes("@") && providerID === "custom");
  return (
    <Form navigationTitle={account ? "Edit Account" : "Connect Account"} isLoading={busy} enableDrafts={false}
      actions={<ActionPanel>
        <Action.SubmitForm title="Connect Account" onSubmit={submit} />
        {provider.helpURL && <Action.OpenInBrowser title={provider.helpTitle} url={provider.helpURL} />}
      </ActionPanel>}
    >
      <Form.TextField id="username" title="Email" value={username} onChange={setUsername} placeholder="QQ, Gmail, or SJTU email address" />
      <Form.PasswordField id="password" title={provider.secretTitle} value={password} onChange={setPassword} placeholder={account ? "Leave blank to keep current password" : provider.placeholder} />
      <Form.Checkbox id="advanced" label="Advanced" value={advanced} onChange={setAdvanced} />
      {advanced && <Form.Dropdown id="provider" title="Provider" value={choice} onChange={(value) => {
        const selected = value as ProviderID | "auto";
        setChoice(selected);
        setHost(providers[selected === "auto" ? detectProvider(username) : selected].host);
        setPort("993");
      }}>
        <Form.Dropdown.Item value="auto" title="Detect Automatically" />
        {(Object.keys(providers) as ProviderID[]).map((id) => <Form.Dropdown.Item key={id} value={id} title={providers[id].name} />)}
      </Form.Dropdown>}
      {showServer && <Form.TextField id="host" title="Server" value={host} onChange={setHost} placeholder="imap.example.com" />}
      {advanced && <Form.TextField id="port" title="Port" value={port} onChange={setPort} />}
      {advanced && <Form.TextField id="folder" title="Folder" value={folder} onChange={setFolder} />}
      {advanced && <Form.TextField id="name" title="Name" value={name} onChange={setName} placeholder="Optional" />}
    </Form>
  );
}
