import { useMemo } from 'react';
import type {
  ActiveTab,
  AiAlert,
  AutomationRule,
  Device,
  EnergyState,
  House,
  Room,
  SensorData,
} from '../../types/smarthome';

interface OverviewTabProps {
  houses: House[];
  rooms: Room[];
  devices: Device[];
  automations: AutomationRule[];
  aiAlerts: AiAlert[];
  energyData: EnergyState;
  sensorData: SensorData | null;
  systemLogs: string[];
  onClearLogs: () => void;
  onNavigateTab: (tab: ActiveTab) => void;
  onToggleDevice: (device: Device) => void;
  cardBg: string;
}

export function OverviewTab({
  houses,
  rooms,
  devices,
  automations,
  aiAlerts,
  energyData,
  sensorData,
  systemLogs,
  onClearLogs,
  onNavigateTab,
  onToggleDevice,
  cardBg,
}: OverviewTabProps) {
  const hasLiveSensor = sensorData !== null && devices.length > 0;

  const activeDevices = useMemo(() => devices.filter((d) => d.is_on), [devices]);

  const estimatedLiveWatt = useMemo(() => {
    return activeDevices.reduce((sum, d) => {
      const t = (d.device_type || '').toLowerCase();
      if (t.includes('ac') || t.includes('air') || t.includes('heater')) return sum + 1200;
      if (t.includes('fan')) return sum + 45;
      if (t.includes('light')) return sum + 15;
      if (t.includes('sensor')) return sum + 2;
      return sum + 25;
    }, 0);
  }, [activeDevices]);

  return (
    <>
      {/* 4 KPI Cards */}
      <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-4">
        <div className={`p-5 rounded-2xl border ${cardBg}`}>
          <div className="flex items-center justify-between text-xs text-slate-400 mb-1">
            <span>Nhiệt độ phòng</span>
            <span className="px-2 py-0.5 rounded bg-amber-500/15 text-amber-400 text-[10px] font-semibold">
              {!hasLiveSensor || !sensorData
                ? 'Chưa kết nối'
                : sensorData.temperature > 31
                ? 'Nóng'
                : sensorData.temperature < 20
                ? 'Lạnh'
                : 'Ổn định'}
            </span>
          </div>
          <div className="text-2xl font-bold text-amber-400">
            {hasLiveSensor && sensorData ? `${sensorData.temperature.toFixed(1)}°C` : '--°C'}
          </div>
          <div className="text-[11px] text-slate-500 mt-1">
            {hasLiveSensor && sensorData
              ? 'Cảm biến DHT22 thời gian thực'
              : 'Chưa có dữ liệu cảm biến nhiệt độ'}
          </div>
        </div>

        <div className={`p-5 rounded-2xl border ${cardBg}`}>
          <div className="flex items-center justify-between text-xs text-slate-400 mb-1">
            <span>Độ ẩm không khí</span>
            <span className="px-2 py-0.5 rounded bg-cyan-500/15 text-cyan-400 text-[10px] font-semibold">
              {!hasLiveSensor || !sensorData
                ? 'Chưa kết nối'
                : sensorData.humidity > 80
                ? 'Ẩm cao'
                : 'Thoáng'}
            </span>
          </div>
          <div className="text-2xl font-bold text-cyan-400">
            {hasLiveSensor && sensorData ? `${sensorData.humidity.toFixed(0)}%` : '--%'}
          </div>
          <div className="text-[11px] text-slate-500 mt-1">Ngưỡng khuyến nghị: 50% – 70%</div>
        </div>

        <div className={`p-5 rounded-2xl border ${cardBg}`}>
          <div className="flex items-center justify-between text-xs text-slate-400 mb-1">
            <span>Ánh sáng / PIR</span>
            <span
              className={`px-2 py-0.5 rounded text-[10px] font-semibold ${
                hasLiveSensor && sensorData?.motion
                  ? 'bg-emerald-500/20 text-emerald-400'
                  : 'bg-slate-800 text-slate-400'
              }`}
            >
              {!hasLiveSensor || !sensorData
                ? 'Chưa kết nối'
                : sensorData.motion
                ? 'Phát hiện người'
                : 'Yên tĩnh'}
            </span>
          </div>
          <div className="text-2xl font-bold text-emerald-400">
            {hasLiveSensor && sensorData ? `${sensorData.lux} Lux` : '-- Lux'}
          </div>
          <div className="text-[11px] text-slate-500 mt-1">
            Cảm biến quang trở LDR & chuyển động
          </div>
        </div>

        <div className={`p-5 rounded-2xl border ${cardBg}`}>
          <div className="flex items-center justify-between text-xs text-slate-400 mb-1">
            <span>Thiết bị & Công suất</span>
            <span className="px-2 py-0.5 rounded bg-sky-500/15 text-sky-400 text-[10px] font-mono">
              ~{estimatedLiveWatt}W
            </span>
          </div>
          <div className="text-2xl font-bold text-sky-400">
            {activeDevices.length} / {devices.length} Bật
          </div>
          <div className="text-[11px] text-slate-500 mt-1">
            Điện năng tích lũy: {energyData.total_kwh.toFixed(3)} kWh
          </div>
        </div>
      </div>

      {/* Row 2: Quick Device Control + Houses & Rooms */}
      <div className="grid grid-cols-1 lg:grid-cols-3 gap-4">
        <div className={`lg:col-span-2 p-5 rounded-2xl border ${cardBg}`}>
          <div className="flex items-center justify-between mb-4">
            <div>
              <h2 className="font-bold text-sm">Điều khiển nhanh Thiết bị IoT</h2>
              <p className="text-xs text-slate-400">
                Bật/tắt trực tiếp thiết bị và theo dõi chỉ số cảm biến thời gian thực qua MQTT
              </p>
            </div>
            <button
              onClick={() => onNavigateTab('devices')}
              className="text-xs text-cyan-400 hover:underline font-semibold"
            >
              Xem tất cả ({devices.length}) →
            </button>
          </div>

          {devices.length === 0 ? (
            <div className="p-8 rounded-xl border border-dashed border-slate-800 text-center text-xs text-slate-500">
              Chưa có thiết bị IoT nào được kết nối.
            </div>
          ) : (
            <div className="grid grid-cols-1 sm:grid-cols-2 gap-3">
              {devices.slice(0, 6).map((dev) => (
                <div
                  key={dev.id}
                  className="p-3.5 rounded-xl bg-slate-900/60 border border-slate-800 flex items-center justify-between gap-3"
                >
                  <div className="min-w-0">
                    <div className="font-semibold text-xs truncate">{dev.name}</div>
                    <div className="text-[11px] text-slate-400 truncate">
                      {dev.room_name || 'Chưa phân phòng'} • {dev.mqtt_topic}
                    </div>

                    {dev.device_type === 'sensor' && (
                      <div className="mt-1.5 flex flex-wrap items-center gap-1.5 text-[10px] font-mono">
                        {hasLiveSensor && sensorData ? (
                          <>
                            <span className="px-1.5 py-0.5 rounded bg-amber-500/15 text-amber-300">
                              {sensorData.temperature.toFixed(1)}°C
                            </span>
                            <span className="px-1.5 py-0.5 rounded bg-cyan-500/15 text-cyan-300">
                              {sensorData.humidity.toFixed(0)}%
                            </span>
                            <span className="px-1.5 py-0.5 rounded bg-emerald-500/15 text-emerald-300">
                              {sensorData.lux} Lux
                            </span>
                          </>
                        ) : (
                          <span className="px-1.5 py-0.5 rounded bg-slate-800 text-slate-400">
                            ⏳ Đang chờ gói tin MQTT...
                          </span>
                        )}
                      </div>
                    )}
                  </div>

                  <button
                    onClick={() => onToggleDevice(dev)}
                    className={`px-3 py-1.5 rounded-lg text-xs font-bold transition shrink-0 ${
                      dev.is_on
                        ? 'bg-emerald-500 text-slate-950'
                        : 'bg-slate-800 text-slate-300 hover:bg-slate-700'
                    }`}
                  >
                    {dev.is_on ? 'ĐANG BẬT' : 'TẮT'}
                  </button>
                </div>
              ))}
            </div>
          )}
        </div>

        <div className={`p-5 rounded-2xl border ${cardBg}`}>
          <div className="flex items-center justify-between mb-4">
            <h2 className="font-bold text-sm">Không gian Nhà & Phòng</h2>
            <span className="text-xs font-mono text-slate-400">
              {houses.length}N • {rooms.length}P
            </span>
          </div>

          {rooms.length === 0 ? (
            <div className="p-8 text-center text-xs text-slate-500">Chưa có phòng nào.</div>
          ) : (
            <div className="space-y-2">
              {rooms.slice(0, 5).map((r) => (
                <div
                  key={r.id}
                  className="p-2.5 rounded-xl bg-slate-900/60 border border-slate-800 flex items-center justify-between text-xs"
                >
                  <div>
                    <div className="font-semibold">{r.name}</div>
                    <div className="text-[11px] text-slate-400">
                      {r.house_name || 'Nhà chính'} • Tầng {r.floor}
                    </div>
                  </div>
                  <span className="text-[11px] font-mono text-cyan-400">
                    {devices.filter((d) => d.room_id === r.id).length} TB
                  </span>
                </div>
              ))}
            </div>
          )}
        </div>
      </div>

      {/* Row 3: Automations + AI Alerts */}
      <div className="grid grid-cols-1 lg:grid-cols-2 gap-4">
        <div className={`p-5 rounded-2xl border ${cardBg}`}>
          <div className="flex items-center justify-between mb-3">
            <h2 className="font-bold text-sm">Kịch bản Tự động hóa ({automations.length})</h2>
            <button
              onClick={() => onNavigateTab('automations')}
              className="text-xs text-cyan-400 hover:underline font-semibold"
            >
              Chi tiết →
            </button>
          </div>

          {automations.length === 0 ? (
            <div className="text-xs text-slate-500 py-4">
              Chưa thiết lập kịch bản tự động hóa nào.
            </div>
          ) : (
            <div className="space-y-2">
              {automations.slice(0, 3).map((a) => (
                <div
                  key={a.id}
                  className="p-3 rounded-xl bg-slate-900/60 border border-slate-800 flex items-center justify-between text-xs"
                >
                  <div>
                    <div className="font-semibold">{a.name}</div>
                    <div className="text-[11px] text-slate-400">
                      IF {a.condition_text} → {a.action_text}
                    </div>
                  </div>
                  <span
                    className={`px-2 py-0.5 rounded text-[10px] font-bold ${
                      a.is_active
                        ? 'bg-emerald-500/20 text-emerald-400'
                        : 'bg-slate-800 text-slate-400'
                    }`}
                  >
                    {a.is_active ? 'BẬT' : 'TẮT'}
                  </span>
                </div>
              ))}
            </div>
          )}
        </div>

        <div className={`p-5 rounded-2xl border ${cardBg}`}>
          <div className="flex items-center justify-between mb-3">
            <h2 className="font-bold text-sm">Cảnh báo An ninh & AI ({aiAlerts.length})</h2>
            <button
              onClick={() => onNavigateTab('ai')}
              className="text-xs text-cyan-400 hover:underline font-semibold"
            >
              Trung tâm AI →
            </button>
          </div>

          {aiAlerts.length === 0 ? (
            <div className="text-xs text-emerald-400 py-4">
              ✓ Hệ thống vận hành ổn định, không có bất thường.
            </div>
          ) : (
            <div className="space-y-2">
              {aiAlerts.slice(0, 3).map((al) => (
                <div
                  key={al.id}
                  className="p-3 rounded-xl bg-rose-500/10 border border-rose-500/30 text-xs"
                >
                  <div className="font-bold text-rose-400">{al.title || al.alert_type}</div>
                  <div className="text-slate-300 mt-0.5">{al.message}</div>
                </div>
              ))}
            </div>
          )}
        </div>
      </div>

      {/* Row 4: System Logs */}
      <div className={`p-5 rounded-2xl border ${cardBg}`}>
        <div className="flex items-center justify-between mb-3">
          <h2 className="font-bold text-sm">Nhật ký hoạt động hệ thống</h2>
          <button onClick={onClearLogs} className="text-xs text-slate-400 hover:text-slate-200">
            Xóa nhật ký
          </button>
        </div>
        <div className="space-y-1 font-mono text-xs text-slate-400 max-h-32 overflow-y-auto">
          {systemLogs.length === 0 ? (
            <div>Không có nhật ký.</div>
          ) : (
            systemLogs.map((log, i) => <div key={i}>{log}</div>)
          )}
        </div>
      </div>
    </>
  );
}