import { Action, ActionPanel, Color, Icon, List, showHUD, showToast, Toast } from "@raycast/api";
import Accounts from "./accounts";
import { AccountForm } from "./account-form";
import { LatestCode, request } from "./bridge";
import { useSnapshot } from "./use-snapshot";

export default function Codes() {
  const { snapshot, loading, error, refresh } = useSnapshot(true);
  async function copy(code: LatestCode) {
    try { await request({ action: "copy", id: code.id }); await showHUD("已复制验证码"); }
    catch (error) { await showToast({ style: Toast.Style.Failure, title: "复制失败", message: String(error) }); }
  }
  const sharedActions = <>
    <Action title="刷新" icon={Icon.ArrowClockwise} onAction={refresh} shortcut={{ modifiers: ["cmd"], key: "r" }} />
    <Action.Push title="管理邮箱" icon={Icon.Gear} target={<Accounts />} shortcut={{ modifiers: ["cmd"], key: "," }} />
    <Action.Push title="添加邮箱" icon={Icon.Plus} target={<AccountForm onSaved={refresh} />} shortcut={{ modifiers: ["cmd"], key: "n" }} />
  </>;
  const codes = new Map(snapshot?.codes.map((code) => [code.accountID, code]));
  const accounts = snapshot?.accounts.filter(({ account }) => account.enabled).sort((a, b) => (codes.get(b.account.id)?.receivedAt || 0) - (codes.get(a.account.id)?.receivedAt || 0)) || [];
  return (
    <List isLoading={loading} navigationTitle="验证码" searchBarPlaceholder="搜索服务、邮箱、验证码">
      {!accounts.length && <List.EmptyView title={error || "连接邮箱"} icon={Icon.Envelope}
        actions={<ActionPanel><Action.Push title="连接邮箱" target={<AccountForm onSaved={refresh} />} />{sharedActions}</ActionPanel>} />}
      {accounts.map(({ account, error: accountError }) => {
        const code = codes.get(account.id);
        const old = code && Date.now() / 1000 - code.receivedAt > 600;
        return <List.Item key={account.id}
          title={code?.provider || account.name || account.username}
          subtitle={code?.code || (accountError ? "连接失败" : loading ? "正在查找" : "暂无验证码")}
          icon={{ source: code ? Icon.Key : Icon.Envelope, tintColor: code ? Color.Blue : Color.SecondaryText }}
          keywords={[account.username, account.name, code?.code || "", code?.sender || ""]}
          accessories={[
            { text: account.name || account.username, tooltip: account.username },
            ...(old ? [{ tag: { value: "较早", color: Color.Orange }, tooltip: "这封邮件已超过 10 分钟，验证码可能已失效" }] : []),
            ...(code ? [{ date: new Date(code.receivedAt * 1000), tooltip: new Date(code.receivedAt * 1000).toLocaleString() }] : []),
          ]}
          actions={<ActionPanel>
            {code && <Action title="复制验证码" icon={Icon.Clipboard} onAction={() => copy(code)} />}
            {sharedActions}
            {accountError && <Action title="查看错误" onAction={() => showToast({ style: Toast.Style.Failure, title: "连接失败", message: accountError })} />}
          </ActionPanel>}
        />;
      })}
    </List>
  );
}
