import React, { useEffect, useMemo, useState } from 'react';
import type { AutomationRule, Device } from '../../types/smarthome';
import { API_BASE, getAuthHeaders } from '../../utils/api';

interface AutomationsTabProps {
  automations: AutomationRule[];
  setAutomations: React.Dispatch<React.SetStateAction<AutomationRule[]>>;
  devices?: Device[];
  isOwnerOrAdmin: boolean;
  cardBg: string;
  inputBg: string;
  appendLog: (msg: string) => void;
  onRefresh: () => Promise<void>;
}

const SENSOR_OPTIONS = [
  { label: 'Nhiệt độ', key: 'temperature', defaultOp: '>', defaultVal: '30' },
  { label: 'Độ ẩm', key: 'humidity', defaultOp: '>', defaultVal: '80' },
  { label: 'Ánh sáng', key: 'lux', defaultOp: '<', defaultVal: '300' },
  { label: 'Chuyển động', key: 'motion', defaultOp: '==', defaultVal: '1' },
];

const OPERATOR_OPTIONS = ['>', '<', '>=', '<=', '=='];

export function AutomationsTab({
  automations,
  setAutomations,
  devices: propDevices,
  isOwnerOrAdmin,
  cardBg,
  inputBg,
  appendLog,
  onRefresh,
}: AutomationsTabProps) {
  const [fetchedDevices, setFetchedDevices] = useState<Device[]>([]);
  const [isModalOpen, setIsModalOpen] = useState(false);
  const [isSubmitting, setIsSubmitting] = useState(false);

  // State form giống hệt dialog TẠO KỊCH BẢN TỰ ĐỘNG trên Mobile
  const [newAutoName, setNewAutoName] = useState('');
  const [sensorLabel, setSensorLabel] = useState('Nhiệt độ');
  const [operator, setOperator] = useState('>');
  const [threshold, setThreshold] = useState('30');
  const [selectedDeviceId, setSelectedDeviceId] = useState('');
  const [actionCmd, setActionCmd] = useState<'ON' | 'OFF'>('ON');

  const [newAutoCondition, setNewAutoCondition] = useState('Nhiệt độ > 30');
  const [newAutoAction, setNewAutoAction] = useState('');

  const isLightMode = cardBg.includes('bg-white');

  // Tự tải danh sách thiết bị nếu component cha chưa truyền prop devices
  useEffect(() => {
    if (propDevices && propDevices.length > 0) return;
    let active = true;
    fetch(`${API_BASE}/devices`, { headers: getAuthHeaders() })
      .then((res) => (res.ok ? res.json() : []))
      .then((data) => {
        if (!active) return;
        const list = Array.isArray(data) ? data : data?.data || [];
        setFetchedDevices(list);
      })
      .catch(() => {});
    return () => {
      active = false;
    };
  }, [propDevices]);

  const allDevices = propDevices && propDevices.length > 0 ? propDevices : fetchedDevices;

  // Lọc thiết bị chấp hành (loại bỏ cảm biến thuần túy)
  const actuatorDevices = useMemo(() => {
    const filtered = allDevices.filter((d) => {
      const type = String(d.device_type || '').toLowerCase();
      const name = String(d.name || '').toLowerCase();
      return (
        type !== 'sensor' &&
        !name.includes('cảm biến') &&
        !name.includes('dht22')
      );
    });
    return filtered.length > 0 ? filtered : allDevices;
  }, [allDevices]);

  const selectedDevice = useMemo(
    () =>
      actuatorDevices.find((d) => String(d.id) === String(selectedDeviceId)) ||
      actuatorDevices[0],
    [actuatorDevices, selectedDeviceId]
  );

  // Chọn thiết bị mặc định khi có danh sách thiết bị
  useEffect(() => {
    if (!selectedDeviceId && actuatorDevices.length > 0) {
      setSelectedDeviceId(String(actuatorDevices[0].id));
    }
  }, [actuatorDevices, selectedDeviceId]);

  // Tự động cập nhật chuỗi Điều kiện kích hoạt (IF)
  useEffect(() => {
    setNewAutoCondition(`${sensorLabel} ${operator} ${threshold}`.trim());
  }, [sensorLabel, operator, threshold]);

  // Tự động cập nhật chuỗi Hành động thực thi (THEN)
  useEffect(() => {
    const targetName = selectedDevice?.name || 'Thiết bị';
    const verb = actionCmd === 'ON' ? 'Bật' : 'Tắt';
    setNewAutoAction(`${verb} ${targetName} (${actionCmd})`);
  }, [selectedDevice, actionCmd]);

  const findDeviceByKeyword = (keywords: string[]) => {
    return (
      actuatorDevices.find((d) => {
        const name = String(d.name || '').toLowerCase();
        const type = String(d.device_type || '').toLowerCase();
        return keywords.some((kw) => name.includes(kw) || type.includes(kw));
      }) || actuatorDevices[0]
    );
  };

  // 3 mẫu kích hoạt nhanh Wokwi giống Mobile
  const applyWokwiPreset = (preset: 'HOT_FAN' | 'DARK_LIGHT' | 'PIR_LIGHT') => {
    if (preset === 'HOT_FAN') {
      const fan = findDeviceByKeyword(['quạt', 'fan']);
      setNewAutoName('Tự động làm mát khi nóng');
      setSensorLabel('Nhiệt độ');
      setOperator('>');
      setThreshold('30');
      if (fan) setSelectedDeviceId(String(fan.id));
      setActionCmd('ON');
    } else if (preset === 'DARK_LIGHT') {
      const light = findDeviceByKeyword(['đèn', 'light', 'led']);
      setNewAutoName('Bật đèn khi trời tối');
      setSensorLabel('Ánh sáng');
      setOperator('<');
      setThreshold('300');
      if (light) setSelectedDeviceId(String(light.id));
      setActionCmd('ON');
    } else if (preset === 'PIR_LIGHT') {
      const light = findDeviceByKeyword(['đèn', 'light', 'led']);
      setNewAutoName('Cảnh báo chuyển động PIR');
      setSensorLabel('Chuyển động');
      setOperator('==');
      setThreshold('1');
      if (light) setSelectedDeviceId(String(light.id));
      setActionCmd('ON');
    }
  };

  const openCreateModal = () => {
    setNewAutoName('');
    setSensorLabel('Nhiệt độ');
    setOperator('>');
    setThreshold('30');
    setActionCmd('ON');
    if (actuatorDevices.length > 0) {
      setSelectedDeviceId(String(actuatorDevices[0].id));
    }
    setIsModalOpen(true);
  };

  const handleCreateAutomation = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!newAutoName.trim() || !newAutoCondition.trim() || !newAutoAction.trim()) {
      return;
    }

    setIsSubmitting(true);
    try {
      const res = await fetch(`${API_BASE}/automations`, {
        method: 'POST',
        headers: getAuthHeaders(),
        body: JSON.stringify({
          name: newAutoName.trim(),
          condition_text: newAutoCondition.trim(),
          action_text: newAutoAction.trim(),
        }),
      });

      if (res.ok) {
        appendLog(`Đã tạo kịch bản "${newAutoName.trim()}".`);
        setNewAutoName('');
        setIsModalOpen(false);
        await onRefresh();
      }
    } finally {
      setIsSubmitting(false);
    }
  };

  const handleToggleAutomation = async (rule: AutomationRule) => {
    const next = !rule.is_active;
    setAutomations((prev) =>
      prev.map((a) => (a.id === rule.id ? { ...a, is_active: next } : a))
    );
    await fetch(`${API_BASE}/automations/${rule.id}/toggle`, {
      method: 'POST',
      headers: getAuthHeaders(),
      body: JSON.stringify({ is_active: next }),
    });
  };

  const handleDeleteAutomation = async (rule: AutomationRule) => {
    if (!confirm(`Xóa kịch bản "${rule.name}"?`)) return;
    const res = await fetch(`${API_BASE}/automations/${rule.id}`, {
      method: 'DELETE',
      headers: getAuthHeaders(),
    });
    if (res.ok) {
      appendLog(`Đã xóa kịch bản "${rule.name}".`);
      await onRefresh();
    }
  };

  return (
    <div className="space-y-6">
      {/* Thanh tiêu đề & nút mở Modal tạo kịch bản */}
      <div
        className={`p-5 rounded-2xl border flex flex-wrap items-center justify-between gap-3 ${cardBg}`}
      >
        <div>
          <h2 className="font-bold text-sm tracking-wide">
            KỊCH BẢN TỰ ĐỘNG HÓA (IF - THEN)
          </h2>
          <p className="text-xs text-slate-400 mt-1">
            Tự động điều khiển thiết bị theo ngưỡng cảm biến nhiệt độ, độ ẩm, ánh sáng và chuyển động.
          </p>
        </div>
        {isOwnerOrAdmin && (
          <button
            type="button"
            onClick={openCreateModal}
            className="py-2.5 px-5 rounded-full bg-cyan-400 hover:bg-cyan-300 text-slate-950 font-bold text-xs tracking-wide shadow-lg shadow-cyan-500/20 transition"
          >
            + THÊM LUẬT
          </button>
        )}
      </div>

      {/* Danh sách kịch bản hiện có */}
      <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
        {automations.length === 0 ? (
          <div
            className={`col-span-full p-10 rounded-2xl border text-center text-xs text-slate-500 ${cardBg}`}
          >
            Chưa có kịch bản tự động hóa nào trong ngôi nhà của bạn.
          </div>
        ) : (
          automations.map((rule) => (
            <div
              key={rule.id}
              className={`p-4 rounded-2xl border flex items-center justify-between gap-3 ${cardBg}`}
            >
              <div>
                <div className="font-bold text-sm">{rule.name}</div>
                <div className="text-xs text-slate-400 mt-1">
                  IF{' '}
                  <span className="text-amber-400 font-mono">
                    {rule.condition_text}
                  </span>{' '}
                  → THEN{' '}
                  <span className="text-cyan-400">{rule.action_text}</span>
                </div>
              </div>
              <div className="flex items-center gap-2 shrink-0">
                <button
                  type="button"
                  onClick={() => handleToggleAutomation(rule)}
                  className={`px-3 py-1.5 rounded-lg text-xs font-bold ${
                    rule.is_active
                      ? 'bg-emerald-500/20 text-emerald-400 border border-emerald-500/30'
                      : 'bg-slate-800 text-slate-400'
                  }`}
                >
                  {rule.is_active ? 'Đang BẬT' : 'Đang TẮT'}
                </button>
                {isOwnerOrAdmin && (
                  <button
                    type="button"
                    onClick={() => handleDeleteAutomation(rule)}
                    className="px-2.5 py-1.5 rounded-lg bg-rose-500/15 text-rose-400 hover:bg-rose-500/25 text-xs"
                  >
                    Xóa
                  </button>
                )}
              </div>
            </div>
          ))
        )}
      </div>

      {/* MODAL TẠO KỊCH BẢN TỰ ĐỘNG (ĐỒNG BỘ VỚI MOBILE) */}
      {isModalOpen && (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/75 p-4 backdrop-blur-sm">
          <div
            className={`w-full max-w-lg rounded-3xl border p-6 shadow-2xl ${
              isLightMode
                ? 'bg-white border-slate-200 text-slate-900'
                : 'bg-[#121726] border-slate-800 text-slate-100'
            }`}
          >
            <h3 className="text-base font-bold tracking-wide">
              TẠO KỊCH BẢN TỰ ĐỘNG
            </h3>

            {/* Mẫu kích hoạt nhanh Wokwi */}
            <div className="mt-4">
              <div className="text-xs text-slate-400 mb-2">
                Mẫu kích hoạt nhanh Wokwi:
              </div>
              <div className="flex flex-wrap gap-2">
                <button
                  type="button"
                  onClick={() => applyWokwiPreset('HOT_FAN')}
                  className={`px-3 py-1.5 rounded-xl border text-xs font-medium transition ${
                    isLightMode
                      ? 'bg-slate-100 border-slate-300 text-slate-700 hover:border-cyan-500'
                      : 'bg-[#181F32] border-slate-700 text-slate-200 hover:border-cyan-400 hover:text-cyan-300'
                  }`}
                >
                  Nóng &gt; 30°C → Bật Quạt
                </button>
                <button
                  type="button"
                  onClick={() => applyWokwiPreset('DARK_LIGHT')}
                  className={`px-3 py-1.5 rounded-xl border text-xs font-medium transition ${
                    isLightMode
                      ? 'bg-slate-100 border-slate-300 text-slate-700 hover:border-cyan-500'
                      : 'bg-[#181F32] border-slate-700 text-slate-200 hover:border-cyan-400 hover:text-cyan-300'
                  }`}
                >
                  Tối &lt; 300 lx → Bật Đèn
                </button>
                <button
                  type="button"
                  onClick={() => applyWokwiPreset('PIR_LIGHT')}
                  className={`px-3 py-1.5 rounded-xl border text-xs font-medium transition ${
                    isLightMode
                      ? 'bg-slate-100 border-slate-300 text-slate-700 hover:border-cyan-500'
                      : 'bg-[#181F32] border-slate-700 text-slate-200 hover:border-cyan-400 hover:text-cyan-300'
                  }`}
                >
                  Có chuyển động → Bật Đèn
                </button>
              </div>
            </div>

            <form onSubmit={handleCreateAutomation} className="mt-5 space-y-4">
              {/* Tên kịch bản */}
              <div>
                <label className="block text-xs text-slate-400 mb-1">
                  Tên kịch bản
                </label>
                <input
                  type="text"
                  required
                  value={newAutoName}
                  onChange={(e) => setNewAutoName(e.target.value)}
                  placeholder="VD: Tự động làm mát khi nóng"
                  className={`w-full px-3 py-2 rounded-xl border text-xs ${inputBg}`}
                />
              </div>

              {/* Hàng 1: Cảm biến | So sánh | Ngưỡng */}
              <div className="grid grid-cols-12 gap-3">
                <div className="col-span-5">
                  <label className="block text-xs text-slate-400 mb-1">
                    Cảm biến
                  </label>
                  <select
                    value={sensorLabel}
                    onChange={(e) => {
                      const next = e.target.value;
                      setSensorLabel(next);
                      const found = SENSOR_OPTIONS.find((s) => s.label === next);
                      if (found) {
                        setOperator(found.defaultOp);
                        setThreshold(found.defaultVal);
                      }
                    }}
                    className={`w-full px-3 py-2 rounded-xl border text-xs ${inputBg}`}
                  >
                    {SENSOR_OPTIONS.map((s) => (
                      <option key={s.key} value={s.label}>
                        {s.label}
                      </option>
                    ))}
                  </select>
                </div>

                <div className="col-span-3">
                  <label className="block text-xs text-slate-400 mb-1">
                    So sánh
                  </label>
                  <select
                    value={operator}
                    onChange={(e) => setOperator(e.target.value)}
                    className={`w-full px-3 py-2 rounded-xl border text-xs ${inputBg}`}
                  >
                    {OPERATOR_OPTIONS.map((op) => (
                      <option key={op} value={op}>
                        {op}
                      </option>
                    ))}
                  </select>
                </div>

                <div className="col-span-4">
                  <label className="block text-xs text-slate-400 mb-1">
                    Ngưỡng
                  </label>
                  <input
                    type="number"
                    step="any"
                    required
                    value={threshold}
                    onChange={(e) => setThreshold(e.target.value)}
                    className={`w-full px-3 py-2 rounded-xl border text-xs ${inputBg}`}
                  />
                </div>
              </div>

              {/* Hàng 2: Thiết bị thực thi | Lệnh */}
              <div className="grid grid-cols-12 gap-3">
                <div className="col-span-8">
                  <label className="block text-xs text-slate-400 mb-1">
                    Thiết bị thực thi
                  </label>
                  <select
                    value={selectedDevice ? String(selectedDevice.id) : ''}
                    onChange={(e) => setSelectedDeviceId(e.target.value)}
                    className={`w-full px-3 py-2 rounded-xl border text-xs ${inputBg}`}
                  >
                    {actuatorDevices.length === 0 ? (
                      <option value="">Chưa có thiết bị</option>
                    ) : (
                      actuatorDevices.map((dev) => (
                        <option key={dev.id} value={String(dev.id)}>
                          {dev.name}
                        </option>
                      ))
                    )}
                  </select>
                </div>

                <div className="col-span-4">
                  <label className="block text-xs text-slate-400 mb-1">
                    Lệnh
                  </label>
                  <select
                    value={actionCmd}
                    onChange={(e) =>
                      setActionCmd(e.target.value as 'ON' | 'OFF')
                    }
                    className={`w-full px-3 py-2 rounded-xl border text-xs ${inputBg}`}
                  >
                    <option value="ON">BẬT</option>
                    <option value="OFF">TẮT</option>
                  </select>
                </div>
              </div>

              {/* Điều kiện kích hoạt (IF) */}
              <div>
                <label className="block text-xs text-slate-400 mb-1">
                  Điều kiện kích hoạt (IF)
                </label>
                <input
                  type="text"
                  required
                  value={newAutoCondition}
                  onChange={(e) => setNewAutoCondition(e.target.value)}
                  className={`w-full px-3 py-2 rounded-xl border text-xs font-mono text-amber-400 ${inputBg}`}
                />
              </div>

              {/* Hành động thực thi (THEN) */}
              <div>
                <label className="block text-xs text-slate-400 mb-1">
                  Hành động thực thi (THEN)
                </label>
                <input
                  type="text"
                  required
                  value={newAutoAction}
                  onChange={(e) => setNewAutoAction(e.target.value)}
                  className={`w-full px-3 py-2 rounded-xl border text-xs text-cyan-400 ${inputBg}`}
                />
              </div>

              {/* Nút HỦY & LƯU KỊCH BẢN */}
              <div className="flex items-center justify-end gap-3 pt-3">
                <button
                  type="button"
                  onClick={() => setIsModalOpen(false)}
                  className="px-4 py-2 rounded-xl text-xs font-bold text-slate-400 hover:text-slate-200 transition"
                >
                  HỦY
                </button>
                <button
                  type="submit"
                  disabled={isSubmitting}
                  className="py-2.5 px-6 rounded-full bg-cyan-400 hover:bg-cyan-300 text-slate-950 font-bold text-xs tracking-wide shadow-lg shadow-cyan-500/20 transition disabled:opacity-50"
                >
                  {isSubmitting ? 'ĐANG LƯU...' : 'LƯU KỊCH BẢN'}
                </button>
              </div>
            </form>
          </div>
        </div>
      )}
    </div>
  );
}