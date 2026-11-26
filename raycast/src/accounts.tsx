import { Action, ActionPanel, Alert, Color, Icon, List, confirmAlert, getPreferenceValues, openExtensionPreferences, showHUD, showToast, Toast } from "@raycast/api";
import { AccountForm } from "./account-form";
import { MailAccount, request } from "./bridge";
import { useSnapshot } from "./use-snapshot";

export default function Accounts() {
  const { snapshot, setSnapshot, loading, error, refresh } = useSnapshot();
  async function update(action: string, value: boolean, id?: string) {
    try { setSnapshot(await request({ action, value, id })); }
    catch (error) { await showToast({ style: Toast.Style.Failure, title: "Could Not Save Settings", message: String(error) }); }
  }
  async function remove(account: MailAccount) {
    if (!await confirmAlert({ title: `Remove ${account.name || account.username}?`, primaryAction: { title: "Remove", style: Alert.ActionStyle.Destructive } })) return;
    try { setSnapshot(await request({ action: "remove", id: account.id })); }
    catch (error) { await showToast({ style: Toast.Style.Failure, title: "Could Not Remove Account", message: String(error) }); }
  }
  async function quit() {
    try { await request({ action: "quit" }); await showHUD("InboxCode Stopped"); }
    catch (error) { await showToast({ style: Toast.Style.Failure, title: "Could Not Quit", message: String(error) }); }
  }
  const add = <Action.Push title="Add Account" icon={Icon.Plus} target={<AccountForm onSaved={refresh} />} shortcut={{ modifiers: ["cmd"], key: "n" }} />;
  return (
    <List isLoading={loading} navigationTitle="Accounts" searchBarPlaceholder="Search accounts">
      {!snapshot?.accounts.length && <List.EmptyView title={error || "Connect Account"} icon={Icon.Envelope} actions={<ActionPanel>{add}<Action title="Retry" onAction={refresh} /></ActionPanel>} />}
      <List.Section title="Accounts">
        {snapshot?.accounts.map(({ account, online, error }) => (
          <List.Item key={account.id} title={account.name || account.username} subtitle={account.name ? account.username : undefined}
            icon={{ source: Icon.Envelope, tintColor: online ? Color.Green : Color.SecondaryText }}
            accessories={[{ text: !account.enabled ? "Disabled" : online ? "Listening" : error ? "Connection Failed" : "Connecting" }]}
            actions={<ActionPanel>
              <Action.Push title="Edit Account" icon={Icon.Pencil} target={<AccountForm account={account} onSaved={refresh} />} />
              {add}
              <Action title={account.enabled ? "Disable Account" : "Enable Account"} onAction={() => update("enable", !account.enabled, account.id)} />
              {error && <Action title="Show Error" onAction={() => showToast({ style: Toast.Style.Failure, title: "Connection Failed", message: error })} />}
              <Action title="Remove Account" icon={Icon.Trash} style={Action.Style.Destructive} onAction={() => remove(account)} shortcut={{ modifiers: ["ctrl"], key: "x" }} />
            </ActionPanel>}
          />
        ))}
        <List.Item title="Add Account" icon={Icon.Plus} actions={<ActionPanel>{add}</ActionPanel>} />
      </List.Section>
      {snapshot && <List.Section title="Background">
        <List.Item title="Connection" icon={Icon.Network} accessories={[{ text: ({ direct: "Direct", system: "System Settings", socks5: "SOCKS5 Proxy", http: "HTTP Proxy" } as Record<string, string>)[getPreferenceValues().connectionMode || "direct"] }]}
          actions={<ActionPanel><Action title="Connection Settings" onAction={openExtensionPreferences} /></ActionPanel>} />
        {[
          { action: "autoCopy", title: "Auto-Copy", value: snapshot.autoCopy, icon: Icon.Clipboard },
          { action: "showPopup", title: "Show Popups", value: snapshot.showPopup, icon: Icon.Window },
          { action: "launchAtLogin", title: "Launch at Login", value: snapshot.launchAtLogin, icon: Icon.Power },
          { action: "pause", title: "Pause Monitoring", value: snapshot.paused, icon: Icon.Pause },
        ].map((option) => <List.Item key={option.action} title={option.title} icon={option.icon}
          accessories={[{ text: option.value ? "On" : "Off" }]}
          actions={<ActionPanel><Action title={option.value ? "Off" : "On"} onAction={() => update(option.action, !option.value)} /></ActionPanel>} />)}
        <List.Item title="Quit Background Helper" icon={Icon.Power} actions={<ActionPanel><Action title="Quit Background Helper" icon={Icon.Power} onAction={quit} /></ActionPanel>} />
      </List.Section>}
    </List>
  );
}
