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
      await showToast({ style: Toast.Style.Failure, title: "此版本暂不支持交大 365 邮箱", message: "SJTU 预设适用于 @sjtu.edu.cn" });
      return;
    }
    if (!address || !server || (!account && !secret) || !Number.isInteger(portNumber) || portNumber < 1 || portNumber > 65535) {
      await showToast({ style: Toast.Style.Failure, title: "请填写邮箱和密码", message: server ? undefined : "请在更多设置中填写 IMAP 服务器" });
      return;
    }
    if (account && !secret && (address !== account.username || server !== account.host || portNumber !== account.port)) {
      await showToast({ style: Toast.Style.Failure, title: "更改邮箱或服务器后，请重新填写密码" });
      return;
    }
    setBusy(true);
    const toast = await showToast({ style: Toast.Style.Animated, title: "正在连接邮箱" });
    try {
      await request({ action: "save", password: secret, account: {
        id: account?.id || randomUUID(), username: address, host: server, port: portNumber,
        name: name.trim(), folder: folder.trim() || "INBOX", enabled: account?.enabled ?? true,
      } });
      setPassword("");
      toast.style = Toast.Style.Success;
      toast.title = "已连接";
      await onSaved();
      pop();
    } catch (error) {
      toast.style = Toast.Style.Failure;
      toast.title = "连接失败";
      toast.message = error instanceof Error ? error.message : "请检查邮箱配置";
    } finally { setBusy(false); }
  }
  const showServer = advanced || (username.includes("@") && providerID === "custom");
  return (
    <Form navigationTitle={account ? "编辑邮箱" : "连接邮箱"} isLoading={busy} enableDrafts={false}
      actions={<ActionPanel>
        <Action.SubmitForm title="连接邮箱" onSubmit={submit} />
        {provider.helpURL && <Action.OpenInBrowser title={provider.helpTitle} url={provider.helpURL} />}
      </ActionPanel>}
    >
      <Form.TextField id="username" title="邮箱" value={username} onChange={setUsername} placeholder="QQ、Gmail 或 SJTU 邮箱地址" />
      <Form.PasswordField id="password" title={provider.secretTitle} value={password} onChange={setPassword} placeholder={account ? "留空保持不变" : provider.placeholder} />
      <Form.Checkbox id="advanced" label="更多设置" value={advanced} onChange={setAdvanced} />
      {advanced && <Form.Dropdown id="provider" title="邮箱类型" value={choice} onChange={(value) => {
        const selected = value as ProviderID | "auto";
        setChoice(selected);
        setHost(providers[selected === "auto" ? detectProvider(username) : selected].host);
        setPort("993");
      }}>
        <Form.Dropdown.Item value="auto" title="自动识别" />
        {(Object.keys(providers) as ProviderID[]).map((id) => <Form.Dropdown.Item key={id} value={id} title={providers[id].name} />)}
      </Form.Dropdown>}
      {showServer && <Form.TextField id="host" title="服务器" value={host} onChange={setHost} placeholder="imap.example.com" />}
      {advanced && <Form.TextField id="port" title="端口" value={port} onChange={setPort} />}
      {advanced && <Form.TextField id="folder" title="文件夹" value={folder} onChange={setFolder} />}
      {advanced && <Form.TextField id="name" title="名称" value={name} onChange={setName} placeholder="可选" />}
    </Form>
  );
}
