import { Action, ActionPanel, Alert, Color, Icon, List, confirmAlert, showHUD, showToast, Toast } from "@raycast/api";
import { AccountForm } from "./account-form";
import { MailAccount, request } from "./bridge";
import { useSnapshot } from "./use-snapshot";

export default function Accounts() {
  const { snapshot, setSnapshot, loading, error, refresh } = useSnapshot();
  async function update(action: string, value: boolean, id?: string) {
    try { setSnapshot(await request({ action, value, id })); }
    catch (error) { await showToast({ style: Toast.Style.Failure, title: "设置失败", message: String(error) }); }
  }
  async function remove(account: MailAccount) {
    if (!await confirmAlert({ title: `移除 ${account.name || account.username}？`, primaryAction: { title: "移除", style: Alert.ActionStyle.Destructive } })) return;
    try { setSnapshot(await request({ action: "remove", id: account.id })); }
    catch (error) { await showToast({ style: Toast.Style.Failure, title: "移除失败", message: String(error) }); }
  }
  async function quit() {
    try { await request({ action: "quit" }); await showHUD("InboxCode 后台已退出"); }
    catch (error) { await showToast({ style: Toast.Style.Failure, title: "退出失败", message: String(error) }); }
  }
  const add = <Action.Push title="添加邮箱" icon={Icon.Plus} target={<AccountForm onSaved={refresh} />} shortcut={{ modifiers: ["cmd"], key: "n" }} />;
  return (
    <List isLoading={loading} navigationTitle="邮箱" searchBarPlaceholder="搜索邮箱">
      {!snapshot?.accounts.length && <List.EmptyView title={error || "连接邮箱"} icon={Icon.Envelope} actions={<ActionPanel>{add}<Action title="重试" onAction={refresh} /></ActionPanel>} />}
      <List.Section title="邮箱">
        {snapshot?.accounts.map(({ account, online, error }) => (
          <List.Item key={account.id} title={account.name || account.username} subtitle={account.name ? account.username : undefined}
            icon={{ source: Icon.Envelope, tintColor: online ? Color.Green : Color.SecondaryText }}
            accessories={[{ text: !account.enabled ? "已停用" : online ? "监听中" : error ? "连接失败" : "连接中" }]}
            actions={<ActionPanel>
              <Action.Push title="编辑邮箱" icon={Icon.Pencil} target={<AccountForm account={account} onSaved={refresh} />} />
              {add}
              <Action title={account.enabled ? "停用邮箱" : "启用邮箱"} onAction={() => update("enable", !account.enabled, account.id)} />
              {error && <Action title="查看错误" onAction={() => showToast({ style: Toast.Style.Failure, title: "连接失败", message: error })} />}
              <Action title="移除邮箱" icon={Icon.Trash} style={Action.Style.Destructive} onAction={() => remove(account)} shortcut={{ modifiers: ["ctrl"], key: "x" }} />
            </ActionPanel>}
          />
        ))}
        <List.Item title="添加邮箱" icon={Icon.Plus} actions={<ActionPanel>{add}</ActionPanel>} />
      </List.Section>
      {snapshot && <List.Section title="后台">
        {[
          { action: "autoCopy", title: "自动复制", value: snapshot.autoCopy, icon: Icon.Clipboard },
          { action: "showPopup", title: "弹窗提醒", value: snapshot.showPopup, icon: Icon.Window },
          { action: "launchAtLogin", title: "开机启动", value: snapshot.launchAtLogin, icon: Icon.Power },
          { action: "pause", title: "暂停监听", value: snapshot.paused, icon: Icon.Pause },
        ].map((option) => <List.Item key={option.action} title={option.title} icon={option.icon}
          accessories={[{ text: option.value ? "开启" : "关闭" }]}
          actions={<ActionPanel><Action title={option.value ? "关闭" : "开启"} onAction={() => update(option.action, !option.value)} /></ActionPanel>} />)}
        <List.Item title="退出后台" icon={Icon.Power} actions={<ActionPanel><Action title="退出后台" icon={Icon.Power} onAction={quit} /></ActionPanel>} />
      </List.Section>}
    </List>
  );
}
