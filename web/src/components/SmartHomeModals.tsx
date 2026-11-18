import React, { useState, useEffect } from 'react';
import type {
  Device,
  DiscoveredWokwiDevice,
  House,
  Room,
  UserRole,
} from '../types/smarthome';

// 1. Modal Quét thiết bị Wokwi
export const ScanWokwiModal: React.FC<{
  isOpen: boolean;
  isDark: boolean;
  isScanning: boolean;
  discoveredDevices: DiscoveredWokwiDevice[];
  onClose: () => void;
  onRescan: () => void;
  onAddDevice: (item: DiscoveredWokwiDevice) => void;
}> = ({
  isOpen,
  isDark,
  isScanning,
  discoveredDevices,
  onClose,
  onRescan,
  onAddDevice,
}) => {
  if (!isOpen) return null;

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/60 p-4">
      <div
        className={`w-full max-w-lg rounded-2xl border p-6 shadow-xl ${
          isDark
            ? 'bg-[#0d131f] border-slate-800 text-slate-100'
            : 'bg-white border-slate-200 text-slate-800'
        }`}
      >
        <div className="flex justify-between items-center mb-4">
          <h3 className="text-sm font-bold flex items-center gap-2">
            <span>📡</span> Quét Thiết bị Mô phỏng Wokwi (MQTT)
          </h3>
          <button onClick={onClose} className="text-xs text-slate-400 hover:text-slate-200">
            ✕
          </button>
        </div>

        {isScanning ? (
          <div className="py-8 text-center text-xs text-slate-400">
            Đang quét các topic thiết bị trên MQTT Broker...
          </div>
        ) : discoveredDevices.length === 0 ? (
          <div className="py-8 text-center text-xs text-slate-400">
            Không phát hiện thêm thiết bị mới nào chưa lưu trong Database.
          </div>
        ) : (
          <div className="space-y-2.5 max-h-64 overflow-y-auto">
            {discoveredDevices.map((item) => (
              <div
                key={item.mqtt_topic}
                className={`p-3 rounded-xl border flex justify-between items-center gap-3 ${
                  isDark
                    ? 'bg-slate-900/70 border-slate-800'
                    : 'bg-slate-50 border-slate-200'
                }`}
              >
                <div>
                  <div className="text-xs font-bold">{item.name}</div>
                  <div className="text-[11px] font-mono text-slate-400">
                    {item.mqtt_topic} ({item.device_type})
                  </div>
                </div>
                <button
                  onClick={() => onAddDevice(item)}
                  className="px-3 py-1.5 rounded-lg bg-cyan-500 text-slate-950 font-bold text-xs hover:brightness-110 transition"
                >
                  + Thêm
                </button>
              </div>
            ))}
          </div>
        )}

        <div className="flex justify-end gap-2 mt-5">
          <button
            onClick={onRescan}
            className="px-3.5 py-1.5 rounded-lg border border-slate-700 text-xs font-semibold"
          >
            Quét lại
          </button>
          <button
            onClick={onClose}
            className="px-3.5 py-1.5 rounded-lg bg-slate-700 text-white text-xs font-semibold"
          >
            Đóng
          </button>
        </div>
      </div>
    </div>
  );
};

