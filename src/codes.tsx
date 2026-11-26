import { Action, ActionPanel, Clipboard, Color, Icon, List, closeMainWindow, showHUD } from "@raycast/api";
import { ReactElement, useCallback, useEffect, useMemo, useState } from "react";
import { Account, formatCode, remaining, totp } from "./totp";
import { loadAccounts, saveAccounts } from "./storage";
import { AccountOptions } from "./manage";

async function copyCode(account: Account) {
  // Recompute on activation so a rollover never copies a stale rendered code.
  await Clipboard.copy(totp(account), { concealed: true });
  await closeMainWindow();
  await showHUD("Copied " + account.issuer + " code");
}

function CodeRow({ account, actions, paused }: { account: Account; actions?: ReactElement; paused: boolean }) {
  const [now, setNow] = useState(Date.now());
  useEffect(() => {
    if (paused) return;
    setNow(Date.now());
    const timer = setInterval(() => setNow(Date.now()), 1000);
    return () => clearInterval(timer);
  }, [paused]);
  const seconds = remaining(account, now);
  return <List.Item id={account.id}
    icon={{ source: Icon.Key, tintColor: Color.Purple }}
    title={account.issuer}
    subtitle={{ value: account.name || "—", tooltip: account.name || "No account name" }}
    keywords={[account.issuer, account.name]}
    accessories={[
      // Figure spaces reserve the same numeric width for 6-, 7-, and 8-digit codes.
      { text: formatCode(totp(account, now)).padStart(9, "\u2007"), tooltip: "Verification code — press Return to copy" },
      { tag: { value: `${String(seconds).padStart(2, "0")}s`, color: seconds <= 5 ? Color.Orange : Color.SecondaryText }, tooltip: "Refreshes automatically" },
    ]}
    actions={actions}
  />;
}

export default function Command() {
  const [accounts, setAccounts] = useState<Account[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");
  const [paused, setPaused] = useState(false);
  const updateAccount = useCallback(async (next: Account) => {
    const updated = accounts.map(account => account.id === next.id ? next : account)
      .sort((a, b) => a.issuer.localeCompare(b.issuer) || a.name.localeCompare(b.name));
    await saveAccounts(updated);
    setAccounts(updated);
  }, [accounts]);
  // Keep action identities stable while the countdown renders; an open menu or
  // pushed form must not be recreated on each clock tick.
  const actions = useMemo(() => new Map(accounts.map(account => [account.id,
    <ActionPanel key={account.id}>
      <Action title="Copy Code" icon={Icon.Clipboard} onAction={() => copyCode(account)} />
      <Action.Push title="Account Options" icon={Icon.Gear} shortcut={{ modifiers: ["cmd"], key: "return" }}
        onPush={() => setPaused(true)} onPop={() => setPaused(false)}
        target={<AccountOptions account={account} accounts={accounts} onSave={updateAccount} />} />
    </ActionPanel>
  ])), [accounts, updateAccount]);
  useEffect(() => {
    let alive = true;
    loadAccounts().then((items) => { if (alive) setAccounts(items); })
      .catch(() => { if (alive) setError("Could not load your accounts. Check the local import setup."); })
      .finally(() => { if (alive) setLoading(false); });
    return () => { alive = false; };
  }, []);
  return (
    <List isLoading={loading} searchBarPlaceholder="Search accounts…  ⌘↵ Account options" navigationTitle="AuthCode">
      {error ? <List.EmptyView icon={Icon.Lock} title="Accounts unavailable" description={error} /> : null}
      {accounts.map(account => <CodeRow key={account.id} account={account} actions={actions.get(account.id)} paused={paused} />)}
    </List>
  );
}
