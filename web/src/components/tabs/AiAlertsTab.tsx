import { useEffect, useMemo, useState } from 'react';
import type { AiAlert, AiSuggestion, Device, SensorData } from '../../types/smarthome';
import { API_BASE, getAuthHeaders } from '../../utils/api';

interface AiAlertsTabProps {
  aiAlerts: AiAlert[];
  aiSuggestions: AiSuggestion[];
  setAiSuggestions: React.Dispatch<React.SetStateAction<AiSuggestion[]>>;
  devices: Device[];
  sensorData: SensorData | null;
  isOwnerOrAdmin: boolean;
  cardBg: string;
  appendLog: (msg: string) => void;
  onRefresh: () => Promise<void>;
}

export function AiAlertsTab({
  aiAlerts,
  aiSuggestions,
  setAiSuggestions,
  devices,
  sensorData,
  isOwnerOrAdmin,
  cardBg,
  appendLog,
  onRefresh,
}: AiAlertsTabProps) {
  const [isAnalyzing, setIsAnalyzing] = useState(false);
  const [isSimulating, setIsSimulating] = useState(false);
  const [processingId, setProcessingId] = useState<string | null>(null);

  // Lọc danh sách cảm biến thật có trong hộ gia đình
  const realSensors = useMemo(() => {
    return devices.filter((d) => {
      const t = (d.device_type || '').toLowerCase();
      const topic = (d.mqtt_topic || '').toLowerCase();
      return (
        t === 'sensor' ||
        t === 'dht22' ||
        topic.includes('sensor') ||
        topic.includes('dht') ||
        topic.includes('telemetry')
      );
    });
  }, [devices]);

  const [selectedSensorId, setSelectedSensorId] = useState<string>('');

  useEffect(() => {
    if (realSensors.length === 0) {
      setSelectedSensorId('');
      return;
    }
    if (!realSensors.some((s) => s.id === selectedSensorId)) {
      setSelectedSensorId(realSensors[0].id);
    }
  }, [realSensors, selectedSensorId]);

  const activeSensor = useMemo(
    () => realSensors.find((s) => s.id === selectedSensorId) || realSensors[0] || null,
    [realSensors, selectedSensorId]
  );

  // Tính công suất tải thực tế từ các thiết bị thật đang bật trong nhà
  const activePowerWatt = useMemo(() => {
    return devices
      .filter((d) => d.is_on)
      .reduce((sum, d) => {
        const t = (d.device_type || '').toLowerCase();
        if (t.includes('ac') || t.includes('air') || t.includes('heater')) return sum + 1200;
        if (t.includes('fan')) return sum + 45;
        if (t.includes('light')) return sum + 15;
        if (t.includes('sensor')) return sum + 2;
        return sum + 25;
      }, 0);
  }, [devices]);

  const hasLiveSensor = sensorData !== null && realSensors.length > 0;

  // Mô phỏng bất thường dựa trên cảm biến THẬT và nền nhiệt độ THẬT
  const handleSimulateAnomaly = async () => {
    if (!activeSensor) {
      appendLog('Chưa có cảm biến thật trong nhà để mô phỏng bất thường.');
      return;
    }

    setIsSimulating(true);
    try {
      // Nếu có dữ liệu live từ cảm biến thì truyền điểm đột biến dựa trên nhiệt độ thật đang đo,
      // nếu chưa có gói tin live thì để Backend tự tính từ lịch sử dbo.sensor_data của cảm biến này
      const payload: Record<string, unknown> = {
        device_id: activeSensor.id,
      };
      if (hasLiveSensor && sensorData && sensorData.temperature > 0) {
        payload.temperature = Number((sensorData.temperature + 16.5).toFixed(1));
      }

      const res = await fetch(`${API_BASE}/ai/simulate-anomaly`, {
        method: 'POST',
        headers: getAuthHeaders(),
        body: JSON.stringify(payload),
      });

      const data = await res.json().catch(() => null);
      if (res.ok) {
        appendLog(
          data?.message || `Đã kiểm thử cảnh báo bất thường trên ${activeSensor.name}.`
        );
        await onRefresh();
      } else {
        appendLog(data?.error || 'Không thể mô phỏng bất thường trên cảm biến.');
      }
    } finally {
      setIsSimulating(false);
    }
  };

  const handleAnalyzeSuggestions = async () => {
    setIsAnalyzing(true);
    try {
      const res = await fetch(`${API_BASE}/ai/suggestions/analyze`, {
        method: 'POST',
        headers: getAuthHeaders(),
      });
      if (res.ok) {
        const data = await res.json();
        appendLog(data?.message || 'Đã hoàn tất phân tích thói quen & gợi ý AI.');
        await onRefresh();
      }
    } finally {
      setIsAnalyzing(false);
    }
  };

  const handleApplySuggestion = async (sug: AiSuggestion) => {
    setProcessingId(sug.id);
    try {
      const res = await fetch(`${API_BASE}/ai/suggestions/${sug.id}/apply`, {
        method: 'POST',
        headers: getAuthHeaders(),
      });
      if (res.ok) {
        const data = await res.json();
        setAiSuggestions((prev) => prev.filter((item) => item.id !== sug.id));
        appendLog(data?.message || `Đã áp dụng gợi ý: ${sug.title}`);
        await onRefresh();
      }
    } finally {
      setProcessingId(null);
    }
  };

  const handleDismissSuggestion = async (sug: AiSuggestion) => {
    setProcessingId(sug.id);
    try {
      const res = await fetch(`${API_BASE}/ai/suggestions/${sug.id}/dismiss`, {
        method: 'POST',
        headers: getAuthHeaders(),
      });
      if (res.ok) {
        setAiSuggestions((prev) => prev.filter((item) => item.id !== sug.id));
        appendLog(`Đã bỏ qua gợi ý AI: ${sug.title}`);
      }
    } finally {
      setProcessingId(null);
    }
  };

  const getSuggestionBadge = (type: string) => {
    const normalized = (type || '').toUpperCase();
    if (normalized === 'ENERGY') {
      return {
        label: '⚡ Tiết kiệm điện',
        badgeClass: 'bg-emerald-500/15 text-emerald-400 border-emerald-500/30',
        cardAccent: 'border-emerald-500/30',
      };
    }
    if (normalized === 'COMFORT') {
      return {
        label: 'Tiện nghi cảm biến',
        badgeClass: 'bg-amber-500/15 text-amber-400 border-amber-500/30',
        cardAccent: 'border-amber-500/30',
      };
    }
    return {
      label: 'Thói quen sử dụng',
      badgeClass: 'bg-cyan-500/15 text-cyan-400 border-cyan-500/30',
      cardAccent: 'border-cyan-500/30',
    };
  };

  return (
    <div className="space-y-6">
      {/* Header + Chọn cảm biến thật để kiểm thử Z-Score */}
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div>
          <h1 className="text-lg font-bold">Trung tâm Trợ lý & Giám sát An ninh AI</h1>
        </div>

        <div className="flex flex-wrap items-center gap-2">
          <button
            onClick={handleAnalyzeSuggestions}
            disabled={isAnalyzing}
            className="px-4 py-2 rounded-xl bg-cyan-500 hover:bg-cyan-400 disabled:opacity-50 text-slate-950 font-bold text-xs transition"
          >
            {isAnalyzing ? 'Đang phân tích...' : 'Quét gợi ý AI'}
          </button>

          {isOwnerOrAdmin && (
            <div className="flex items-center gap-2">
              {realSensors.length > 1 && (
                <select
                  value={selectedSensorId}
                  onChange={(e) => setSelectedSensorId(e.target.value)}
                  className="px-3 py-2 rounded-xl bg-slate-900/80 border border-slate-700 text-xs text-slate-200"
                >
                  {realSensors.map((s) => (
                    <option key={s.id} value={s.id}>
                      {s.name} {s.room_name ? `(${s.room_name})` : ''}
                    </option>
                  ))}
                </select>
              )}

              <button
                onClick={handleSimulateAnomaly}
                disabled={isSimulating || !activeSensor}
                title={
                  activeSensor
                    ? `Kiểm thử cảnh báo Z-Score trên ${activeSensor.name}`
                    : 'Chưa có thiết bị cảm biến thật trong nhà'
                }
                className="px-4 py-2 rounded-xl bg-rose-500 hover:bg-rose-400 disabled:opacity-50 text-white font-bold text-xs transition"
              >
                {isSimulating
                  ? 'Đang tính Z-Score...'
                  : activeSensor
                  ? `Kiểm thử bất thường (${activeSensor.name})`
                  : 'Chưa có cảm biến thật'}
              </button>
            </div>
          )}
        </div>
      </div>

      {/* DẢI CHỈ SỐ CẢM BIẾN & TẢI ĐIỆN THỰC TẾ ĐANG ĐO */}
      <div className="grid grid-cols-2 lg:grid-cols-4 gap-3">
        <div className={`p-3.5 rounded-xl border ${cardBg}`}>
          <div className="text-[11px] text-slate-400">Nhiệt độ thực tế</div>
          <div className="text-lg font-bold text-amber-400 mt-0.5">
            {hasLiveSensor && sensorData ? `${sensorData.temperature.toFixed(1)}°C` : '-- °C'}
          </div>
          <div className="text-[10px] text-slate-500 truncate mt-0.5">
            {activeSensor ? activeSensor.name : 'Chưa kết nối cảm biến'}
          </div>
        </div>

        <div className={`p-3.5 rounded-xl border ${cardBg}`}>
          <div className="text-[11px] text-slate-400">Độ ẩm thực tế</div>
          <div className="text-lg font-bold text-cyan-400 mt-0.5">
            {hasLiveSensor && sensorData ? `${sensorData.humidity.toFixed(0)}%` : '-- %'}
          </div>
          <div className="text-[10px] text-slate-500 truncate mt-0.5">
            {activeSensor?.room_name || 'Luồng MQTT thời gian thực'}
          </div>
        </div>

        <div className={`p-3.5 rounded-xl border ${cardBg}`}>
          <div className="text-[11px] text-slate-400">Ánh sáng / PIR</div>
          <div className="text-lg font-bold text-emerald-400 mt-0.5">
            {hasLiveSensor && sensorData ? `${sensorData.lux} Lux` : '-- Lux'}
          </div>
          <div className="text-[10px] text-slate-500 truncate mt-0.5">
            {hasLiveSensor && sensorData
              ? sensorData.motion
                ? 'Đang có chuyển động'
                : 'Không có chuyển động'
              : 'Đang chờ dữ liệu'}
          </div>
        </div>

        <div className={`p-3.5 rounded-xl border ${cardBg}`}>
          <div className="text-[11px] text-slate-400">Công suất tải thực tế</div>
          <div className="text-lg font-bold text-sky-400 mt-0.5">~{activePowerWatt} W</div>
          <div className="text-[10px] text-slate-500 truncate mt-0.5">
            {devices.filter((d) => d.is_on).length} / {devices.length} thiết bị đang bật
          </div>
        </div>
      </div>

      {/* PHẦN 1: GỢI Ý THÔNG MINH DÀNH CHO NGƯỜI DÙNG */}
      <div className={`p-5 rounded-2xl border space-y-3 ${cardBg}`}>
        <div className="flex items-center justify-between">
          <div>
            <h2 className="text-sm font-bold text-cyan-400">
              Gợi ý thông minh dành cho bạn ({aiSuggestions.length})
            </h2>
          </div>
        </div>

        {aiSuggestions.length === 0 ? (
          <div className="p-6 rounded-xl bg-slate-900/60 border border-slate-800 text-center text-xs text-slate-400">
            Chưa có gợi ý mới. Hệ thống đang tiếp tục học thói quen sử dụng thiết bị hàng ngày của bạn.
          </div>
        ) : (
          <div className="grid grid-cols-1 lg:grid-cols-2 gap-3">
            {aiSuggestions.map((sug) => {
              const meta = getSuggestionBadge(sug.suggestion_type);
              const confidencePct = Math.round((sug.confidence_score || 0.8) * 100);
              const isAutomation =
                (sug.suggested_action?.mode || '').toUpperCase() === 'AUTOMATION';
              const isBusy = processingId === sug.id;

              return (
                <div
                  key={sug.id}
                  className={`p-4 rounded-xl bg-slate-900/60 border flex flex-col justify-between gap-3 ${meta.cardAccent}`}
                >
                  <div className="space-y-1.5">
                    <div className="flex flex-wrap items-center justify-between gap-2">
                      <span
                        className={`px-2 py-0.5 rounded-md border text-[10px] font-bold ${meta.badgeClass}`}
                      >
                        {meta.label}
                      </span>
                      <div className="flex items-center gap-2 text-[11px] font-mono text-slate-400">
                        <span className="px-2 py-0.5 rounded bg-slate-800 text-cyan-300">
                          Tin cậy {confidencePct}%
                        </span>
                        <span>{sug.created_at}</span>
                      </div>
                    </div>

                    <div className="text-sm font-bold text-slate-100">{sug.title}</div>
                    <p className="text-xs text-slate-300 leading-relaxed">{sug.description}</p>

                    <div className="text-[11px] text-slate-400 pt-0.5">
                      Thiết bị: <span className="font-semibold text-slate-200">{sug.device_name}</span>
                      {sug.room_name ? ` • ${sug.room_name}` : ''}
                    </div>
                  </div>

                  <div className="flex items-center justify-end gap-2 pt-2 border-t border-slate-800/80">
                    <button
                      onClick={() => handleDismissSuggestion(sug)}
                      disabled={isBusy}
                      className="px-3 py-1.5 rounded-lg bg-slate-800 hover:bg-slate-700 disabled:opacity-50 text-slate-300 text-xs font-semibold transition"
                    >
                      Bỏ qua
                    </button>
                    <button
                      onClick={() => handleApplySuggestion(sug)}
                      disabled={isBusy}
                      className="px-3.5 py-1.5 rounded-lg bg-cyan-500 hover:bg-cyan-400 disabled:opacity-50 text-slate-950 text-xs font-bold transition"
                    >
                      {isBusy
                        ? 'Đang xử lý...'
                        : isAutomation
                        ? '✓ Tạo kịch bản tự động'
                        : '✓ Áp dụng ngay'}
                    </button>
                  </div>
                </div>
              );
            })}
          </div>
        )}
      </div>

      {/* PHẦN 2: CẢNH BÁO BẤT THƯỜNG CẢM BIẾN THỰC TẾ */}
      <div className="space-y-3">
        <h2 className="text-sm font-bold text-rose-400">
          Cảnh báo bất thường cảm biến ({aiAlerts.length})
        </h2>

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
    </div>
  );
}