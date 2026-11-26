import { showToast, Toast } from "@raycast/api";
import { useCallback, useEffect, useState } from "react";
import { rawRequest, request, Snapshot } from "./bridge";

export function useSnapshot(fetchMail = false) {
  const [snapshot, setSnapshot] = useState<Snapshot>();
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string>();
  const refresh = useCallback(async () => {
    setLoading(true);
    try {
      setSnapshot(await request({ action: fetchMail ? "refresh" : "list", value: fetchMail }));
      setError(undefined);
    } catch (error) {
      const message = error instanceof Error ? error.message : "Connection Failed";
      setError(message);
      await showToast({ style: Toast.Style.Failure, title: "Could Not Load Codes", message });
    } finally { setLoading(false); }
  }, [fetchMail]);
  useEffect(() => {
    let active = true;
    let polling = false;
    (async () => {
      try {
        const first = await request({ action: "list" });
        if (!active) return;
        setSnapshot(first);
        setLoading(false);
        if (fetchMail && first.accounts.some(({ account }) => account.enabled)) {
          const refreshed = await request({ action: "refresh" });
          if (active) setSnapshot(refreshed);
        }
      } catch (error) {
        if (active) setError(error instanceof Error ? error.message : "Could not connect to InboxCode");
      } finally { if (active) setLoading(false); }
    })();
    const interval = setInterval(async () => {
      if (polling) return;
      polling = true;
      try { const next = await rawRequest({ action: "list" }); if (active) setSnapshot(next); }
      catch { /* Explicit refresh reports connection errors without repetitive toasts. */ }
      finally { polling = false; }
    }, 1000);
    return () => { active = false; clearInterval(interval); };
  }, [fetchMail]);
  return { snapshot, setSnapshot, loading, error, refresh };
}
