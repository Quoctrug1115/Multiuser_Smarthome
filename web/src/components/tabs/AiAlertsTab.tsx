import type { AiAlert } from '../../types/smarthome';
import { API_BASE, getAuthHeaders } from '../../utils/api';

interface AiAlertsTabProps {
  aiAlerts: AiAlert[];
  isOwnerOrAdmin: boolean;
  cardBg: string;
  appendLog: (msg: string) => void;
  onRefresh: () => Promise<void>;
}

export function AiAlertsTab({
  aiAlerts,
  isOwnerOrAdmin,
  cardBg,
  appendLog,
  onRefresh,
}: AiAlertsTabProps) {
  const handleSimulateAnomaly = async () => {
    const res = await fetch(`${API_BASE}/ai/simulate-anomaly`, {
      method: 'POST',
      headers: getAuthHeaders(),
      body: JSON.stringify({ temperature: 65.0, sensor_id: 'ESP32-DHT22-01' }),
    });
    if (res.ok) {
      appendLog('Đã kích hoạt mô phỏng cảnh báo quá nhiệt AI.');
      onRefresh();
    }
  };

  return (
    <div className="space-y-4">
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-lg font-bold">🤖 Trung tâm Giám sát An ninh & Bất thường AI</h1>
          <p className="text-xs text-slate-400">
            Phân tích Z-Score cảm biến thời gian thực riêng cho ngôi nhà của bạn
          </p>
        </div>
        {isOwnerOrAdmin && (
          <button
            onClick={handleSimulateAnomaly}
            className="px-4 py-2 rounded-xl bg-rose-500 hover:bg-rose-400 text-white font-bold text-xs"
          >
            ⚡ Mô phỏng bất thường
          </button>
        )}
      </div>

      {aiAlerts.length === 0 ? (
        <div className={`p-10 rounded-2xl border text-center text-xs text-emerald-400 ${cardBg}`}>
          ✓ Không phát hiện sự cố hay bất thường nào trong ngôi nhà của bạn.
        </div>
      ) : (
        <div className="space-y-3">
          {aiAlerts.map((al) => (
            <div
              key={al.id}
              className="p-4 rounded-2xl bg-rose-500/10 border border-rose-500/30 flex items-center justify-between gap-4"
            >
              <div>
                <div className="text-xs font-bold text-rose-400">{al.title || al.alert_type}</div>
                <div className="text-sm text-slate-200 mt-0.5">{al.message}</div>
              </div>
              <div className="text-xs font-mono text-slate-400 shrink-0">{al.created_at}</div>
            </div>
          ))}
        </div>
      )}
    </div>
  );
}