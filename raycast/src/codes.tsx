import { Action, ActionPanel, Color, Icon, List, showHUD, showToast, Toast } from "@raycast/api";
import Accounts from "./accounts";
import { AccountForm } from "./account-form";
import { LatestCode, request } from "./bridge";
import { useSnapshot } from "./use-snapshot";

export default function Codes() {
  const { snapshot, loading, error, refresh } = useSnapshot(true);
  async function copy(code: LatestCode) {
    try { await request({ action: "copy", id: code.id }); await showHUD(code.kind === "link" ? "Link Copied" : "Code Copied"); }
    catch (error) { await showToast({ style: Toast.Style.Failure, title: "Could Not Copy", message: String(error) }); }
  }
  const sharedActions = <>
    <Action title="Refresh" icon={Icon.ArrowClockwise} onAction={refresh} shortcut={{ modifiers: ["cmd"], key: "r" }} />
    <Action.Push title="Manage Accounts" icon={Icon.Gear} target={<Accounts />} shortcut={{ modifiers: ["cmd"], key: "," }} />
    <Action.Push title="Add Account" icon={Icon.Plus} target={<AccountForm onSaved={refresh} />} shortcut={{ modifiers: ["cmd"], key: "n" }} />
  </>;
  const codes = new Map(snapshot?.codes.map((code) => [code.accountID, code]));
  const accounts = snapshot?.accounts.filter(({ account }) => account.enabled).sort((a, b) => (codes.get(b.account.id)?.receivedAt || 0) - (codes.get(a.account.id)?.receivedAt || 0)) || [];
  return (
    <List isLoading={loading || accounts.some(({ lookupState }) => lookupState && lookupState !== "idle")} navigationTitle="Codes" searchBarPlaceholder="Search services, accounts, codes, and links">
      {!accounts.length && <List.EmptyView title={error || "Connect Account"} icon={Icon.Envelope}
        actions={<ActionPanel><Action.Push title="Connect Account" target={<AccountForm onSaved={refresh} />} />{sharedActions}</ActionPanel>} />}
      {accounts.map(({ account, error: accountError, lookupState, cacheReady, online }) => {
        const code = codes.get(account.id);
        const old = code && Date.now() / 1000 - code.receivedAt > 600;
        const isLink = code?.kind === "link";
        let displayValue = code?.code;
        if (isLink) {
          try { displayValue = new URL(code!.code).hostname; } catch { displayValue = "Link"; }
        }
        return <List.Item key={account.id}
          title={code?.provider || account.name || account.username}
          subtitle={displayValue || (lookupState && lookupState !== "idle"
            ? ({ queued: "Queued", connecting: "Connecting", checking: "Checking", searching: "Searching" })[lookupState]
            : accountError ? "Connection Failed" : cacheReady ? "No Code Found" : online ? "Not Checked" : "Connecting")}
          icon={{ source: isLink ? Icon.Link : code ? Icon.Key : Icon.Envelope, tintColor: code ? Color.Blue : Color.SecondaryText }}
          keywords={[account.username, account.name, code?.code || "", code?.sender || ""]}
          accessories={[
            { text: account.name || account.username, tooltip: account.username },
            ...(old ? [{ tag: { value: "Older", color: Color.Orange }, tooltip: "This email is over 10 minutes old. Its code or link may have expired." }] : []),
            ...(code ? [{ date: new Date(code.receivedAt * 1000), tooltip: new Date(code.receivedAt * 1000).toLocaleString() }] : []),
          ]}
          actions={<ActionPanel>
            {code && <Action title={isLink ? "Copy Link" : "Copy Code"} icon={Icon.Clipboard} onAction={() => copy(code)} />}
            {sharedActions}
            {accountError && <Action title="Show Error" onAction={() => showToast({ style: Toast.Style.Failure, title: "Connection Failed", message: accountError })} />}
          </ActionPanel>}
        />;
      })}
    </List>
  );
}
