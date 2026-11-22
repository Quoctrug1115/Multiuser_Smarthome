import { useEffect, useState } from 'react';
import type { AiAlert, AiSuggestion, Device, SensorData, UserProfile } from '../types/smarthome';
import { WS_URL } from '../utils/api';

interface UseSmartHomeSocketOptions {
  currentUser: UserProfile | null;
  setSensorData: React.Dispatch<React.SetStateAction<SensorData | null>>;
  setDevices: React.Dispatch<React.SetStateAction<Device[]>>;
  setAiAlerts: React.Dispatch<React.SetStateAction<AiAlert[]>>;
  setAiSuggestions?: React.Dispatch<React.SetStateAction<AiSuggestion[]>>;
  appendLog: (msg: string) => void;
}

function getStoredToken(): string | null {
  try {
    return (
      localStorage.getItem('token') ||
      localStorage.getItem('access_token') ||
      localStorage.getItem('smarthome_token') ||
      localStorage.getItem('jwt')
    );
  } catch {
    return null;
  }
}

function buildAuthenticatedWsUrl(baseUrl: string): string {
  const token = getStoredToken()?.trim();
  if (!token || /[?&]token=/.test(baseUrl)) {
    return baseUrl;
  }
  const separator = baseUrl.includes('?') ? '&' : '?';
  return `${baseUrl}${separator}token=${encodeURIComponent(token)}`;
}

function normalizeTopic(topic: unknown): string {
  if (typeof topic !== 'string') return '';
  return topic.trim().replace(/\/+$/, '').toLowerCase();
}

function isSameTenant(data: Record<string, unknown>, tenantId: string): boolean {
  const normalizedTenant = tenantId.trim().toLowerCase();
  if (Array.isArray(data.owner_ids) && data.owner_ids.length > 0) {
    return data.owner_ids.some(
      (id) => typeof id === 'string' && id.trim().toLowerCase() === normalizedTenant
    );
  }
  const msgOwnerId = data.owner_id;
  if (msgOwnerId === null || msgOwnerId === undefined || msgOwnerId === '') {
    return true;
  }
  return String(msgOwnerId).trim().toLowerCase() === normalizedTenant;
}

export function useSmartHomeSocket({
  currentUser,
  setSensorData,
  setDevices,
  setAiAlerts,
  setAiSuggestions,
  appendLog,
}: UseSmartHomeSocketOptions) {
  const [wsConnected, setWsConnected] = useState(false);

  useEffect(() => {
    if (!currentUser) {
      setWsConnected(false);
      return;
    }

    const tenantId = currentUser.owner_id || currentUser.id;
    let ws: WebSocket | null = null;
    let reconnectTimer: ReturnType<typeof setTimeout>;
    let isUnmounted = false;

    const connectWs = () => {
      if (isUnmounted) return;

      try {
        ws = new WebSocket(buildAuthenticatedWsUrl(WS_URL));

        ws.onopen = () => {
          if (!isUnmounted) {
            setWsConnected(true);
          }
        };

        ws.onmessage = (event) => {
          try {
            const msg = JSON.parse(event.data);

            if (msg.type === 'SENSOR_UPDATE' && msg.data) {
              if (!isSameTenant(msg.data, tenantId)) {
                return;
              }
              setSensorData((prev) => ({
                temperature: Number(msg.data.temperature ?? prev?.temperature ?? 0),
                humidity: Number(msg.data.humidity ?? prev?.humidity ?? 0),
                lux: Number(msg.data.lux ?? prev?.lux ?? 0),
                motion: Boolean(msg.data.motion ?? prev?.motion ?? false),
              }));
            } else if (msg.type === 'DEVICE_UPDATE' && msg.data) {
              if (!isSameTenant(msg.data, tenantId)) {
                return;
              }

              const incomingTopic = normalizeTopic(msg.data.mqtt_topic);
              const nextIsOn =
                typeof msg.data.is_on === 'boolean'
                  ? msg.data.is_on
                  : String(msg.data.status ?? '').toUpperCase() === 'ON';

              setDevices((prev) =>
                prev.map((d) => {
                  const isMatch =
                    (msg.data.id && d.id === msg.data.id) ||
                    (incomingTopic !== '' && normalizeTopic(d.mqtt_topic) === incomingTopic);

                  if (!isMatch) return d;

                  return {
                    ...d,
                    is_on: nextIsOn,
                    is_online:
                      typeof msg.data.is_online === 'boolean'
                        ? msg.data.is_online
                        : d.is_online,
                  };
                })
              );
            } else if (msg.type === 'AI_ALERT' && msg.data) {
              if (isSameTenant(msg.data, tenantId)) {
                setAiAlerts((prev) => [msg.data, ...prev].slice(0, 30));
                appendLog(`AI ALERT: ${msg.data.message}`);
              }
            } else if (msg.type === 'AI_SUGGESTION' && msg.data) {
              if (isSameTenant(msg.data, tenantId)) {
                setAiSuggestions?.((prev) => {
                  if (prev.some((item) => item.id === msg.data.id)) {
                    return prev;
                  }
                  return [msg.data, ...prev].slice(0, 20);
                });
                appendLog(`AI GỢI Ý: ${msg.data.title}`);
              }
            }
          } catch {
            // ignore non-JSON frames
          }
        };

        ws.onclose = () => {
          setWsConnected(false);
          if (!isUnmounted) {
            reconnectTimer = setTimeout(connectWs, 4000);
          }
        };

        ws.onerror = () => {
          setWsConnected(false);
        };
      } catch {
        setWsConnected(false);
        if (!isUnmounted) {
          reconnectTimer = setTimeout(connectWs, 4000);
        }
      }
    };

    connectWs();

    return () => {
      isUnmounted = true;
      clearTimeout(reconnectTimer);
      if (ws) {
        ws.onclose = null;
        ws.close();
      }
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [currentUser?.id, currentUser?.owner_id]);

  return wsConnected;
}