// 2. Modal Thêm / Sửa Thiết bị IoT (kèm chọn Phòng)
export const DeviceFormModal: React.FC<{
  isOpen: boolean;
  isDark: boolean;
  editingDevice: Device | null;
  rooms: Room[];
  houses: House[];
  onClose: () => void;
  onSubmit: (data: {
    name: string;
    device_type: string;
    mqtt_topic: string;
    room_id: string | null;
  }) => void;
}> = ({ isOpen, isDark, editingDevice, rooms, houses, onClose, onSubmit }) => {
  const [name, setName] = useState('');
  const [deviceType, setDeviceType] = useState('switch');
  const [mqttTopic, setMqttTopic] = useState('');
  const [roomId, setRoomId] = useState<string>('');

  useEffect(() => {
    if (editingDevice) {
      setName(editingDevice.name);
      setDeviceType(editingDevice.device_type || 'switch');
      setMqttTopic(editingDevice.topic);
      setRoomId(editingDevice.room_id || '');
    } else {
      setName('');
      setDeviceType('switch');
      setMqttTopic('smarthome/devices/');
      setRoomId('');
    }
  }, [editingDevice, isOpen]);

  if (!isOpen) return null;

  const inputClass = `w-full px-3 py-2 rounded-lg text-xs border focus:outline-none focus:ring-2 focus:ring-cyan-500 ${
    isDark
      ? 'bg-slate-900 border-slate-800 text-slate-200'
      : 'bg-slate-50 border-slate-300 text-slate-800'
  }`;

  const getHouseName = (houseId: string) =>
    houses.find((h) => h.id === houseId)?.name || '';

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/60 p-4">
      <div
        className={`w-full max-w-md rounded-2xl border p-6 shadow-xl ${
          isDark
            ? 'bg-[#0d131f] border-slate-800 text-slate-100'
            : 'bg-white border-slate-200 text-slate-800'
        }`}
      >
        <h3 className="text-sm font-bold mb-4">
          {editingDevice ? '✏️ Chỉnh sửa Thiết bị IoT' : '+ Thêm Thiết bị IoT Mới'}
        </h3>

        <form
          onSubmit={(e) => {
            e.preventDefault();
            onSubmit({
              name: name.trim(),
              device_type: deviceType,
              mqtt_topic: mqttTopic.trim(),
              room_id: roomId || null,
            });
          }}
          className="space-y-3.5"
        >
          <div>
            <label className="block text-xs font-semibold mb-1">Tên thiết bị</label>
            <input
              type="text"
              value={name}
              onChange={(e) => setName(e.target.value)}
              className={inputClass}
              placeholder="VD: Đèn Phòng Ngủ"
              required
            />
          </div>

          <div>
            <label className="block text-xs font-semibold mb-1">Phân phòng</label>
            <select
              value={roomId}
              onChange={(e) => setRoomId(e.target.value)}
              className={inputClass}
            >
              <option value="">-- Chưa phân phòng --</option>
              {rooms.map((r) => {
                const hName = r.house_name || getHouseName(r.house_id);
                return (
                  <option key={r.id} value={r.id}>
                    {r.name} (Tầng {r.floor}){hName ? ` — ${hName}` : ''}
                  </option>
                );
              })}
            </select>
          </div>

          <div>
            <label className="block text-xs font-semibold mb-1">Loại thiết bị</label>
            <select
              value={deviceType}
              onChange={(e) => setDeviceType(e.target.value)}
              className={inputClass}
            >
              <option value="light">Đèn chiếu sáng (light)</option>
              <option value="fan">Quạt điện (fan)</option>
              <option value="ac">Điều hòa (ac)</option>
              <option value="switch">Công tắc thông minh (switch)</option>
              <option value="sensor">Cảm biến môi trường (sensor)</option>
            </select>
          </div>

          <div>
            <label className="block text-xs font-semibold mb-1">MQTT Topic</label>
            <input
              type="text"
              value={mqttTopic}
              onChange={(e) => setMqttTopic(e.target.value)}
              className={`${inputClass} font-mono`}
              placeholder="smarthome/devices/den_phong_ngu"
              required
            />
          </div>

          <div className="flex justify-end gap-2 pt-2">
            <button
              type="button"
              onClick={onClose}
              className="px-4 py-2 rounded-lg border border-slate-700 text-xs font-semibold"
            >
              Hủy
            </button>
            <button
              type="submit"
              className="px-4 py-2 rounded-lg bg-sky-600 hover:bg-sky-700 text-white text-xs font-bold"
            >
              Lưu thiết bị
            </button>
          </div>
        </form>
      </div>
    </div>
  );
};

