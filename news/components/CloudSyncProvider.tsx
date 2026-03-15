"use client";

import {
  cloudSyncConfigured,
  pullFromCloud,
  schedulePushToCloud,
  syncRoomId,
} from "@/lib/storage/cloudSync";
import { importSnapshot } from "@/lib/storage/indexeddb";
import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useState,
} from "react";

type Ctx = {
  syncOn: boolean;
  room: string;
  lastPull: string | null;
  pullNow: () => Promise<void>;
  notifyLocalChange: () => void;
};

const CloudSyncContext = createContext<Ctx | null>(null);

export function useCloudSync() {
  return useContext(CloudSyncContext);
}

const POLL_MS = 10_000;

export default function CloudSyncProvider({
  children,
}: {
  children: React.ReactNode;
}) {
  const [syncOn] = useState(cloudSyncConfigured);
  const [room, setRoom] = useState(syncRoomId);
  const [lastPull, setLastPull] = useState<string | null>(null);

  const pullNow = useCallback(async () => {
    if (!cloudSyncConfigured()) return;
    const snap = await pullFromCloud();
    if (snap && (snap.reports?.length || snap.stories?.length || true)) {
      await importSnapshot(snap);
      setLastPull(new Date().toISOString());
      window.dispatchEvent(new Event("meshnews-sync-pull"));
    }
  }, []);

  useEffect(() => {
    if (!syncOn) return;
    void pullNow();
    const id = setInterval(() => void pullNow(), POLL_MS);
    return () => clearInterval(id);
  }, [syncOn, pullNow]);

  useEffect(() => {
    const onRoom = () => setRoom(syncRoomId());
    window.addEventListener("meshnews-sync-room", onRoom);
    return () => window.removeEventListener("meshnews-sync-room", onRoom);
  }, []);

  const notifyLocalChange = useCallback(() => {
    schedulePushToCloud();
  }, []);

  return (
    <CloudSyncContext.Provider
      value={{
        syncOn,
        room,
        lastPull,
        pullNow,
        notifyLocalChange,
      }}
    >
      {children}
    </CloudSyncContext.Provider>
  );
}
