import { useEffect, useState } from 'react';
import type { AiAlert, Device, SensorData, UserProfile } from '../types/smarthome';
import { WS_URL } from '../utils/api';

interface UseSmartHomeSocketOptions {
  currentUser: UserProfile | null;
  setSensorData: React.Dispatch<React.SetStateAction<SensorData | null>>;
  setDevices: React.Dispatch<React.SetStateAction<Device[]>>;
  setAiAlerts: React.Dispatch<React.SetStateAction<AiAlert[]>>;
  appendLog: (msg: string) => void;
}

export function useSmartHomeSocket({
  currentUser,
  setSensorData,
  setDevices,
  setAiAlerts,
  appendLog,
}: UseSmartHomeSocketOptions) {
  const [wsConnected, setWsConnected] = useState(false);

  useEffect(() => {
    if (!currentUser) {
      setWsConnected(false);
      return;
    }

    let ws: WebSocket | null = null;
    let reconnectTimer: ReturnType<typeof setTimeout>;

    const connectWs = () => {
      try {
        ws = new WebSocket(WS_URL);
        ws.onopen = () => {
          setWsConnected(true);
        };
        ws.onmessage = (event) => {
          try {
            const msg = JSON.parse(event.data);
            if (msg.type === 'SENSOR_UPDATE' && msg.data) {
              setSensorData((prev) => ({
                temperature: Number(msg.data.temperature ?? prev?.temperature ?? 0),
                humidity: Number(msg.data.humidity ?? prev?.humidity ?? 0),
                lux: Number(msg.data.lux ?? prev?.lux ?? 0),
                motion: Boolean(msg.data.motion ?? prev?.motion ?? false),
              }));
            } else if (msg.type === 'DEVICE_UPDATE' && msg.data) {
              setDevices((prev) =>
                prev.map((d) =>
                  d.id === msg.data.id || d.mqtt_topic === msg.data.mqtt_topic
                    ? { ...d, is_on: Boolean(msg.data.is_on) }
                    : d
                )
              );
            } else if (msg.type === 'AI_ALERT' && msg.data) {
              if (
                !msg.data.owner_id ||
                msg.data.owner_id === (currentUser.owner_id || currentUser.id)
              ) {
                setAiAlerts((prev) => [msg.data, ...prev].slice(0, 30));
                appendLog(`AI ALERT: ${msg.data.message}`);
              }
            }
          } catch {
            // ignore non-JSON frames
          }
        };
        ws.onclose = () => {
          setWsConnected(false);
          reconnectTimer = setTimeout(connectWs, 4000);
        };
        ws.onerror = () => {
          setWsConnected(false);
        };
      } catch {
        setWsConnected(false);
      }
    };

    connectWs();
    return () => {
      clearTimeout(reconnectTimer);
      if (ws) ws.close();
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [currentUser?.id]);

  return wsConnected;
}