// 3. Modal Thêm / Sửa Nhà (bảng houses)
export const HouseFormModal: React.FC<{
  isOpen: boolean;
  isDark: boolean;
  editingHouse: House | null;
  errorMsg: string;
  onClose: () => void;
  onSubmit: (data: { name: string; address: string }) => void;
}> = ({ isOpen, isDark, editingHouse, errorMsg, onClose, onSubmit }) => {
  const [name, setName] = useState('');
  const [address, setAddress] = useState('');

  useEffect(() => {
    if (editingHouse) {
      setName(editingHouse.name);
      setAddress(editingHouse.address || '');
    } else {
      setName('');
      setAddress('');
    }
  }, [editingHouse, isOpen]);

  if (!isOpen) return null;

  const inputClass = `w-full px-3 py-2 rounded-lg text-xs border focus:outline-none focus:ring-2 focus:ring-cyan-500 ${
    isDark
      ? 'bg-slate-900 border-slate-800 text-slate-200'
      : 'bg-slate-50 border-slate-300 text-slate-800'
  }`;

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/60 p-4">
      <div
        className={`w-full max-w-md rounded-2xl border p-6 shadow-xl ${
          isDark
            ? 'bg-[#0d131f] border-slate-800 text-slate-100'
            : 'bg-white border-slate-200 text-slate-800'
        }`}
      >
        <h3 className="text-sm font-bold mb-4">
          {editingHouse ? '✏️ Chỉnh sửa Thông tin Nhà' : '🏡 Thêm Ngôi nhà Mới'}
        </h3>

        {errorMsg && (
          <div className="mb-3 p-2.5 rounded-lg bg-red-500/15 border border-red-500/40 text-red-400 text-xs">
            {errorMsg}
          </div>
        )}

        <form
          onSubmit={(e) => {
            e.preventDefault();
            onSubmit({ name: name.trim(), address: address.trim() });
          }}
          className="space-y-3.5"
        >
          <div>
            <label className="block text-xs font-semibold mb-1">Tên ngôi nhà *</label>
            <input
              type="text"
              value={name}
              onChange={(e) => setName(e.target.value)}
              className={inputClass}
              placeholder="VD: Nhà Chính Quận 1"
              required
            />
          </div>

          <div>
            <label className="block text-xs font-semibold mb-1">Địa chỉ</label>
            <input
              type="text"
              value={address}
              onChange={(e) => setAddress(e.target.value)}
              className={inputClass}
              placeholder="VD: 123 Nguyễn Huệ, TP.HCM"
            />
          </div>

          <div className="flex justify-end gap-2 pt-2">
            <button
              type="button"
              onClick={onClose}
              className="px-4 py-2 rounded-lg border border-slate-700 text-xs font-semibold"
            >
              Hủy
            </button>
            <button
              type="submit"
              className="px-4 py-2 rounded-lg bg-cyan-500 hover:bg-cyan-400 text-slate-950 text-xs font-bold"
            >
              {editingHouse ? 'Cập nhật' : 'Tạo nhà'}
            </button>
          </div>
        </form>
      </div>
    </div>
  );
};

