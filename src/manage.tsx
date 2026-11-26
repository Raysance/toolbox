import { Action, ActionPanel, Clipboard, Detail, Form, Icon, List, Toast, showToast, useNavigation } from "@raycast/api";
import { useState } from "react";
import { writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import { join, basename } from "node:path";
import { Account, editAccount, toURI } from "./totp";

export function AccountOptions({ account, accounts, onSave }: {
  account: Account; accounts: Account[]; onSave: (next: Account) => Promise<void>;
}) {
  const [current, setCurrent] = useState(account);
  const [all, setAll] = useState(accounts);
  async function save(next: Account) {
    await onSave(next);
    setCurrent(next);
    setAll(items => items.map(item => item.id === next.id ? next : item));
  }
  return <List navigationTitle={`${current.issuer} · ${current.name}`} searchBarPlaceholder="Account options…">
    <List.Item title="View Setup Key" icon={Icon.Key} actions={<ActionPanel>
      <Action.Push title="View Setup Key" target={<ViewKey account={current} />} />
    </ActionPanel>} />
    <List.Item title="Edit Account" icon={Icon.Pencil} actions={<ActionPanel>
      <Action.Push title="Edit Account" target={<EditAccount account={current} onSave={save} />} />
    </ActionPanel>} />
    <List.Item title="Export This Account" icon={Icon.Download} actions={<ActionPanel>
      <Action.Push title="Export This Account" target={<ExportAccounts accounts={[current]} />} />
    </ActionPanel>} />
    <List.Item title="Export All Accounts" icon={Icon.Download} actions={<ActionPanel>
      <Action.Push title="Export All Accounts" target={<ExportAccounts accounts={all} />} />
    </ActionPanel>} />
  </List>;
}

async function copySecret(text: string) {
  await Clipboard.copy(text, { concealed: true });
  await showToast({ style: Toast.Style.Success, title: "Copied securely" });
}

export function ViewKey({ account }: { account: Account }) {
  return <Detail navigationTitle="TOTP Key"
    markdown={`# TOTP key\n\n\`\`\`text\n${account.secret}\n\`\`\`\n\nThis key can generate your verification codes. Keep it private.`}
    metadata={<Detail.Metadata>
      <Detail.Metadata.Label title="Service" text={account.issuer} />
      <Detail.Metadata.Label title="Account" text={account.name} />
      <Detail.Metadata.Label title="Algorithm" text={account.algorithm} />
      <Detail.Metadata.Label title="Digits" text={String(account.digits)} />
      <Detail.Metadata.Label title="Period" text={`${account.period} seconds`} />
    </Detail.Metadata>}
    actions={<ActionPanel>
      <Action title="Copy Setup Key" icon={Icon.Key} onAction={() => copySecret(account.secret)} />
      <Action title="Copy Otp Auth Uri" icon={Icon.Link} onAction={() => copySecret(toURI(account))} />
    </ActionPanel>} />;
}

type EditValues = { issuer: string; name: string; secret: string; algorithm: string; digits: string; period: string };

export function EditAccount({ account, onSave }: { account: Account; onSave: (next: Account) => Promise<void> }) {
  const { pop } = useNavigation();
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  async function submit(values: EditValues) {
    if (busy) return;
    let next: Account;
    try { next = editAccount(account, values); }
    catch { setError("Check the names, Base32 key, algorithm, digits, and period (1–3600 seconds)."); return; }
    setBusy(true);
    try {
      await onSave(next);
      await showToast({ style: Toast.Style.Success, title: "Account updated" });
      pop();
    } catch {
      await showToast({ style: Toast.Style.Failure, title: "Could not save account" });
    } finally { setBusy(false); }
  }
  return <Form navigationTitle="Edit Account" isLoading={busy}
    actions={<ActionPanel><Action.SubmitForm title="Save Changes" icon={Icon.Check} onSubmit={submit} /></ActionPanel>}>
    <Form.TextField id="issuer" title="Service" defaultValue={account.issuer} />
    <Form.TextField id="name" title="Account" defaultValue={account.name} />
    <Form.PasswordField id="secret" title="Setup Key" defaultValue={account.secret} />
    <Form.Dropdown id="algorithm" title="Algorithm" defaultValue={account.algorithm}>
      {["SHA1", "SHA256", "SHA512"].map(value => <Form.Dropdown.Item key={value} value={value} title={value} />)}
    </Form.Dropdown>
    <Form.Dropdown id="digits" title="Digits" defaultValue={String(account.digits)}>
      {[6, 7, 8].map(value => <Form.Dropdown.Item key={value} value={String(value)} title={String(value)} />)}
    </Form.Dropdown>
    <Form.TextField id="period" title="Period (Seconds)" defaultValue={String(account.period)} />
    {error ? <Form.Description title="Check Fields" text={error} /> : null}
  </Form>;
}

export function ExportAccounts({ accounts }: { accounts: Account[] }) {
  const { pop } = useNavigation();
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  async function submit(values: { folder: string[]; filename: string }) {
    if (busy) return;
    const filename = values.filename.trim();
    if (values.folder.length !== 1 || !filename || basename(filename) !== filename || filename === "." || filename === ".." || filename.includes("\0")) {
      setError("Choose a folder and enter a valid filename."); return;
    }
    setBusy(true);
    try {
      await writeFile(join(values.folder[0], filename), accounts.map(toURI).join("\n") + "\n", { encoding: "utf8", flag: "wx", mode: 0o600 });
      await showToast({ style: Toast.Style.Success, title: `Exported ${accounts.length} account${accounts.length === 1 ? "" : "s"}`, message: filename });
      pop();
    } catch (e) {
      setError((e as NodeJS.ErrnoException).code === "EEXIST" ? "That file already exists. Choose another name." : "Could not write the file. Check the folder and filename.");
    } finally { setBusy(false); }
  }
  return <Form navigationTitle="Export TOTP Accounts" isLoading={busy}
    actions={<ActionPanel><Action.SubmitForm title="Export File" icon={Icon.Download} onSubmit={submit} /></ActionPanel>}>
    <Form.Description title="Export" text={`${accounts.length} account${accounts.length === 1 ? "" : "s"} as standard otpauth:// entries. The file contains unencrypted setup keys. Keep it private.`} />
    <Form.FilePicker id="folder" title="Save To" canChooseDirectories canChooseFiles={false} allowMultipleSelection={false} defaultValue={[join(homedir(), "Downloads")]} />
    <Form.TextField id="filename" title="Filename" defaultValue={`2fa-export-${new Date().toISOString().replace(/[:.]/g, "-")}.txt`} />
    {error ? <Form.Description title="Export Failed" text={error} /> : null}
  </Form>;
}