// 4. Modal Thêm / Sửa Phòng (bảng rooms)
export const RoomFormModal: React.FC<{
  isOpen: boolean;
  isDark: boolean;
  editingRoom: Room | null;
  houses: House[];
  defaultHouseId: string;
  errorMsg: string;
  onClose: () => void;
  onSubmit: (data: { house_id: string; name: string; floor: number }) => void;
}> = ({
  isOpen,
  isDark,
  editingRoom,
  houses,
  defaultHouseId,
  errorMsg,
  onClose,
  onSubmit,
}) => {
  const [houseId, setHouseId] = useState('');
  const [name, setName] = useState('');
  const [floor, setFloor] = useState<number>(1);

  useEffect(() => {
    if (editingRoom) {
      setHouseId(editingRoom.house_id);
      setName(editingRoom.name);
      setFloor(editingRoom.floor ?? 1);
    } else {
      setHouseId(defaultHouseId || houses[0]?.id || '');
      setName('');
      setFloor(1);
    }
  }, [editingRoom, defaultHouseId, houses, isOpen]);

  if (!isOpen) return null;

  const inputClass = `w-full px-3 py-2 rounded-lg text-xs border focus:outline-none focus:ring-2 focus:ring-cyan-500 ${
    isDark
      ? 'bg-slate-900 border-slate-800 text-slate-200'
      : 'bg-slate-50 border-slate-300 text-slate-800'
  }`;

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/60 p-4">
      <div
        className={`w-full max-w-md rounded-2xl border p-6 shadow-xl ${
          isDark
            ? 'bg-[#0d131f] border-slate-800 text-slate-100'
            : 'bg-white border-slate-200 text-slate-800'
        }`}
      >
        <h3 className="text-sm font-bold mb-4">
          {editingRoom ? '✏️ Chỉnh sửa Phòng' : '🚪 Thêm Phòng Mới'}
        </h3>

        {errorMsg && (
          <div className="mb-3 p-2.5 rounded-lg bg-red-500/15 border border-red-500/40 text-red-400 text-xs">
            {errorMsg}
          </div>
        )}

        <form
          onSubmit={(e) => {
            e.preventDefault();
            onSubmit({
              house_id: houseId,
              name: name.trim(),
              floor: Number(floor) || 1,
            });
          }}
          className="space-y-3.5"
        >
          <div>
            <label className="block text-xs font-semibold mb-1">Thuộc ngôi nhà *</label>
            <select
              value={houseId}
              onChange={(e) => setHouseId(e.target.value)}
              className={inputClass}
              required
            >
              <option value="" disabled>
                -- Chọn ngôi nhà --
              </option>
              {houses.map((h) => (
                <option key={h.id} value={h.id}>
                  {h.name}
                </option>
              ))}
            </select>
          </div>

          <div>
            <label className="block text-xs font-semibold mb-1">Tên phòng *</label>
            <input
              type="text"
              value={name}
              onChange={(e) => setName(e.target.value)}
              className={inputClass}
              placeholder="VD: Phòng Khách, Phòng Ngủ Master, Nhà Bếp..."
              required
            />
          </div>

          <div>
            <label className="block text-xs font-semibold mb-1">Tầng (Floor)</label>
            <input
              type="number"
              min={0}
              max={50}
              value={floor}
              onChange={(e) => setFloor(Number(e.target.value))}
              className={inputClass}
              required
            />
          </div>

          <div className="flex justify-end gap-2 pt-2">
            <button
              type="button"
              onClick={onClose}
              className="px-4 py-2 rounded-lg border border-slate-700 text-xs font-semibold"
            >
              Hủy
            </button>
            <button
              type="submit"
              disabled={!houseId}
              className="px-4 py-2 rounded-lg bg-emerald-600 hover:bg-emerald-700 text-white text-xs font-bold disabled:opacity-50"
            >
              {editingRoom ? 'Cập nhật phòng' : 'Tạo phòng'}
            </button>
          </div>
        </form>
      </div>
    </div>
  );
};

// 5. Modal Tạo Luật Tự động hóa IF-THEN
export const AutomationFormModal: React.FC<{
  isOpen: boolean;
  isDark: boolean;
  onClose: () => void;
  onSubmit: (data: { name: string; condition_text: string; action_text: string }) => void;
}> = ({ isOpen, isDark, onClose, onSubmit }) => {
  const [name, setName] = useState('');
  const [conditionText, setConditionText] = useState('Nhiệt độ > 30');
  const [actionText, setActionText] = useState('Bật Quạt Phòng Khách (ON)');

  if (!isOpen) return null;

  const inputClass = `w-full px-3 py-2 rounded-lg text-xs border focus:outline-none focus:ring-2 focus:ring-cyan-500 ${
    isDark
      ? 'bg-slate-900 border-slate-800 text-slate-200'
      : 'bg-slate-50 border-slate-300 text-slate-800'
  }`;

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/60 p-4">
      <div
        className={`w-full max-w-md rounded-2xl border p-6 shadow-xl ${
          isDark
            ? 'bg-[#0d131f] border-slate-800 text-slate-100'
            : 'bg-white border-slate-200 text-slate-800'
        }`}
      >
        <h3 className="text-sm font-bold mb-4">⚡ Tạo Kịch bản Tự động hóa IF-THEN</h3>
        <form
          onSubmit={(e) => {
            e.preventDefault();
            onSubmit({
              name: name.trim(),
              condition_text: conditionText.trim(),
              action_text: actionText.trim(),
            });
            setName('');
          }}
          className="space-y-3.5"
        >
          <div>
            <label className="block text-xs font-semibold mb-1">Tên kịch bản</label>
            <input
              type="text"
              value={name}
              onChange={(e) => setName(e.target.value)}
              className={inputClass}
              placeholder="VD: Bật quạt khi nóng"
              required
            />
          </div>
          <div>
            <label className="block text-xs font-semibold mb-1">Điều kiện (IF)</label>
            <input
              type="text"
              value={conditionText}
              onChange={(e) => setConditionText(e.target.value)}
              className={`${inputClass} font-mono`}
              placeholder="Nhiệt độ > 30 hoặc Ánh sáng < 300"
              required
            />
          </div>
          <div>
            <label className="block text-xs font-semibold mb-1">Hành động (THEN)</label>
            <input
              type="text"
              value={actionText}
              onChange={(e) => setActionText(e.target.value)}
              className={`${inputClass} font-mono`}
              placeholder="Bật Quạt Phòng Khách (ON)"
              required
            />
          </div>
          <div className="flex justify-end gap-2 pt-2">
            <button
              type="button"
              onClick={onClose}
              className="px-4 py-2 rounded-lg border border-slate-700 text-xs font-semibold"
            >
              Hủy
            </button>
            <button
              type="submit"
              className="px-4 py-2 rounded-lg bg-amber-600 hover:bg-amber-700 text-white text-xs font-bold"
            >
              Tạo luật
            </button>
          </div>
        </form>
      </div>
    </div>
  );
};

// 6. Modal Tạo Tài khoản Mới
export const AccountFormModal: React.FC<{
  isOpen: boolean;
  isDark: boolean;
  isSubmitting: boolean;
  errorMsg: string;
  onClose: () => void;
  onSubmit: (data: { name: string; email: string; password: string; role: UserRole }) => void;
}> = ({ isOpen, isDark, isSubmitting, errorMsg, onClose, onSubmit }) => {
  const [name, setName] = useState('');
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [role, setRole] = useState<UserRole>('Member');

  if (!isOpen) return null;

  const inputClass = `w-full px-3 py-2 rounded-lg text-xs border focus:outline-none focus:ring-2 focus:ring-cyan-500 ${
    isDark
      ? 'bg-slate-900 border-slate-800 text-slate-200'
      : 'bg-slate-50 border-slate-300 text-slate-800'
  }`;

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/60 p-4">
      <div
        className={`w-full max-w-md rounded-2xl border p-6 shadow-xl ${
          isDark
            ? 'bg-[#0d131f] border-slate-800 text-slate-100'
            : 'bg-white border-slate-200 text-slate-800'
        }`}
      >
        <h3 className="text-sm font-bold mb-4">👥 Tạo Tài khoản Người dùng Mới</h3>
        {errorMsg && (
          <div className="mb-3 p-2.5 rounded-lg bg-red-500/15 border border-red-500/40 text-red-400 text-xs">
            {errorMsg}
          </div>
        )}
        <form
          onSubmit={(e) => {
            e.preventDefault();
            onSubmit({ name: name.trim(), email: email.trim(), password, role });
          }}
          className="space-y-3.5"
        >
          <div>
            <label className="block text-xs font-semibold mb-1">Họ và tên</label>
            <input
              type="text"
              value={name}
              onChange={(e) => setName(e.target.value)}
              className={inputClass}
              required
            />
          </div>
          <div>
            <label className="block text-xs font-semibold mb-1">Email</label>
            <input
              type="email"
              value={email}
              onChange={(e) => setEmail(e.target.value)}
              className={inputClass}
              required
            />
          </div>
          <div>
            <label className="block text-xs font-semibold mb-1">Mật khẩu</label>
            <input
              type="password"
              value={password}
              onChange={(e) => setPassword(e.target.value)}
              className={inputClass}
              required
            />
          </div>
          <div>
            <label className="block text-xs font-semibold mb-1">Vai trò (Role)</label>
            <select
              value={role}
              onChange={(e) => setRole(e.target.value as UserRole)}
              className={inputClass}
            >
              <option value="Member">Member (Thành viên)</option>
              <option value="Admin">Admin (Quản trị viên)</option>
              <option value="Guest">Guest (Khách)</option>
            </select>
          </div>
          <div className="flex justify-end gap-2 pt-2">
            <button
              type="button"
              onClick={onClose}
              className="px-4 py-2 rounded-lg border border-slate-700 text-xs font-semibold"
            >
              Hủy
            </button>
            <button
              type="submit"
              disabled={isSubmitting}
              className="px-4 py-2 rounded-lg bg-sky-600 hover:bg-sky-700 text-white text-xs font-bold disabled:opacity-50"
            >
              {isSubmitting ? 'Đang tạo...' : 'Tạo tài khoản'}
            </button>
          </div>
        </form>
      </div>
    </div>
  );
};