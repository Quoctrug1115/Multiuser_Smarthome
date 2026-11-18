import React, { useState, useEffect, useRef, useMemo } from 'react';
import * as XLSX from 'xlsx';
import { EnergyAnalyticsPanel, type EnergyPeriod } from './components/EnergyAnalyticsPanel';

const API_BASE = import.meta.env.VITE_API_URL || 'http://127.0.0.1:3000/api/v1';
const WS_URL =
  import.meta.env.VITE_WS_URL ||
  API_BASE.replace(/^http/, 'ws').replace(/\/api\/v1\/?$/, '/ws');

interface UserProfile {
  id: string;
  name: string;
  full_name?: string;
  email: string;
  role: string;
  owner_id?: string | null;
}

interface ExcelUserPreviewItem {
  rowNumber: number;
  name: string;
  email: string;
  password: string;
  isDefaultPassword: boolean;
  role: 'Admin' | 'Member' | 'Guest';
  isValid: boolean;
  errorReason?: string;
}

interface ExcelSpacePreviewItem {
  id: string;
  sheetName: string;
  rowNumber: number;
  kind: 'house' | 'room' | 'device';
  name: string;
  address?: string;
  houseName?: string;
  roomName?: string;
  floor?: number;
  deviceType?: string;
  mqttTopic?: string;
  isValid: boolean;
  errorReason?: string;
}

interface House {
  id: string;
  name: string;
  address: string;
  owner_id?: string | null;
}

interface Room {
  id: string;
  house_id: string;
  house_name?: string;
  name: string;
  floor: number;
}

interface Device {
  id: string;
  name: string;
  device_type: string;
  mqtt_topic: string;
  room_id?: string | null;
  room_name?: string | null;
  is_on: boolean;
}

interface AutomationRule {
  id: string;
  name: string;
  condition_text: string;
  action_text: string;
  condition_type?: string;
  operator?: string;
  threshold?: number;
  action?: string;
  is_active: boolean;
}

interface AiAlert {
  id: string;
  alert_type: string;
  title?: string;
  message: string;
  severity?: string;
  created_at: string;
}

interface EnergyPoint {
  label: string;
  kwh: number;
  power_watt?: number;
}

interface EnergyState {
  total_kwh: number;
  estimated_cost: number;
  peak_watt?: number;
  daily: EnergyPoint[];
}

type ActiveTab = 'overview' | 'devices' | 'automations' | 'energy' | 'ai' | 'accounts';

export function App() {
  // ==================== AUTH STATE ====================
  const [currentUser, setCurrentUser] = useState<UserProfile | null>(() => {
    try {
      const saved = localStorage.getItem('smarthome_user');
      return saved ? JSON.parse(saved) : null;
    } catch {
      return null;
    }
  });
  const [authMode, setAuthMode] = useState<'login' | 'register'>('login');
  const [authName, setAuthName] = useState('');
  const [authEmail, setAuthEmail] = useState('');
  const [authPassword, setAuthPassword] = useState('');
  const [authError, setAuthError] = useState('');
  const [authLoading, setAuthLoading] = useState(false);

  // ==================== UI & NAVIGATION STATE ====================
  const [activeTab, setActiveTab] = useState<ActiveTab>('overview');
  const [isDark, setIsDark] = useState(true);
  const [clockText, setClockText] = useState('');
  const [wsConnected, setWsConnected] = useState(false);
  const [systemLogs, setSystemLogs] = useState<string[]>([
    'SYSTEM: Khởi động giao diện quản trị SmartHome IoT.',
  ]);

  // ==================== DOMAIN DATA STATE ====================
  const [houses, setHouses] = useState<House[]>([]);
  const [rooms, setRooms] = useState<Room[]>([]);
  const [devices, setDevices] = useState<Device[]>([]);
  const [automations, setAutomations] = useState<AutomationRule[]>([]);
  const [aiAlerts, setAiAlerts] = useState<AiAlert[]>([]);
  const [usersList, setUsersList] = useState<UserProfile[]>([]);

  const [sensorData, setSensorData] = useState<{
    temperature: number;
    humidity: number;
    lux: number;
    motion: boolean;
  } | null>(null);

  const [energyPeriod, setEnergyPeriod] = useState<EnergyPeriod>('week');
  const [energyData, setEnergyData] = useState<EnergyState>({
    total_kwh: 0,
    estimated_cost: 0,
    peak_watt: 0,
    daily: [],
  });

  // ==================== FILTER & FORM STATES ====================
  const [selectedHouseId, setSelectedHouseId] = useState<string | null>(null);
  const [selectedRoomId, setSelectedRoomId] = useState<string | null>(null);

  // House form & edit
  const [newHouseName, setNewHouseName] = useState('');
  const [newHouseAddress, setNewHouseAddress] = useState('');
  const [editingHouse, setEditingHouse] = useState<House | null>(null);

  // Room form & edit
  const [newRoomHouseId, setNewRoomHouseId] = useState('');
  const [newRoomName, setNewRoomName] = useState('');
  const [newRoomFloor, setNewRoomFloor] = useState(1);
  const [editingRoom, setEditingRoom] = useState<Room | null>(null);

  // Device form, edit & discovery
  const [newDeviceName, setNewDeviceName] = useState('');
  const [newDeviceType, setNewDeviceType] = useState('light');
  const [newDeviceTopic, setNewDeviceTopic] = useState('');
  const [newDeviceRoomId, setNewDeviceRoomId] = useState('');
  const [editingDevice, setEditingDevice] = useState<Device | null>(null);
  const [discoveringDevices, setDiscoveringDevices] = useState(false);

  // Excel Space & Device Preview States
  const fileInputRef = useRef<HTMLInputElement | null>(null);
  const [excelPreviewSpace, setExcelPreviewSpace] = useState<ExcelSpacePreviewItem[]>([]);
  const [spaceExcelFileName, setSpaceExcelFileName] = useState<string>('');
  const [isImportingSpace, setIsImportingSpace] = useState<boolean>(false);

  // Automation form
  const [newAutoName, setNewAutoName] = useState('');
  const [newAutoCondition, setNewAutoCondition] = useState('');
  const [newAutoAction, setNewAutoAction] = useState('');

  // Sub-account form, edit & Excel Preview States
  const [newUserName, setNewUserName] = useState('');
  const [newUserEmail, setNewUserEmail] = useState('');
  const [newUserPassword, setNewUserPassword] = useState('');
  const [newUserRole, setNewUserRole] = useState('Member');
  const [editingUser, setEditingUser] = useState<UserProfile | null>(null);

  const userExcelInputRef = useRef<HTMLInputElement | null>(null);
  const [excelPreviewUsers, setExcelPreviewUsers] = useState<ExcelUserPreviewItem[]>([]);
  const [excelFileName, setExcelFileName] = useState<string>('');
  const [isImportingUsers, setIsImportingUsers] = useState<boolean>(false);

  // ==================== PERMISSION CHECK ====================
  const normalizedRole = (currentUser?.role || '').trim().toLowerCase();
  const isOwnerOrAdmin = normalizedRole === 'owner' || normalizedRole === 'admin';

  const appendLog = (msg: string) => {
    const time = new Date().toLocaleTimeString('vi-VN', { hour12: false });
    setSystemLogs((prev) => [`[${time}] ${msg}`, ...prev].slice(0, 40));
  };

  // ==================== CLOCK ====================
  useEffect(() => {
    const updateClock = () => {
      const now = new Date();
      const timePart = now.toLocaleTimeString('vi-VN', { hour12: false });
      const datePart = now.toLocaleDateString('vi-VN');
      setClockText(`${timePart}  ${datePart}`);
    };
    updateClock();
    const timer = setInterval(updateClock, 1000);
    return () => clearInterval(timer);
  }, []);

  // ==================== FETCH DATA ====================
  const getAuthHeaders = (): HeadersInit => {
    const token = localStorage.getItem('token') || '';
    return {
      'Content-Type': 'application/json',
      Authorization: `Bearer ${token}`,
    };
  };

  const fetchAllDatabaseData = async (periodOverride?: EnergyPeriod) => {
    const token = localStorage.getItem('token');
    if (!token) return;

    const headers = getAuthHeaders();
    const activePeriod = periodOverride || energyPeriod;

    try {
      const [meRes, housesRes, roomsRes, devicesRes, autoRes, energyRes, aiRes] =
        await Promise.all([
          fetch(`${API_BASE}/auth/me`, { headers }).catch(() => null),
          fetch(`${API_BASE}/houses`, { headers }).catch(() => null),
          fetch(`${API_BASE}/rooms`, { headers }).catch(() => null),
          fetch(`${API_BASE}/devices`, { headers }).catch(() => null),
          fetch(`${API_BASE}/automations`, { headers }).catch(() => null),
          fetch(`${API_BASE}/energy/analytics?period=${activePeriod}`, { headers }).catch(
            () => null
          ),
          fetch(`${API_BASE}/ai/alerts`, { headers }).catch(() => null),
        ]);

      if (meRes && meRes.status === 401) {
        handleLogout();
        return;
      }

      let effectiveRole = currentUser?.role || 'Member';
      if (meRes && meRes.ok) {
        const meData = await meRes.json();
        if (meData?.role) {
          effectiveRole = meData.role;
          setCurrentUser((prev) => {
            if (!prev) return prev;
            const updated: UserProfile = {
              ...prev,
              id: meData.id || prev.id,
              name: meData.name || prev.name,
              email: meData.email || prev.email,
              role: meData.role,
              owner_id: meData.owner_id ?? prev.owner_id,
            };
            localStorage.setItem('smarthome_user', JSON.stringify(updated));
            return updated;
          });
        }
      }

      if (housesRes && housesRes.ok) {
        const data = await housesRes.json();
        const list = Array.isArray(data) ? data : [];
        setHouses(list);
        if (list.length > 0 && !newRoomHouseId) {
          setNewRoomHouseId(list[0].id);
        }
      }

      if (roomsRes && roomsRes.ok) {
        const data = await roomsRes.json();
        setRooms(Array.isArray(data) ? data : []);
      }

      if (devicesRes && devicesRes.ok) {
        const data = await devicesRes.json();
        setDevices(Array.isArray(data) ? data : []);
      }

      if (autoRes && autoRes.ok) {
        const data = await autoRes.json();
        setAutomations(Array.isArray(data) ? data : []);
      }

      if (energyRes && energyRes.ok) {
        const data = await energyRes.json();
        const totalKwh = Number(data?.total_kwh ?? 0);
        const dailyRaw = Array.isArray(data?.daily)
          ? data.daily
          : Array.isArray(data?.chart_data)
          ? data.chart_data
          : [];
        const normalizedDaily: EnergyPoint[] = dailyRaw.map(
          (item: Record<string, unknown>, idx: number) => ({
            label: String(item.label ?? item.day ?? `N${idx + 1}`),
            kwh: Number(item.kwh ?? item.value ?? 0),
            power_watt: Number(item.power_watt ?? 0),
          })
        );

        setEnergyData({
          total_kwh: totalKwh,
          estimated_cost: Number(
            data?.estimated_cost ?? data?.total_vnd ?? Math.round(totalKwh * 2500)
          ),
          peak_watt: Number(data?.peak_watt ?? 0),
          daily: normalizedDaily,
        });
      }

      if (aiRes && aiRes.ok) {
        const data = await aiRes.json();
        setAiAlerts(Array.isArray(data) ? data : []);
      }

      const roleLower = effectiveRole.trim().toLowerCase();
      if (roleLower === 'owner' || roleLower === 'admin') {
        const usersRes = await fetch(`${API_BASE}/users`, { headers }).catch(() => null);
        if (usersRes && usersRes.ok) {
          const uData = await usersRes.json();
          setUsersList(Array.isArray(uData) ? uData : []);
        }
      } else {
        setUsersList([]);
      }
    } catch (err) {
      console.error('Fetch error:', err);
    }
  };

  useEffect(() => {
    if (!currentUser) return;
    fetchAllDatabaseData();
    const interval = setInterval(() => fetchAllDatabaseData(), 15000);
    return () => clearInterval(interval);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [currentUser?.id, energyPeriod]);

  // ==================== WEBSOCKET REALTIME ====================
  useEffect(() => {
    if (!currentUser) return;

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
  }, [currentUser?.id]);

  // ==================== AUTH HANDLERS ====================
  const handleAuthSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    setAuthError('');
    setAuthLoading(true);

    try {
      const endpoint = authMode === 'login' ? '/auth/login' : '/auth/register';
      const body =
        authMode === 'login'
          ? { email: authEmail.trim(), password: authPassword }
          : { name: authName.trim(), email: authEmail.trim(), password: authPassword };

      const res = await fetch(`${API_BASE}${endpoint}`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(body),
      });

      const data = await res.json();
      if (!res.ok) {
        setAuthError(data?.error || 'Xác thực thất bại, vui lòng thử lại.');
        return;
      }

      if (data?.token && data?.user) {
        localStorage.setItem('token', data.token);
        localStorage.setItem('smarthome_user', JSON.stringify(data.user));
        setCurrentUser(data.user);
        setActiveTab('overview');
        setAuthName('');
        setAuthEmail('');
        setAuthPassword('');
        appendLog(`Đăng nhập thành công với vai trò ${data.user.role}.`);
      }
    } catch {
      setAuthError('Không thể kết nối tới máy chủ Backend.');
    } finally {
      setAuthLoading(false);
    }
  };

  const handleLogout = () => {
    localStorage.removeItem('token');
    localStorage.removeItem('smarthome_user');
    setCurrentUser(null);
    setUsersList([]);
    setHouses([]);
    setRooms([]);
    setDevices([]);
    setAutomations([]);
    setAiAlerts([]);
    setSensorData(null);
    setEnergyData({ total_kwh: 0, estimated_cost: 0, peak_watt: 0, daily: [] });
    setSelectedHouseId(null);
    setSelectedRoomId(null);
    setExcelPreviewSpace([]);
    setSpaceExcelFileName('');
    setExcelPreviewUsers([]);
    setExcelFileName('');
    setEditingHouse(null);
    setEditingRoom(null);
    setEditingDevice(null);
    setEditingUser(null);
    setActiveTab('overview');
    setSystemLogs(['SYSTEM: Đã đăng xuất khỏi phiên làm việc.']);
  };

  // ==================== HOUSE / ROOM / DEVICE HANDLERS ====================
  const handleCreateHouse = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!newHouseName.trim()) return;

    const res = await fetch(`${API_BASE}/houses`, {
      method: 'POST',
      headers: getAuthHeaders(),
      body: JSON.stringify({ name: newHouseName.trim(), address: newHouseAddress.trim() }),
    });
    if (res.ok) {
      appendLog(`Đã thêm ngôi nhà "${newHouseName.trim()}".`);
      setNewHouseName('');
      setNewHouseAddress('');
      fetchAllDatabaseData();
    } else {
      const err = await res.json().catch(() => ({}));
      alert(err.error || 'Không thể tạo ngôi nhà');
    }
  };

  const handleUpdateHouse = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!editingHouse || !editingHouse.name.trim()) return;

    const res = await fetch(`${API_BASE}/houses/${editingHouse.id}`, {
      method: 'PUT',
      headers: getAuthHeaders(),
      body: JSON.stringify({
        name: editingHouse.name.trim(),
        address: editingHouse.address.trim(),
      }),
    });
    if (res.ok) {
      appendLog(`Đã cập nhật thông tin nhà "${editingHouse.name.trim()}".`);
      setEditingHouse(null);
      fetchAllDatabaseData();
    } else {
      const err = await res.json().catch(() => ({}));
      alert(err.error || 'Không thể cập nhật ngôi nhà');
    }
  };

  const handleDeleteHouse = async (house: House) => {
    if (!confirm(`Xóa ngôi nhà "${house.name}" và toàn bộ phòng bên trong?`)) return;
    const res = await fetch(`${API_BASE}/houses/${house.id}`, {
      method: 'DELETE',
      headers: getAuthHeaders(),
    });
    if (res.ok) {
      if (selectedHouseId === house.id) setSelectedHouseId(null);
      appendLog(`Đã xóa ngôi nhà "${house.name}".`);
      fetchAllDatabaseData();
    }
  };

  const handleCreateRoom = async (e: React.FormEvent) => {
    e.preventDefault();
    const targetHouse = newRoomHouseId || houses[0]?.id;
    if (!targetHouse || !newRoomName.trim()) {
      alert('Vui lòng tạo ít nhất 1 Ngôi nhà trước khi thêm phòng.');
      return;
    }

    const res = await fetch(`${API_BASE}/rooms`, {
      method: 'POST',
      headers: getAuthHeaders(),
      body: JSON.stringify({
        house_id: targetHouse,
        name: newRoomName.trim(),
        floor: Number(newRoomFloor) || 1,
      }),
    });
    if (res.ok) {
      appendLog(`Đã thêm phòng "${newRoomName.trim()}".`);
      setNewRoomName('');
      fetchAllDatabaseData();
    } else {
      const err = await res.json().catch(() => ({}));
      alert(err.error || 'Không thể tạo phòng');
    }
  };

  const handleUpdateRoom = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!editingRoom || !editingRoom.name.trim()) return;

    const res = await fetch(`${API_BASE}/rooms/${editingRoom.id}`, {
      method: 'PUT',
      headers: getAuthHeaders(),
      body: JSON.stringify({
        house_id: editingRoom.house_id,
        name: editingRoom.name.trim(),
        floor: Number(editingRoom.floor) || 1,
      }),
    });
    if (res.ok) {
      appendLog(`Đã cập nhật phòng "${editingRoom.name.trim()}".`);
      setEditingRoom(null);
      fetchAllDatabaseData();
    } else {
      const err = await res.json().catch(() => ({}));
      alert(err.error || 'Không thể cập nhật phòng');
    }
  };

  const handleDeleteRoom = async (room: Room) => {
    if (!confirm(`Xóa phòng "${room.name}"? Các thiết bị sẽ chuyển về Chưa phân phòng.`)) return;
    const res = await fetch(`${API_BASE}/rooms/${room.id}`, {
      method: 'DELETE',
      headers: getAuthHeaders(),
    });
    if (res.ok) {
      if (selectedRoomId === room.id) setSelectedRoomId(null);
      appendLog(`Đã xóa phòng "${room.name}".`);
      fetchAllDatabaseData();
    }
  };

  const handleCreateDevice = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!newDeviceName.trim() || !newDeviceTopic.trim()) return;

    const res = await fetch(`${API_BASE}/devices`, {
      method: 'POST',
      headers: getAuthHeaders(),
      body: JSON.stringify({
        name: newDeviceName.trim(),
        device_type: newDeviceType,
        mqtt_topic: newDeviceTopic.trim(),
        room_id: newDeviceRoomId || null,
      }),
    });
    if (res.ok) {
      appendLog(`Đã thêm thiết bị "${newDeviceName.trim()}".`);
      setNewDeviceName('');
      setNewDeviceTopic('');
      fetchAllDatabaseData();
    } else {
      const err = await res.json().catch(() => ({}));
      alert(err.error || 'Không thể thêm thiết bị');
    }
  };

  const handleUpdateDevice = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!editingDevice || !editingDevice.name.trim() || !editingDevice.mqtt_topic.trim()) return;

    const res = await fetch(`${API_BASE}/devices/${editingDevice.id}`, {
      method: 'PUT',
      headers: getAuthHeaders(),
      body: JSON.stringify({
        name: editingDevice.name.trim(),
        device_type: editingDevice.device_type,
        mqtt_topic: editingDevice.mqtt_topic.trim(),
        room_id: editingDevice.room_id || null,
      }),
    });
    if (res.ok) {
      appendLog(`Đã cập nhật thiết bị "${editingDevice.name.trim()}".`);
      setEditingDevice(null);
      fetchAllDatabaseData();
    } else {
      const err = await res.json().catch(() => ({}));
      alert(err.error || 'Không thể cập nhật thiết bị');
    }
  };

  const handleToggleDevice = async (device: Device) => {
    const nextState = !device.is_on;
    setDevices((prev) =>
      prev.map((d) => (d.id === device.id ? { ...d, is_on: nextState } : d))
    );

    const res = await fetch(`${API_BASE}/devices/${device.id}/control`, {
      method: 'POST',
      headers: getAuthHeaders(),
      body: JSON.stringify({ is_on: nextState, action: nextState ? 'ON' : 'OFF' }),
    });

    if (res.ok) {
      appendLog(`MQTT [${device.mqtt_topic}] -> ${device.name}: ${nextState ? 'BẬT' : 'TẮT'}`);
    } else {
      setDevices((prev) =>
        prev.map((d) => (d.id === device.id ? { ...d, is_on: !nextState } : d))
      );
    }
  };

  const handleDeleteDevice = async (device: Device) => {
    if (!confirm(`Xóa thiết bị "${device.name}"?`)) return;
    const res = await fetch(`${API_BASE}/devices/${device.id}`, {
      method: 'DELETE',
      headers: getAuthHeaders(),
    });
    if (res.ok) {
      appendLog(`Đã xóa thiết bị "${device.name}".`);
      fetchAllDatabaseData();
    }
  };

  const handleDiscoverDevices = async () => {
    setDiscoveringDevices(true);
    try {
      const res = await fetch(`${API_BASE}/devices/discover`, {
        headers: getAuthHeaders(),
      });
      if (res.ok) {
        const data = await res.json();
        const foundList = Array.isArray(data)
          ? data
          : Array.isArray(data?.devices)
          ? data.devices
          : [];
        appendLog(`Quét MQTT Discovery: phát hiện ${foundList.length} thiết bị.`);
        if (foundList.length === 0) {
          alert('Hiện chưa có thiết bị mới nào phát tín hiệu trên topic smarthome/discovery.');
        } else {
          const existingTopics = new Set(devices.map((d) => d.mqtt_topic.trim().toLowerCase()));
          const previewDiscovered: ExcelSpacePreviewItem[] = foundList.map(
            (item: Record<string, unknown>, idx: number) => {
              const topic = String(item.mqtt_topic || '').trim();
              const name = String(item.name || topic || `Thiết bị MQTT ${idx + 1}`).trim();
              const dType = String(item.device_type || 'switch').trim().toLowerCase();
              const isDup = existingTopics.has(topic.toLowerCase());
              return {
                id: `discover-${idx}-${topic}`,
                sheetName: 'MQTT Discovery',
                rowNumber: idx + 1,
                kind: 'device',
                name,
                deviceType: ['light', 'fan', 'ac', 'switch', 'sensor'].includes(dType)
                  ? dType
                  : 'switch',
                mqttTopic: topic,
                isValid: Boolean(topic) && !isDup,
                errorReason: !topic
                  ? 'Thiếu MQTT Topic'
                  : isDup
                  ? 'Thiết bị đã được kết nối trong nhà'
                  : undefined,
              };
            }
          );
          setSpaceExcelFileName('MQTT Discovery (ESP32)');
          setExcelPreviewSpace(previewDiscovered);
        }
      }
    } finally {
      setDiscoveringDevices(false);
    }
  };

  // ==================== EXCEL HELPERS ====================
  const normalizeExcelKey = (key: string): string =>
    key
      .trim()
      .toLowerCase()
      .normalize('NFD')
      .replace(/[\u0300-\u036f]/g, '')
      .replace(/đ/g, 'd')
      .replace(/[^a-z0-9]/g, '');

  const readExcelRows = async (file: File): Promise<Record<string, unknown>[]> => {
    const xlsxLib = (XLSX as unknown as { default?: typeof XLSX }).default || XLSX;
    const buffer = await file.arrayBuffer();
    const bytes = new Uint8Array(buffer);
    const workbook = xlsxLib.read(bytes, { type: 'array' });
    const firstSheet = workbook.SheetNames[0];
    if (!firstSheet) return [];
    const sheet = workbook.Sheets[firstSheet];
    return xlsxLib.utils.sheet_to_json<Record<string, unknown>>(sheet, { defval: '' });
  };

  const readAllExcelSheets = async (
    file: File
  ): Promise<{ sheetName: string; rowNumber: number; data: Record<string, unknown> }[]> => {
    const xlsxLib = (XLSX as unknown as { default?: typeof XLSX }).default || XLSX;
    const buffer = await file.arrayBuffer();
    const bytes = new Uint8Array(buffer);
    const workbook = xlsxLib.read(bytes, { type: 'array' });
    const allRows: { sheetName: string; rowNumber: number; data: Record<string, unknown> }[] = [];

    for (const sheetName of workbook.SheetNames) {
      const sheet = workbook.Sheets[sheetName];
      if (!sheet) continue;
      const rows = xlsxLib.utils.sheet_to_json<Record<string, unknown>>(sheet, { defval: '' });
      rows.forEach((data, idx) => {
        allRows.push({ sheetName, rowNumber: idx + 2, data });
      });
    }
    return allRows;
  };

  // ==================== EXCEL EXPORT & IMPORT SPACES / DEVICES ====================
  const handleExportExcel = () => {
    const xlsxLib = (XLSX as unknown as { default?: typeof XLSX }).default || XLSX;
    const workbook = xlsxLib.utils.book_new();

    // Sheet 1: Nhà & Phòng
    const spaceRows: Record<string, unknown>[] = [];
    if (rooms.length > 0) {
      rooms.forEach((r, idx) => {
        const houseObj = houses.find((h) => h.id === r.house_id);
        spaceRows.push({
          STT: idx + 1,
          TenNha: r.house_name || houseObj?.name || 'Nhà chính',
          DiaChi: houseObj?.address || '',
          TenPhong: r.name,
          Tang: r.floor || 1,
        });
      });
    } else if (houses.length > 0) {
      houses.forEach((h, idx) => {
        spaceRows.push({
          STT: idx + 1,
          TenNha: h.name,
          DiaChi: h.address || '',
          TenPhong: '',
          Tang: 1,
        });
      });
    } else {
      spaceRows.push({
        STT: 1,
        TenNha: 'Nhà Quận 7',
        DiaChi: '123 Nguyễn Văn Linh',
        TenPhong: 'Phòng khách',
        Tang: 1,
      });
    }
    const spaceSheet = xlsxLib.utils.json_to_sheet(spaceRows);
    xlsxLib.utils.book_append_sheet(workbook, spaceSheet, 'Nha_Va_Phong');

    // Sheet 2: Thiết bị IoT
    const deviceRows =
      devices.length > 0
        ? devices.map((d, idx) => ({
            STT: idx + 1,
            TenThietBi: d.name,
            LoaiThietBi: d.device_type,
            MqttTopic: d.mqtt_topic,
            Phong: d.room_name || '',
            TrangThai: d.is_on ? 'BẬT' : 'TẮT',
          }))
        : [
            {
              STT: 1,
              TenThietBi: 'Đèn trần phòng khách',
              LoaiThietBi: 'light',
              MqttTopic: 'smarthome/devices/led_phong_khach',
              Phong: 'Phòng khách',
              TrangThai: 'TẮT',
            },
          ];
    const deviceSheet = xlsxLib.utils.json_to_sheet(deviceRows);
    xlsxLib.utils.book_append_sheet(workbook, deviceSheet, 'ThietBi_SmartHome');

    xlsxLib.writeFile(
      workbook,
      `SmartHome_Nha_Phong_ThietBi_${new Date().toISOString().slice(0, 10)}.xlsx`
    );
    appendLog('Đã xuất file Excel Nhà, Phòng & Thiết bị (.xlsx).');
  };

  // Bước 1: Tải file Excel Nhà / Phòng / Thiết bị -> Hiển thị danh sách kiểm tra hợp lệ
  const handleImportExcel = async (e: React.ChangeEvent<HTMLInputElement>) => {
    const file = e.target.files?.[0];
    if (!file) return;

    let rawEntries: { sheetName: string; rowNumber: number; data: Record<string, unknown> }[] = [];
    try {
      rawEntries = await readAllExcelSheets(file);
    } catch (err) {
      console.error('Parse space Excel error:', err);
      alert(`Lỗi đọc file Excel: ${(err as Error)?.message || 'File không hợp lệ'}`);
      if (fileInputRef.current) fileInputRef.current.value = '';
      return;
    }

    if (rawEntries.length === 0) {
      alert('File Excel trống, không có dòng dữ liệu nào.');
      if (fileInputRef.current) fileInputRef.current.value = '';
      return;
    }

    const existingHouseNames = new Set(houses.map((h) => h.name.trim().toLowerCase()));
    const existingRoomKeys = new Set(
      rooms.map(
        (r) => `${(r.house_name || '').trim().toLowerCase()}::${r.name.trim().toLowerCase()}`
      )
    );
    const existingRoomNamesOnly = new Set(rooms.map((r) => r.name.trim().toLowerCase()));
    const existingDeviceTopics = new Set(devices.map((d) => d.mqtt_topic.trim().toLowerCase()));

    const seenHousesInFile = new Set<string>();
    const seenRoomsInFile = new Set<string>();
    const seenTopicsInFile = new Set<string>();
    const detectedColumns = new Set<string>();

    const previewList: ExcelSpacePreviewItem[] = [];

    rawEntries.forEach((entry, idx) => {
      const norm: Record<string, string> = {};
      Object.entries(entry.data).forEach(([k, v]) => {
        detectedColumns.add(k);
        norm[normalizeExcelKey(k)] = String(v ?? '').trim();
      });

      const houseName =
        norm['tennha'] || norm['nha'] || norm['house'] || norm['housename'] || '';
      const address = norm['diachi'] || norm['address'] || '';
      const roomName =
        norm['tenphong'] || norm['phong'] || norm['room'] || norm['roomname'] || '';
      const floorRaw = norm['tang'] || norm['floor'] || '1';
      const floor = Number.parseInt(floorRaw, 10) || 1;

      const deviceName =
        norm['tenthietbi'] || norm['thietbi'] || norm['device'] || norm['devicename'] || '';
      const mqttTopic = norm['mqtttopic'] || norm['topic'] || norm['mqtt'] || '';
      const rawDeviceType = (
        norm['loaithietbi'] ||
        norm['loai'] ||
        norm['devicetype'] ||
        norm['type'] ||
        'switch'
      ).toLowerCase();

      if (!houseName && !roomName && !deviceName && !mqttTopic) {
        return;
      }

      // Nhánh 1: Dòng khai báo Thiết bị IoT
      if (deviceName || mqttTopic) {
        let isValid = true;
        let errorReason = '';

        if (!deviceName) {
          isValid = false;
          errorReason = 'Thiếu tên thiết bị (TenThietBi)';
        } else if (!mqttTopic) {
          isValid = false;
          errorReason = 'Thiếu MQTT Topic (MqttTopic)';
        } else if (existingDeviceTopics.has(mqttTopic.toLowerCase())) {
          isValid = false;
          errorReason = 'MQTT Topic đã tồn tại trong nhà';
        } else if (seenTopicsInFile.has(mqttTopic.toLowerCase())) {
          isValid = false;
          errorReason = 'Trùng MQTT Topic ngay trong file Excel';
        }

        if (mqttTopic) seenTopicsInFile.add(mqttTopic.toLowerCase());

        const validTypes = ['light', 'fan', 'ac', 'switch', 'sensor'];
        const normalizedType = validTypes.includes(rawDeviceType) ? rawDeviceType : 'switch';

        previewList.push({
          id: `${entry.sheetName}-${entry.rowNumber}-${idx}`,
          sheetName: entry.sheetName,
          rowNumber: entry.rowNumber,
          kind: 'device',
          name: deviceName,
          houseName,
          roomName,
          deviceType: normalizedType,
          mqttTopic,
          isValid,
          errorReason: isValid ? undefined : errorReason,
        });
        return;
      }

      // Nhánh 2: Dòng khai báo Phòng
      if (roomName) {
        const hKey = houseName.toLowerCase();
        const rKey = roomName.toLowerCase();
        const compositeKey = `${hKey}::${rKey}`;

        let isValid = true;
        let errorReason = '';

        const isDupInDb = hKey
          ? existingRoomKeys.has(compositeKey)
          : existingRoomNamesOnly.has(rKey);

        if (isDupInDb) {
          isValid = false;
          errorReason = `Phòng "${roomName}" đã tồn tại`;
        } else if (seenRoomsInFile.has(compositeKey)) {
          isValid = false;
          errorReason = 'Trùng tên phòng ngay trong file Excel';
        }

        seenRoomsInFile.add(compositeKey);

        previewList.push({
          id: `${entry.sheetName}-${entry.rowNumber}-${idx}`,
          sheetName: entry.sheetName,
          rowNumber: entry.rowNumber,
          kind: 'room',
          name: roomName,
          houseName: houseName || houses[0]?.name || 'Nhà chính',
          floor,
          isValid,
          errorReason: isValid ? undefined : errorReason,
        });
        return;
      }

      // Nhánh 3: Dòng khai báo Ngôi nhà
      if (houseName) {
        const hKey = houseName.toLowerCase();
        let isValid = true;
        let errorReason = '';

        if (existingHouseNames.has(hKey)) {
          isValid = false;
          errorReason = `Ngôi nhà "${houseName}" đã tồn tại`;
        } else if (seenHousesInFile.has(hKey)) {
          isValid = false;
          errorReason = 'Trùng tên nhà ngay trong file Excel';
        }

        seenHousesInFile.add(hKey);

        previewList.push({
          id: `${entry.sheetName}-${entry.rowNumber}-${idx}`,
          sheetName: entry.sheetName,
          rowNumber: entry.rowNumber,
          kind: 'house',
          name: houseName,
          address,
          isValid,
          errorReason: isValid ? undefined : errorReason,
        });
      }
    });

    if (fileInputRef.current) fileInputRef.current.value = '';

    if (previewList.length === 0) {
      alert(
        `Không nhận diện được cột dữ liệu hợp lệ trong file "${file.name}".\n` +
          `Các cột đọc được: ${Array.from(detectedColumns).join(', ') || '(Trống)'}\n\n` +
          `Gợi ý tên cột chuẩn:\n` +
          `• Nhà & Phòng: TenNha, DiaChi, TenPhong, Tang\n` +
          `• Thiết bị: TenThietBi, LoaiThietBi, MqttTopic, Phong`
      );
      return;
    }

    const validCount = previewList.filter((i) => i.isValid).length;
    setSpaceExcelFileName(file.name);
    setExcelPreviewSpace(previewList);
    appendLog(
      `Đã đọc file "${file.name}": ${validCount}/${previewList.length} mục Nhà/Phòng/Thiết bị hợp lệ.`
    );
  };

  const handleRemovePreviewSpaceItem = (id: string) => {
    setExcelPreviewSpace((prev) => {
      const next = prev.filter((item) => item.id !== id);
      if (next.length === 0) setSpaceExcelFileName('');
      return next;
    });
  };

  // Bước 2: Xác nhận lưu các mục Nhà / Phòng / Thiết bị hợp lệ vào PostgreSQL
  const handleConfirmImportSpaceItems = async () => {
    const validItems = excelPreviewSpace.filter((i) => i.isValid);
    if (validItems.length === 0) return;

    setIsImportingSpace(true);
    let createdCount = 0;
    const failedMap = new Map<string, string>();

    const houseNameToId = new Map<string, string>();
    houses.forEach((h) => houseNameToId.set(h.name.trim().toLowerCase(), h.id));

    const roomNameToId = new Map<string, string>();
    rooms.forEach((r) => roomNameToId.set(r.name.trim().toLowerCase(), r.id));

    const ensureHouseId = async (houseTitle?: string, addr = ''): Promise<string | null> => {
      const cleanName = (houseTitle || '').trim();
      if (!cleanName) {
        return houses[0]?.id || Array.from(houseNameToId.values())[0] || null;
      }
      const key = cleanName.toLowerCase();
      if (houseNameToId.has(key)) return houseNameToId.get(key)!;

      const res = await fetch(`${API_BASE}/houses`, {
        method: 'POST',
        headers: getAuthHeaders(),
        body: JSON.stringify({ name: cleanName, address: addr }),
      });
      if (res.ok) {
        const created = await res.json().catch(() => null);
        if (created?.id) {
          houseNameToId.set(key, created.id);
          return created.id;
        }
      }
      return houses[0]?.id || Array.from(houseNameToId.values())[0] || null;
    };

    try {
      // 1. Tạo các Ngôi nhà trước
      for (const item of validItems.filter((i) => i.kind === 'house')) {
        const res = await fetch(`${API_BASE}/houses`, {
          method: 'POST',
          headers: getAuthHeaders(),
          body: JSON.stringify({ name: item.name, address: item.address || '' }),
        });
        if (res.ok) {
          const created = await res.json().catch(() => null);
          if (created?.id) {
            houseNameToId.set(item.name.trim().toLowerCase(), created.id);
          }
          createdCount++;
        } else {
          const err = await res.json().catch(() => ({}));
          failedMap.set(item.id, err.error || `Lỗi HTTP ${res.status}`);
        }
      }

      // 2. Tạo các Phòng (tự tạo Nhà nếu file Excel có khai báo TenNha mới)
      for (const item of validItems.filter((i) => i.kind === 'room')) {
        const targetHouseId = await ensureHouseId(item.houseName);
        if (!targetHouseId) {
          failedMap.set(item.id, 'Chưa có Ngôi nhà để gắn phòng');
          continue;
        }

        const res = await fetch(`${API_BASE}/rooms`, {
          method: 'POST',
          headers: getAuthHeaders(),
          body: JSON.stringify({
            house_id: targetHouseId,
            name: item.name,
            floor: item.floor || 1,
          }),
        });
        if (res.ok) {
          createdCount++;
        } else {
          const err = await res.json().catch(() => ({}));
          const rawMsg = String(err.error || `Lỗi HTTP ${res.status}`);
          const friendlyMsg =
            rawMsg.includes('devices_mqtt_topic_key') ||
            rawMsg.includes('idx_devices_owner_mqtt_topic')
              ? 'MQTT Topic này đã tồn tại trên hệ thống'
              : rawMsg;
          failedMap.set(item.id, friendlyMsg);
        }
      }

      // 3. Tạo các Thiết bị IoT (tự động gán vào Phòng vừa tạo hoặc Phòng đã có)
      for (const item of validItems.filter((i) => i.kind === 'device')) {
        let targetRoomId: string | null = null;
        if (item.roomName) {
          const rKey = item.roomName.trim().toLowerCase();
          if (roomNameToId.has(rKey)) {
            targetRoomId = roomNameToId.get(rKey)!;
          } else {
            const hId = await ensureHouseId(item.houseName);
            if (hId) {
              const roomRes = await fetch(`${API_BASE}/rooms`, {
                method: 'POST',
                headers: getAuthHeaders(),
                body: JSON.stringify({ house_id: hId, name: item.roomName.trim(), floor: 1 }),
              });
              if (roomRes.ok) {
                const createdRoom = await roomRes.json().catch(() => null);
                if (createdRoom?.id) {
                  roomNameToId.set(rKey, createdRoom.id);
                  targetRoomId = createdRoom.id;
                }
              }
            }
          }
        }

        const res = await fetch(`${API_BASE}/devices`, {
          method: 'POST',
          headers: getAuthHeaders(),
          body: JSON.stringify({
            name: item.name,
            device_type: item.deviceType || 'switch',
            mqtt_topic: item.mqttTopic,
            room_id: targetRoomId,
          }),
        });
        if (res.ok) {
          createdCount++;
        } else {
          const err = await res.json().catch(() => ({}));
          failedMap.set(item.id, err.error || `Lỗi HTTP ${res.status}`);
        }
      }

      appendLog(`Đã nhập thành công ${createdCount} mục Nhà/Phòng/Thiết bị từ Excel.`);
      await fetchAllDatabaseData();

      if (failedMap.size === 0) {
        setExcelPreviewSpace([]);
        setSpaceExcelFileName('');
      } else {
        setExcelPreviewSpace((prev) =>
          prev
            .filter((item) => !item.isValid || failedMap.has(item.id))
            .map((item) =>
              failedMap.has(item.id)
                ? { ...item, isValid: false, errorReason: failedMap.get(item.id) }
                : item
            )
        );
      }
    } finally {
      setIsImportingSpace(false);
    }
  };

  // ==================== AUTOMATION HANDLERS ====================
  const handleCreateAutomation = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!newAutoName.trim() || !newAutoCondition.trim() || !newAutoAction.trim()) return;

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
      setNewAutoCondition('');
      setNewAutoAction('');
      fetchAllDatabaseData();
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
      fetchAllDatabaseData();
    }
  };

  // ==================== AI ANOMALY HANDLER ====================
  const handleSimulateAnomaly = async () => {
    const res = await fetch(`${API_BASE}/ai/simulate-anomaly`, {
      method: 'POST',
      headers: getAuthHeaders(),
      body: JSON.stringify({ temperature: 65.0, sensor_id: 'ESP32-DHT22-01' }),
    });
    if (res.ok) {
      appendLog('Đã kích hoạt mô phỏng cảnh báo quá nhiệt AI.');
      fetchAllDatabaseData();
    }
  };

  // ==================== ACCOUNT MANAGEMENT HANDLERS ====================
  const handleCreateSubUser = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!newUserName.trim() || !newUserEmail.trim() || !newUserPassword.trim()) return;

    const res = await fetch(`${API_BASE}/users`, {
      method: 'POST',
      headers: getAuthHeaders(),
      body: JSON.stringify({
        name: newUserName.trim(),
        email: newUserEmail.trim(),
        password: newUserPassword,
        role: newUserRole,
      }),
    });

    const data = await res.json().catch(() => ({}));
    if (res.ok) {
      appendLog(`Đã tạo tài khoản thành viên ${newUserEmail.trim()} (${newUserRole}).`);
      setNewUserName('');
      setNewUserEmail('');
      setNewUserPassword('');
      setNewUserRole('Member');
      fetchAllDatabaseData();
    } else {
      alert(data.error || 'Không thể tạo tài khoản');
    }
  };

  const handleUpdateUser = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!editingUser || !editingUser.name.trim()) return;

    const res = await fetch(`${API_BASE}/users/${editingUser.id}`, {
      method: 'PUT',
      headers: getAuthHeaders(),
      body: JSON.stringify({
        name: editingUser.name.trim(),
        role: editingUser.role,
      }),
    });
    if (res.ok) {
      appendLog(`Đã cập nhật tài khoản ${editingUser.email} (${editingUser.role}).`);
      setEditingUser(null);
      fetchAllDatabaseData();
    } else {
      const err = await res.json().catch(() => ({}));
      alert(err.error || 'Không thể cập nhật tài khoản');
    }
  };

  const handleDeleteUser = async (u: UserProfile) => {
    if (!confirm(`Xóa tài khoản "${u.name}" (${u.email}) khỏi gia đình?`)) return;
    const res = await fetch(`${API_BASE}/users/${u.id}`, {
      method: 'DELETE',
      headers: getAuthHeaders(),
    });
    if (res.ok) {
      appendLog(`Đã xóa tài khoản ${u.email}.`);
      fetchAllDatabaseData();
    } else {
      const err = await res.json().catch(() => ({}));
      alert(err.error || 'Không thể xóa tài khoản này');
    }
  };

  // ==================== EXCEL EXPORT & IMPORT USERS ====================
  const handleExportUsersExcel = () => {
    const xlsxLib = (XLSX as unknown as { default?: typeof XLSX }).default || XLSX;
    const sourceList = usersList.length > 0 ? usersList : currentUser ? [currentUser] : [];
    const rows = sourceList.map((u, idx) => ({
      STT: idx + 1,
      HoTen: u.name,
      Email: u.email,
      MatKhau: '',
      VaiTro: u.role,
    }));

    const worksheet = xlsxLib.utils.json_to_sheet(
      rows.length > 0
        ? rows
        : [
            {
              STT: 1,
              HoTen: 'Nguyễn Văn C',
              Email: 'member1@family.vn',
              MatKhau: '123456',
              VaiTro: 'Member',
            },
          ]
    );
    const workbook = xlsxLib.utils.book_new();
    xlsxLib.utils.book_append_sheet(workbook, worksheet, 'TaiKhoan_GiaDinh');
    xlsxLib.writeFile(workbook, `SmartHome_Accounts_${new Date().toISOString().slice(0, 10)}.xlsx`);
    appendLog('Đã xuất danh sách tài khoản gia đình ra file Excel (.xlsx).');
  };

  // Bước 1: Tải file Excel tài khoản lên -> Kiểm tra từng dòng và hiển thị danh sách hợp lệ
  const handleImportUsersExcel = async (e: React.ChangeEvent<HTMLInputElement>) => {
    const file = e.target.files?.[0];
    if (!file) return;

    let jsonRows: Record<string, unknown>[] = [];
    try {
      jsonRows = await readExcelRows(file);
    } catch (err) {
      console.error('Parse Excel error:', err);
      alert(`Lỗi đọc file Excel: ${(err as Error)?.message || 'File không hợp lệ'}`);
      if (userExcelInputRef.current) userExcelInputRef.current.value = '';
      return;
    }

    if (jsonRows.length === 0) {
      alert('File Excel trống, không có dòng dữ liệu nào.');
      if (userExcelInputRef.current) userExcelInputRef.current.value = '';
      return;
    }

    const existingEmails = new Set<string>(
      [...usersList, ...(currentUser ? [currentUser] : [])].map((u) =>
        u.email.trim().toLowerCase()
      )
    );
    const seenInFile = new Set<string>();
    const emailRegex = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

    const previewItems: ExcelUserPreviewItem[] = jsonRows.map((row, idx) => {
      const normalizedRow: Record<string, string> = {};
      Object.entries(row).forEach(([k, v]) => {
        normalizedRow[normalizeExcelKey(k)] = String(v ?? '').trim();
      });

      const name =
        normalizedRow['hoten'] ||
        normalizedRow['tenthanhvien'] ||
        normalizedRow['hovaten'] ||
        normalizedRow['name'] ||
        normalizedRow['fullname'] ||
        '';

      const email = (
        normalizedRow['email'] ||
        normalizedRow['emaildangnhap'] ||
        ''
      ).toLowerCase();

      const rawPassword =
        normalizedRow['matkhau'] ||
        normalizedRow['password'] ||
        '';

      const rawRole = (
        normalizedRow['vaitro'] ||
        normalizedRow['role'] ||
        ''
      ).toLowerCase();

      let isValid = true;
      let errorReason = '';

      if (!name) {
        isValid = false;
        errorReason = 'Thiếu họ và tên';
      } else if (!email || !emailRegex.test(email)) {
        isValid = false;
        errorReason = 'Email không hợp lệ';
      } else if (existingEmails.has(email)) {
        isValid = false;
        errorReason = 'Email đã tồn tại trong gia đình';
      } else if (seenInFile.has(email)) {
        isValid = false;
        errorReason = 'Trùng email ngay trong file Excel';
      } else if (rawRole && !['admin', 'member', 'guest'].includes(rawRole)) {
        isValid = false;
        errorReason = `Vai trò "${rawRole}" không hợp lệ (chỉ nhận Admin/Member/Guest)`;
      }

      if (email) {
        seenInFile.add(email);
      }

      const normalizedRole: 'Admin' | 'Member' | 'Guest' =
        rawRole === 'admin' ? 'Admin' : rawRole === 'guest' ? 'Guest' : 'Member';

      return {
        rowNumber: idx + 2,
        name,
        email,
        password: rawPassword || '123456',
        isDefaultPassword: !rawPassword,
        role: normalizedRole,
        isValid,
        errorReason: isValid ? undefined : errorReason,
      };
    });

    const validCount = previewItems.filter((i) => i.isValid).length;
    setExcelFileName(file.name);
    setExcelPreviewUsers(previewItems);
    appendLog(
      `Đã đọc file "${file.name}": ${validCount}/${previewItems.length} tài khoản hợp lệ.`
    );

    if (userExcelInputRef.current) userExcelInputRef.current.value = '';
  };

  const handleRemovePreviewUser = (rowNumber: number) => {
    setExcelPreviewUsers((prev) => {
      const next = prev.filter((item) => item.rowNumber !== rowNumber);
      if (next.length === 0) setExcelFileName('');
      return next;
    });
  };

  // Bước 2: Xác nhận tạo chỉ các tài khoản hợp lệ
  const handleConfirmImportValidUsers = async () => {
    const validItems = excelPreviewUsers.filter((item) => item.isValid);
    if (validItems.length === 0) return;

    setIsImportingUsers(true);
    let createdCount = 0;
    const failedMap = new Map<number, string>();

    try {
      for (const item of validItems) {
        const res = await fetch(`${API_BASE}/users`, {
          method: 'POST',
          headers: getAuthHeaders(),
          body: JSON.stringify({
            name: item.name,
            email: item.email,
            password: item.password,
            role: item.role,
          }),
        });

        if (res.ok) {
          createdCount++;
        } else {
          const errData = await res.json().catch(() => ({}));
          const rawMsg = String(errData.error || `Lỗi HTTP ${res.status}`);
          const friendlyMsg = rawMsg.includes('users_email_key')
            ? 'Email đã được đăng ký ở tài khoản khác trên hệ thống'
            : rawMsg;
          failedMap.set(item.rowNumber, friendlyMsg);
        }
      }

      appendLog(`Đã tạo thành công ${createdCount} tài khoản hợp lệ từ file Excel.`);
      await fetchAllDatabaseData();

      if (failedMap.size === 0) {
        setExcelPreviewUsers([]);
        setExcelFileName('');
      } else {
        setExcelPreviewUsers((prev) =>
          prev
            .filter((item) => !item.isValid || failedMap.has(item.rowNumber))
            .map((item) =>
              failedMap.has(item.rowNumber)
                ? {
                    ...item,
                    isValid: false,
                    errorReason: failedMap.get(item.rowNumber),
                  }
                : item
            )
        );
      }
    } finally {
      setIsImportingUsers(false);
    }
  };

  // ==================== COMPUTED METRICS ====================
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

  const filteredRooms = useMemo(() => {
    if (!selectedHouseId) return rooms;
    return rooms.filter((r) => r.house_id === selectedHouseId);
  }, [rooms, selectedHouseId]);

  const filteredDevices = useMemo(() => {
    if (selectedRoomId) {
      return devices.filter((d) => d.room_id === selectedRoomId);
    }
    if (selectedHouseId) {
      const roomIdsInHouse = new Set(
        rooms.filter((r) => r.house_id === selectedHouseId).map((r) => r.id)
      );
      return devices.filter((d) => d.room_id && roomIdsInHouse.has(d.room_id));
    }
    return devices;
  }, [devices, rooms, selectedHouseId, selectedRoomId]);

  // ==================== STYLING HELPERS ====================
  const pageBg = isDark ? 'bg-[#080d1a] text-slate-100' : 'bg-slate-100 text-slate-900';
  const sidebarBg = isDark
    ? 'bg-[#0b1121] border-slate-800/80'
    : 'bg-white border-slate-200';
  const cardBg = isDark
    ? 'bg-[#0e1629] border-slate-800/80'
    : 'bg-white border-slate-200 shadow-sm';
  const inputBg = isDark
    ? 'bg-[#131c31] border-slate-700 text-slate-100 placeholder-slate-500'
    : 'bg-slate-50 border-slate-300 text-slate-900 placeholder-slate-400';

  // ==================== AUTH SCREEN ====================
  if (!currentUser) {
    return (
      <div className="min-h-screen bg-[#080d1a] text-slate-100 flex items-center justify-center p-4">
        <div className="w-full max-w-md rounded-2xl bg-[#0e1629] border border-slate-800 p-7 shadow-2xl">
          <div className="flex items-center gap-3 mb-6">
            <div className="w-11 h-11 rounded-xl bg-cyan-500/15 border border-cyan-500/30 flex items-center justify-center text-xl">
              🏠
            </div>
            <div>
              <h1 className="text-lg font-bold text-cyan-400">SmartHome IoT</h1>
              <p className="text-xs text-slate-400">
                Hệ thống điều khiển nhà thông minh đa hộ gia đình
              </p>
            </div>
          </div>

          <div className="grid grid-cols-2 gap-1 p-1 rounded-xl bg-[#131c31] mb-5">
            <button
              type="button"
              onClick={() => {
                setAuthMode('login');
                setAuthError('');
              }}
              className={`py-2 rounded-lg text-xs font-semibold transition ${
                authMode === 'login'
                  ? 'bg-cyan-500 text-slate-950'
                  : 'text-slate-400 hover:text-slate-200'
              }`}
            >
              Đăng nhập
            </button>
            <button
              type="button"
              onClick={() => {
                setAuthMode('register');
                setAuthError('');
              }}
              className={`py-2 rounded-lg text-xs font-semibold transition ${
                authMode === 'register'
                  ? 'bg-cyan-500 text-slate-950'
                  : 'text-slate-400 hover:text-slate-200'
              }`}
            >
              Đăng ký Chủ nhà
            </button>
          </div>

          <form onSubmit={handleAuthSubmit} className="space-y-4">
            {authMode === 'register' && (
              <div>
                <label className="block text-xs font-semibold text-slate-300 mb-1.5">
                  Họ và tên Chủ nhà
                </label>
                <input
                  type="text"
                  required
                  value={authName}
                  onChange={(e) => setAuthName(e.target.value)}
                  placeholder="Ví dụ: Nguyễn Văn A"
                  className="w-full px-3.5 py-2.5 rounded-xl bg-[#131c31] border border-slate-700 text-sm focus:outline-none focus:border-cyan-500"
                />
              </div>
            )}

            <div>
              <label className="block text-xs font-semibold text-slate-300 mb-1.5">Email</label>
              <input
                type="email"
                required
                value={authEmail}
                onChange={(e) => setAuthEmail(e.target.value)}
                placeholder="owner@smarthome.vn"
                className="w-full px-3.5 py-2.5 rounded-xl bg-[#131c31] border border-slate-700 text-sm focus:outline-none focus:border-cyan-500"
              />
            </div>

            <div>
              <label className="block text-xs font-semibold text-slate-300 mb-1.5">Mật khẩu</label>
              <input
                type="password"
                required
                value={authPassword}
                onChange={(e) => setAuthPassword(e.target.value)}
                placeholder="••••••••"
                className="w-full px-3.5 py-2.5 rounded-xl bg-[#131c31] border border-slate-700 text-sm focus:outline-none focus:border-cyan-500"
              />
            </div>

            {authError && (
              <div className="p-3 rounded-xl bg-red-500/15 border border-red-500/30 text-xs text-red-400">
                {authError}
              </div>
            )}

            <button
              type="submit"
              disabled={authLoading}
              className="w-full py-2.5 rounded-xl bg-cyan-500 hover:bg-cyan-400 text-slate-950 font-bold text-sm transition disabled:opacity-50"
            >
              {authLoading
                ? 'Đang xử lý...'
                : authMode === 'login'
                ? 'Đăng nhập hệ thống'
                : 'Đăng ký tài khoản Chủ nhà'}
            </button>

            {authMode === 'register' && (
              <p className="text-[11px] text-slate-400 text-center leading-relaxed">
                Tài khoản đăng ký mới sẽ tự động là{' '}
                <strong className="text-cyan-400">Chủ nhà (Owner)</strong> với không gian quản lý
                nhà, phòng, thiết bị và thành viên độc lập.
              </p>
            )}
          </form>
        </div>
      </div>
    );
  }

  // ==================== MAIN DASHBOARD ====================
  const hasLiveSensor = sensorData !== null && devices.length > 0;

  return (
    <div className={`min-h-screen flex ${pageBg}`}>
      {/* ==================== SIDEBAR ==================== */}
      <aside className={`w-64 shrink-0 border-r flex flex-col justify-between p-4 ${sidebarBg}`}>
        <div>
          <div className="flex items-center gap-3 px-2 py-2 mb-6">
            <div className="w-9 h-9 rounded-xl bg-cyan-500/15 border border-cyan-500/30 flex items-center justify-center text-lg">
              🏠
            </div>
            <div className="min-w-0">
              <div className="font-bold text-sm text-cyan-400 truncate">SmartHome IoT</div>
              <div className="text-xs text-slate-400 truncate">{currentUser.name}</div>
            </div>
          </div>

          <div className="text-[10px] font-bold uppercase tracking-wider text-slate-500 px-3 mb-2">
            ĐIỀU KHIỂN NHÀ THÔNG MINH
          </div>

          <nav className="space-y-1 text-xs font-medium">
            <button
              onClick={() => setActiveTab('overview')}
              className={`w-full flex items-center justify-between px-3 py-2.5 rounded-xl transition ${
                activeTab === 'overview'
                  ? 'bg-cyan-500/15 text-cyan-400 border border-cyan-500/30 font-semibold'
                  : 'text-slate-400 hover:bg-slate-800/50 hover:text-slate-200'
              }`}
            >
              <span>📊 Tổng quan</span>
            </button>

            <button
              onClick={() => setActiveTab('devices')}
              className={`w-full flex items-center justify-between px-3 py-2.5 rounded-xl transition ${
                activeTab === 'devices'
                  ? 'bg-cyan-500/15 text-cyan-400 border border-cyan-500/30 font-semibold'
                  : 'text-slate-400 hover:bg-slate-800/50 hover:text-slate-200'
              }`}
            >
              <span>📱 Phòng & Thiết bị</span>
              <span className="px-1.5 py-0.5 rounded bg-cyan-500/20 text-cyan-300 text-[10px] font-mono">
                {rooms.length}P • {devices.length}
              </span>
            </button>

            <button
              onClick={() => setActiveTab('automations')}
              className={`w-full flex items-center justify-between px-3 py-2.5 rounded-xl transition ${
                activeTab === 'automations'
                  ? 'bg-cyan-500/15 text-cyan-400 border border-cyan-500/30 font-semibold'
                  : 'text-slate-400 hover:bg-slate-800/50 hover:text-slate-200'
              }`}
            >
              <span>⚡ Tự động hóa (IF-THEN)</span>
              <span className="px-1.5 py-0.5 rounded bg-amber-500/20 text-amber-300 text-[10px] font-mono">
                {automations.length}
              </span>
            </button>

            <button
              onClick={() => setActiveTab('energy')}
              className={`w-full flex items-center justify-between px-3 py-2.5 rounded-xl transition ${
                activeTab === 'energy'
                  ? 'bg-cyan-500/15 text-cyan-400 border border-cyan-500/30 font-semibold'
                  : 'text-slate-400 hover:bg-slate-800/50 hover:text-slate-200'
              }`}
            >
              <span>📈 Thống kê Năng lượng</span>
            </button>

            <button
              onClick={() => setActiveTab('ai')}
              className={`w-full flex items-center justify-between px-3 py-2.5 rounded-xl transition ${
                activeTab === 'ai'
                  ? 'bg-cyan-500/15 text-cyan-400 border border-cyan-500/30 font-semibold'
                  : 'text-slate-400 hover:bg-slate-800/50 hover:text-slate-200'
              }`}
            >
              <span>🤖 Trí tuệ Nhân tạo (AI)</span>
              <span className="px-1.5 py-0.5 rounded bg-rose-500/20 text-rose-300 text-[10px] font-mono">
                {aiAlerts.length}
              </span>
            </button>

            {isOwnerOrAdmin && (
              <button
                onClick={() => setActiveTab('accounts')}
                className={`w-full flex items-center justify-between px-3 py-2.5 rounded-xl transition ${
                  activeTab === 'accounts'
                    ? 'bg-cyan-500/15 text-cyan-400 border border-cyan-500/30 font-semibold'
                    : 'text-slate-400 hover:bg-slate-800/50 hover:text-slate-200'
                }`}
              >
                <span>👥 Quản lý Tài khoản</span>
                <span className="px-1.5 py-0.5 rounded bg-emerald-500/20 text-emerald-300 text-[10px] font-mono">
                  {usersList.length}
                </span>
              </button>
            )}
          </nav>
        </div>

        {/* User Footer */}
        <div className="p-3 rounded-xl bg-slate-900/70 border border-slate-800 flex items-center justify-between gap-2">
          <div className="min-w-0">
            <div className="text-xs font-semibold text-slate-200 truncate">{currentUser.email}</div>
            <div className="text-[11px] text-emerald-400 truncate">
              {currentUser.name} ({currentUser.role})
            </div>
          </div>
          <button
            onClick={handleLogout}
            title="Đăng xuất"
            className="p-2 rounded-lg bg-red-500/15 text-red-400 hover:bg-red-500/25 text-xs shrink-0"
          >
            🚪
          </button>
        </div>
      </aside>

      {/* ==================== MAIN CONTENT ==================== */}
      <div className="flex-1 flex flex-col min-w-0">
        {/* TOP HEADER */}
        <header
          className={`px-6 py-3 border-b flex flex-wrap items-center justify-between gap-3 ${sidebarBg}`}
        >
          <div className="px-3 py-1.5 rounded-xl bg-slate-900/70 border border-slate-800 text-xs text-slate-300">
            🗄️ PostgreSQL Sync:{' '}
            <strong className="text-white">{houses.length}</strong> nhà •{' '}
            <strong className="text-white">{rooms.length}</strong> phòng •{' '}
            <strong className="text-white">{devices.length}</strong> thiết bị
          </div>

          <div className="flex flex-wrap items-center gap-2 text-xs">
            <span
              className={`px-3 py-1 rounded-full border font-medium ${
                wsConnected
                  ? 'bg-emerald-500/10 border-emerald-500/30 text-emerald-400'
                  : 'bg-amber-500/10 border-amber-500/30 text-amber-400'
              }`}
            >
              • WebSocket: {wsConnected ? 'Connected' : 'Reconnecting'}
            </span>

            <span className="px-3 py-1 rounded-full bg-sky-500/10 border border-sky-500/30 text-sky-400 font-medium">
              • MQTT Broker: Online
            </span>

            <span className="px-3 py-1 rounded-full bg-amber-500/10 border border-amber-500/30 text-slate-300">
              Vai trò: <strong className="text-amber-400">{currentUser.role}</strong>
            </span>

            <button
              onClick={() => setIsDark(!isDark)}
              className="w-8 h-8 rounded-full bg-slate-800/80 border border-slate-700 flex items-center justify-center text-amber-300 hover:bg-slate-700"
              title="Đổi giao diện Sáng / Tối"
            >
              {isDark ? '🌙' : '☀️'}
            </button>

            <span className="px-3 py-1 rounded-full bg-slate-900/80 border border-slate-800 font-mono text-slate-300">
              {clockText}
            </span>
          </div>
        </header>

        {/* WORKSPACE BODY */}
        <main className="flex-1 p-6 overflow-y-auto space-y-6">
          {/* ==================== TAB 1: TỔNG QUAN ==================== */}
          {activeTab === 'overview' && (
            <>
              {/* 4 KPI Cards */}
              <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-4">
                <div className={`p-5 rounded-2xl border ${cardBg}`}>
                  <div className="flex items-center justify-between text-xs text-slate-400 mb-1">
                    <span>🌡️ Nhiệt độ phòng</span>
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
                    {hasLiveSensor && sensorData
                      ? `${sensorData.temperature.toFixed(1)}°C`
                      : '--°C'}
                  </div>
                  <div className="text-[11px] text-slate-500 mt-1">
                    {hasLiveSensor && sensorData
                      ? 'Cảm biến DHT22 thời gian thực'
                      : 'Chưa có dữ liệu cảm biến nhiệt độ'}
                  </div>
                </div>

                <div className={`p-5 rounded-2xl border ${cardBg}`}>
                  <div className="flex items-center justify-between text-xs text-slate-400 mb-1">
                    <span>💧 Độ ẩm không khí</span>
                    <span className="px-2 py-0.5 rounded bg-cyan-500/15 text-cyan-400 text-[10px] font-semibold">
                      {!hasLiveSensor || !sensorData
                        ? 'Chưa kết nối'
                        : sensorData.humidity > 80
                        ? 'Ẩm cao'
                        : 'Thoáng'}
                    </span>
                  </div>
                  <div className="text-2xl font-bold text-cyan-400">
                    {hasLiveSensor && sensorData
                      ? `${sensorData.humidity.toFixed(0)}%`
                      : '--%'}
                  </div>
                  <div className="text-[11px] text-slate-500 mt-1">
                    Ngưỡng khuyến nghị: 50% – 70%
                  </div>
                </div>

                <div className={`p-5 rounded-2xl border ${cardBg}`}>
                  <div className="flex items-center justify-between text-xs text-slate-400 mb-1">
                    <span>☀️ Ánh sáng / PIR</span>
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
                    <span>🔌 Thiết bị & Công suất</span>
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
                      <h2 className="font-bold text-sm">⚡ Điều khiển nhanh Thiết bị IoT</h2>
                      <p className="text-xs text-slate-400">
                        Bật/tắt trực tiếp thiết bị và theo dõi chỉ số cảm biến thời gian thực qua MQTT
                      </p>
                    </div>
                    <button
                      onClick={() => setActiveTab('devices')}
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

                            {/* Hiển thị chỉ số trực tiếp nếu là thiết bị cảm biến */}
                            {dev.device_type === 'sensor' && (
                              <div className="mt-1.5 flex flex-wrap items-center gap-1.5 text-[10px] font-mono">
                                {hasLiveSensor && sensorData ? (
                                  <>
                                    <span className="px-1.5 py-0.5 rounded bg-amber-500/15 text-amber-300">
                                      🌡️ {sensorData.temperature.toFixed(1)}°C
                                    </span>
                                    <span className="px-1.5 py-0.5 rounded bg-cyan-500/15 text-cyan-300">
                                      💧 {sensorData.humidity.toFixed(0)}%
                                    </span>
                                    <span className="px-1.5 py-0.5 rounded bg-emerald-500/15 text-emerald-300">
                                      ☀️ {sensorData.lux} Lux
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
                            onClick={() => handleToggleDevice(dev)}
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
                    <h2 className="font-bold text-sm">🏠 Không gian Nhà & Phòng</h2>
                    <span className="text-xs font-mono text-slate-400">
                      {houses.length}N • {rooms.length}P
                    </span>
                  </div>

                  {rooms.length === 0 ? (
                    <div className="p-8 text-center text-xs text-slate-500">
                      Chưa có phòng nào.
                    </div>
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
                    <h2 className="font-bold text-sm">
                      ⚙️ Kịch bản Tự động hóa ({automations.length})
                    </h2>
                    <button
                      onClick={() => setActiveTab('automations')}
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
                    <h2 className="font-bold text-sm">
                      🤖 Cảnh báo An ninh & AI ({aiAlerts.length})
                    </h2>
                    <button
                      onClick={() => setActiveTab('ai')}
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
                          <div className="font-bold text-rose-400">
                            {al.title || al.alert_type}
                          </div>
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
                  <h2 className="font-bold text-sm">📜 Nhật ký hoạt động hệ thống</h2>
                  <button
                    onClick={() => setSystemLogs([])}
                    className="text-xs text-slate-400 hover:text-slate-200"
                  >
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
          )}

          {/* ==================== TAB 2: PHÒNG & THIẾT BỊ ==================== */}
          {activeTab === 'devices' && (
            <div className="space-y-6">
              {/* Top Toolbar: Discover & Import / Export Excel (Owner/Admin only) */}
              <div className="flex flex-wrap items-center justify-between gap-3">
                <div>
                  <h1 className="text-lg font-bold">
                    Quản lý Không gian Nhà, Phòng & Thiết bị IoT
                  </h1>
                  <p className="text-xs text-slate-400">
                    Hỗ trợ nhập/xuất hàng loạt qua Excel (Sheet 1: TenNha, DiaChi, TenPhong, Tang • Sheet 2: TenThietBi, LoaiThietBi, MqttTopic, Phong)
                  </p>
                </div>

                {isOwnerOrAdmin && (
                  <div className="flex flex-wrap items-center gap-2">
                    <button
                      type="button"
                      disabled={discoveringDevices}
                      onClick={handleDiscoverDevices}
                      className="px-3.5 py-2 rounded-xl bg-amber-500/15 border border-amber-500/30 text-amber-400 hover:bg-amber-500/25 text-xs font-semibold transition disabled:opacity-50"
                    >
                      {discoveringDevices ? '⏳ Đang quét...' : '📡 Quét thiết bị'}
                    </button>
                    <input
                      ref={fileInputRef}
                      type="file"
                      accept=".xlsx,.xls,.csv"
                      onChange={handleImportExcel}
                      className="hidden"
                    />
                    <button
                      type="button"
                      onClick={() => fileInputRef.current?.click()}
                      className="px-3.5 py-2 rounded-xl bg-emerald-500/15 border border-emerald-500/30 text-emerald-400 hover:bg-emerald-500/25 text-xs font-semibold transition"
                    >
                      📥 Nhập Excel
                    </button>
                    <button
                      type="button"
                      onClick={handleExportExcel}
                      className="px-3.5 py-2 rounded-xl bg-cyan-500/15 border border-cyan-500/30 text-cyan-400 hover:bg-cyan-500/25 text-xs font-semibold transition"
                    >
                      📤 Xuất Excel
                    </button>
                  </div>
                )}
              </div>

              {/* BẢNG XEM TRƯỚC DANH SÁCH NHÀ / PHÒNG / THIẾT BỊ TỪ EXCEL HOẶC DISCOVERY */}
              {excelPreviewSpace.length > 0 &&
                (() => {
                  const validRows = excelPreviewSpace.filter((i) => i.isValid);
                  const invalidRows = excelPreviewSpace.filter((i) => !i.isValid);

                  return (
                    <div className={`p-5 rounded-2xl border border-cyan-500/40 space-y-4 ${cardBg}`}>
                      <div className="flex flex-wrap items-center justify-between gap-3">
                        <div>
                          <h2 className="text-sm font-bold text-cyan-400">
                            📋 Danh sách kiểm tra dữ liệu từ: {spaceExcelFileName}
                          </h2>
                          <div className="flex flex-wrap items-center gap-3 mt-1 text-xs">
                            <span className="text-slate-400">
                              Tổng cộng:{' '}
                              <strong className="text-slate-200">{excelPreviewSpace.length}</strong>{' '}
                              dòng
                            </span>
                            <span className="px-2 py-0.5 rounded bg-emerald-500/15 text-emerald-400 font-semibold">
                              ✓ Hợp lệ: {validRows.length}
                            </span>
                            {invalidRows.length > 0 && (
                              <span className="px-2 py-0.5 rounded bg-rose-500/15 text-rose-400 font-semibold">
                                ✕ Không hợp lệ / Đã tồn tại: {invalidRows.length}
                              </span>
                            )}
                          </div>
                        </div>

                        <div className="flex items-center gap-2">
                          <button
                            type="button"
                            disabled={isImportingSpace}
                            onClick={() => {
                              setExcelPreviewSpace([]);
                              setSpaceExcelFileName('');
                            }}
                            className="px-3.5 py-2 rounded-xl bg-slate-800 hover:bg-slate-700 text-slate-300 text-xs font-semibold transition disabled:opacity-50"
                          >
                            ✕ Hủy bỏ
                          </button>
                          <button
                            type="button"
                            disabled={validRows.length === 0 || isImportingSpace}
                            onClick={handleConfirmImportSpaceItems}
                            className="px-4 py-2 rounded-xl bg-emerald-500 hover:bg-emerald-400 text-slate-950 text-xs font-bold transition disabled:opacity-40"
                          >
                            {isImportingSpace
                              ? 'Đang tạo dữ liệu...'
                              : `✓ Xác nhận tạo ${validRows.length} mục hợp lệ`}
                          </button>
                        </div>
                      </div>

                      <div className="rounded-xl border border-slate-800 overflow-x-auto max-h-72 overflow-y-auto">
                        <table className="w-full text-left text-xs">
                          <thead className="bg-slate-900/90 text-slate-400 uppercase text-[11px] sticky top-0">
                            <tr>
                              <th className="p-2.5">Nguồn / Dòng</th>
                              <th className="p-2.5">Phân loại</th>
                              <th className="p-2.5">Tên mục</th>
                              <th className="p-2.5">Chi tiết (Nhà / Phòng / Topic)</th>
                              <th className="p-2.5">Trạng thái kiểm tra</th>
                              <th className="p-2.5 text-right">Bỏ</th>
                            </tr>
                          </thead>
                          <tbody className="divide-y divide-slate-800/70">
                            {excelPreviewSpace.map((item) => (
                              <tr
                                key={item.id}
                                className={
                                  item.isValid ? 'bg-emerald-500/5' : 'bg-rose-500/5 opacity-80'
                                }
                              >
                                <td className="p-2.5 font-mono text-slate-400">
                                  {item.sheetName} #{item.rowNumber}
                                </td>
                                <td className="p-2.5">
                                  {item.kind === 'house' && (
                                    <span className="px-2 py-0.5 rounded bg-cyan-500/15 text-cyan-400 font-semibold">
                                      🏠 Ngôi nhà
                                    </span>
                                  )}
                                  {item.kind === 'room' && (
                                    <span className="px-2 py-0.5 rounded bg-amber-500/15 text-amber-400 font-semibold">
                                      🚪 Phòng
                                    </span>
                                  )}
                                  {item.kind === 'device' && (
                                    <span className="px-2 py-0.5 rounded bg-emerald-500/15 text-emerald-400 font-semibold">
                                      🔌 Thiết bị
                                    </span>
                                  )}
                                </td>
                                <td className="p-2.5 font-bold">
                                  {item.name || (
                                    <span className="text-rose-400 italic">(Trống)</span>
                                  )}
                                </td>
                                <td className="p-2.5 text-slate-300 font-mono text-[11px]">
                                  {item.kind === 'house' && (item.address || 'Không có địa chỉ')}
                                  {item.kind === 'room' &&
                                    `Nhà: ${item.houseName} • Tầng ${item.floor || 1}`}
                                  {item.kind === 'device' &&
                                    `${item.mqttTopic || 'Thiếu topic'} • ${
                                      item.roomName ? `Phòng: ${item.roomName}` : 'Chưa phân phòng'
                                    } (${item.deviceType})`}
                                </td>
                                <td className="p-2.5">
                                  {item.isValid ? (
                                    <span className="text-emerald-400 font-semibold">
                                      ✓ Hợp lệ (Sẵn sàng tạo)
                                    </span>
                                  ) : (
                                    <span className="text-rose-400 font-medium">
                                      ✕ {item.errorReason}
                                    </span>
                                  )}
                                </td>
                                <td className="p-2.5 text-right">
                                  <button
                                    type="button"
                                    onClick={() => handleRemovePreviewSpaceItem(item.id)}
                                    className="px-2 py-0.5 rounded hover:bg-slate-800 text-slate-400 hover:text-slate-200"
                                    title="Loại khỏi danh sách nhập"
                                  >
                                    ✕
                                  </button>
                                </td>
                              </tr>
                            ))}
                          </tbody>
                        </table>
                      </div>
                    </div>
                  );
                })()}

              {/* Forms Create House / Room / Device (Owner/Admin only) */}
              {isOwnerOrAdmin && (
                <div className="grid grid-cols-1 lg:grid-cols-3 gap-4">
                  {/* Add House */}
                  <form
                    onSubmit={handleCreateHouse}
                    className={`p-4 rounded-2xl border space-y-3 ${cardBg}`}
                  >
                    <h3 className="font-bold text-xs text-cyan-400 uppercase">+ Thêm Ngôi nhà</h3>
                    <input
                      type="text"
                      required
                      value={newHouseName}
                      onChange={(e) => setNewHouseName(e.target.value)}
                      placeholder="Tên nhà (VD: Nhà Quận 7)"
                      className={`w-full px-3 py-2 rounded-xl border text-xs ${inputBg}`}
                    />
                    <input
                      type="text"
                      value={newHouseAddress}
                      onChange={(e) => setNewHouseAddress(e.target.value)}
                      placeholder="Địa chỉ (Tùy chọn)"
                      className={`w-full px-3 py-2 rounded-xl border text-xs ${inputBg}`}
                    />
                    <button
                      type="submit"
                      className="w-full py-2 rounded-xl bg-cyan-500 hover:bg-cyan-400 text-slate-950 font-bold text-xs"
                    >
                      Tạo Ngôi nhà
                    </button>
                  </form>

                  {/* Add Room */}
                  <form
                    onSubmit={handleCreateRoom}
                    className={`p-4 rounded-2xl border space-y-3 ${cardBg}`}
                  >
                    <h3 className="font-bold text-xs text-amber-400 uppercase">+ Thêm Phòng</h3>
                    <select
                      value={newRoomHouseId || houses[0]?.id || ''}
                      onChange={(e) => setNewRoomHouseId(e.target.value)}
                      className={`w-full px-3 py-2 rounded-xl border text-xs ${inputBg}`}
                    >
                      <option value="">-- Chọn ngôi nhà --</option>
                      {houses.map((h) => (
                        <option key={h.id} value={h.id}>
                          {h.name}
                        </option>
                      ))}
                    </select>
                    <div className="grid grid-cols-3 gap-2">
                      <input
                        type="text"
                        required
                        value={newRoomName}
                        onChange={(e) => setNewRoomName(e.target.value)}
                        placeholder="Tên phòng (VD: Phòng khách)"
                        className={`col-span-2 px-3 py-2 rounded-xl border text-xs ${inputBg}`}
                      />
                      <input
                        type="number"
                        value={newRoomFloor}
                        onChange={(e) => setNewRoomFloor(Number(e.target.value))}
                        placeholder="Tầng"
                        className={`px-3 py-2 rounded-xl border text-xs ${inputBg}`}
                      />
                    </div>
                    <button
                      type="submit"
                      className="w-full py-2 rounded-xl bg-amber-500 hover:bg-amber-400 text-slate-950 font-bold text-xs"
                    >
                      Tạo Phòng
                    </button>
                  </form>

                  {/* Add Device */}
                  <form
                    onSubmit={handleCreateDevice}
                    className={`p-4 rounded-2xl border space-y-3 ${cardBg}`}
                  >
                    <h3 className="font-bold text-xs text-emerald-400 uppercase">
                      + Thêm Thiết bị IoT
                    </h3>
                    <div className="grid grid-cols-2 gap-2">
                      <input
                        type="text"
                        required
                        value={newDeviceName}
                        onChange={(e) => setNewDeviceName(e.target.value)}
                        placeholder="Tên thiết bị"
                        className={`px-3 py-2 rounded-xl border text-xs ${inputBg}`}
                      />
                      <select
                        value={newDeviceType}
                        onChange={(e) => setNewDeviceType(e.target.value)}
                        className={`px-3 py-2 rounded-xl border text-xs ${inputBg}`}
                      >
                        <option value="light">Đèn (light)</option>
                        <option value="fan">Quạt (fan)</option>
                        <option value="ac">Điều hòa (ac)</option>
                        <option value="switch">Công tắc (switch)</option>
                        <option value="sensor">Cảm biến (sensor)</option>
                      </select>
                    </div>
                    <div className="grid grid-cols-2 gap-2">
                      <input
                        type="text"
                        required
                        value={newDeviceTopic}
                        onChange={(e) => setNewDeviceTopic(e.target.value)}
                        placeholder="MQTT Topic (home/r1/led)"
                        className={`px-3 py-2 rounded-xl border text-xs ${inputBg}`}
                      />
                      <select
                        value={newDeviceRoomId}
                        onChange={(e) => setNewDeviceRoomId(e.target.value)}
                        className={`px-3 py-2 rounded-xl border text-xs ${inputBg}`}
                      >
                        <option value="">Chưa phân phòng</option>
                        {rooms.map((r) => (
                          <option key={r.id} value={r.id}>
                            {r.name} ({r.house_name || 'Nhà'})
                          </option>
                        ))}
                      </select>
                    </div>
                    <button
                      type="submit"
                      className="w-full py-2 rounded-xl bg-emerald-500 hover:bg-emerald-400 text-slate-950 font-bold text-xs"
                    >
                      Kết nối Thiết bị
                    </button>
                  </form>
                </div>
              )}

              {/* Inline Edit Forms if editing House / Room */}
              {editingHouse && (
                <form
                  onSubmit={handleUpdateHouse}
                  className={`p-4 rounded-2xl border border-cyan-500/40 flex flex-wrap items-center gap-3 ${cardBg}`}
                >
                  <span className="text-xs font-bold text-cyan-400">✏️ Sửa Ngôi nhà:</span>
                  <input
                    type="text"
                    required
                    value={editingHouse.name}
                    onChange={(e) => setEditingHouse({ ...editingHouse, name: e.target.value })}
                    className={`px-3 py-1.5 rounded-xl border text-xs ${inputBg}`}
                  />
                  <input
                    type="text"
                    value={editingHouse.address || ''}
                    onChange={(e) => setEditingHouse({ ...editingHouse, address: e.target.value })}
                    placeholder="Địa chỉ"
                    className={`px-3 py-1.5 rounded-xl border text-xs ${inputBg}`}
                  />
                  <button
                    type="submit"
                    className="px-3 py-1.5 rounded-xl bg-cyan-500 text-slate-950 font-bold text-xs"
                  >
                    Lưu
                  </button>
                  <button
                    type="button"
                    onClick={() => setEditingHouse(null)}
                    className="px-3 py-1.5 rounded-xl bg-slate-800 text-slate-300 text-xs"
                  >
                    Hủy
                  </button>
                </form>
              )}

              {editingRoom && (
                <form
                  onSubmit={handleUpdateRoom}
                  className={`p-4 rounded-2xl border border-amber-500/40 flex flex-wrap items-center gap-3 ${cardBg}`}
                >
                  <span className="text-xs font-bold text-amber-400">✏️ Sửa Phòng:</span>
                  <select
                    value={editingRoom.house_id}
                    onChange={(e) => setEditingRoom({ ...editingRoom, house_id: e.target.value })}
                    className={`px-3 py-1.5 rounded-xl border text-xs ${inputBg}`}
                  >
                    {houses.map((h) => (
                      <option key={h.id} value={h.id}>
                        {h.name}
                      </option>
                    ))}
                  </select>
                  <input
                    type="text"
                    required
                    value={editingRoom.name}
                    onChange={(e) => setEditingRoom({ ...editingRoom, name: e.target.value })}
                    className={`px-3 py-1.5 rounded-xl border text-xs ${inputBg}`}
                  />
                  <input
                    type="number"
                    value={editingRoom.floor}
                    onChange={(e) =>
                      setEditingRoom({ ...editingRoom, floor: Number(e.target.value) })
                    }
                    className={`w-20 px-3 py-1.5 rounded-xl border text-xs ${inputBg}`}
                  />
                  <button
                    type="submit"
                    className="px-3 py-1.5 rounded-xl bg-amber-500 text-slate-950 font-bold text-xs"
                  >
                    Lưu
                  </button>
                  <button
                    type="button"
                    onClick={() => setEditingRoom(null)}
                    className="px-3 py-1.5 rounded-xl bg-slate-800 text-slate-300 text-xs"
                  >
                    Hủy
                  </button>
                </form>
              )}

              {/* Houses Filter Bar */}
              <div className={`p-4 rounded-2xl border ${cardBg}`}>
                <div className="text-xs font-bold text-slate-400 mb-2">DANH SÁCH NGÔI NHÀ</div>
                <div className="flex flex-wrap gap-2">
                  <button
                    onClick={() => {
                      setSelectedHouseId(null);
                      setSelectedRoomId(null);
                    }}
                    className={`px-3 py-1.5 rounded-xl text-xs font-semibold border ${
                      selectedHouseId === null
                        ? 'bg-cyan-500/20 border-cyan-500/40 text-cyan-300'
                        : 'border-slate-700 text-slate-400'
                    }`}
                  >
                    Tất cả nhà ({houses.length})
                  </button>
                  {houses.map((h) => (
                    <div
                      key={h.id}
                      className={`inline-flex items-center gap-2 px-3 py-1.5 rounded-xl text-xs border ${
                        selectedHouseId === h.id
                          ? 'bg-cyan-500/20 border-cyan-500/40 text-cyan-300'
                          : 'border-slate-700 text-slate-300'
                      }`}
                    >
                      <button
                        onClick={() => {
                          setSelectedHouseId(h.id);
                          setSelectedRoomId(null);
                        }}
                        className="font-semibold"
                      >
                        🏠 {h.name}
                      </button>
                      {isOwnerOrAdmin && (
                        <>
                          <button
                            onClick={() => setEditingHouse(h)}
                            className="text-sky-400 hover:text-sky-300 text-[11px]"
                            title="Sửa nhà"
                          >
                            ✎
                          </button>
                          <button
                            onClick={() => handleDeleteHouse(h)}
                            className="text-rose-400 hover:text-rose-300 text-[11px]"
                            title="Xóa nhà"
                          >
                            ✕
                          </button>
                        </>
                      )}
                    </div>
                  ))}
                </div>
              </div>

              {/* Rooms Filter Bar */}
              <div className={`p-4 rounded-2xl border ${cardBg}`}>
                <div className="text-xs font-bold text-slate-400 mb-2">DANH SÁCH PHÒNG</div>
                <div className="flex flex-wrap gap-2">
                  <button
                    onClick={() => setSelectedRoomId(null)}
                    className={`px-3 py-1.5 rounded-xl text-xs font-semibold border ${
                      selectedRoomId === null
                        ? 'bg-amber-500/20 border-amber-500/40 text-amber-300'
                        : 'border-slate-700 text-slate-400'
                    }`}
                  >
                    Tất cả phòng ({filteredRooms.length})
                  </button>
                  {filteredRooms.map((r) => (
                    <div
                      key={r.id}
                      className={`inline-flex items-center gap-2 px-3 py-1.5 rounded-xl text-xs border ${
                        selectedRoomId === r.id
                          ? 'bg-amber-500/20 border-amber-500/40 text-amber-300'
                          : 'border-slate-700 text-slate-300'
                      }`}
                    >
                      <button onClick={() => setSelectedRoomId(r.id)} className="font-semibold">
                        🚪 {r.name} (T{r.floor})
                      </button>
                      {isOwnerOrAdmin && (
                        <>
                          <button
                            onClick={() => setEditingRoom(r)}
                            className="text-sky-400 hover:text-sky-300 text-[11px]"
                            title="Sửa phòng"
                          >
                            ✎
                          </button>
                          <button
                            onClick={() => handleDeleteRoom(r)}
                            className="text-rose-400 hover:text-rose-300 text-[11px]"
                            title="Xóa phòng"
                          >
                            ✕
                          </button>
                        </>
                      )}
                    </div>
                  ))}
                </div>
              </div>

              {/* Devices Grid (Tích hợp chỉnh sửa trực tiếp ngay trên thẻ thiết bị) */}
              <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
                {filteredDevices.length === 0 ? (
                  <div
                    className={`col-span-full p-10 rounded-2xl border text-center text-xs text-slate-500 ${cardBg}`}
                  >
                    Chưa có thiết bị nào trong khu vực này.
                  </div>
                ) : (
                  filteredDevices.map((dev) => {
                    const isEditingThis = editingDevice?.id === dev.id;

                    if (isEditingThis && editingDevice) {
                      return (
                        <form
                          key={dev.id}
                          onSubmit={handleUpdateDevice}
                          className={`p-4 rounded-2xl border border-cyan-500/50 flex flex-col justify-between gap-3 shadow-lg ${cardBg}`}
                        >
                          <div className="flex items-center justify-between">
                            <span className="text-xs font-bold text-cyan-400">
                              ✏️ Chỉnh sửa thiết bị
                            </span>
                            <button
                              type="button"
                              onClick={() => setEditingDevice(null)}
                              className="text-xs text-slate-400 hover:text-slate-200 px-1.5 py-0.5 rounded hover:bg-slate-800"
                            >
                              ✕
                            </button>
                          </div>

                          <div className="space-y-2.5">
                            <div>
                              <label className="block text-[11px] text-slate-400 mb-1">
                                Tên thiết bị
                              </label>
                              <input
                                type="text"
                                required
                                value={editingDevice.name}
                                onChange={(e) =>
                                  setEditingDevice({ ...editingDevice, name: e.target.value })
                                }
                                placeholder="Tên thiết bị"
                                className={`w-full px-3 py-1.5 rounded-xl border text-xs ${inputBg}`}
                              />
                            </div>

                            <div className="grid grid-cols-2 gap-2">
                              <div>
                                <label className="block text-[11px] text-slate-400 mb-1">
                                  Loại thiết bị
                                </label>
                                <select
                                  value={editingDevice.device_type}
                                  onChange={(e) =>
                                    setEditingDevice({
                                      ...editingDevice,
                                      device_type: e.target.value,
                                    })
                                  }
                                  className={`w-full px-2.5 py-1.5 rounded-xl border text-xs ${inputBg}`}
                                >
                                  <option value="light">Đèn (light)</option>
                                  <option value="fan">Quạt (fan)</option>
                                  <option value="ac">Điều hòa (ac)</option>
                                  <option value="switch">Công tắc (switch)</option>
                                  <option value="sensor">Cảm biến (sensor)</option>
                                </select>
                              </div>

                              <div>
                                <label className="block text-[11px] text-slate-400 mb-1">
                                  Phòng
                                </label>
                                <select
                                  value={editingDevice.room_id || ''}
                                  onChange={(e) =>
                                    setEditingDevice({
                                      ...editingDevice,
                                      room_id: e.target.value || null,
                                    })
                                  }
                                  className={`w-full px-2.5 py-1.5 rounded-xl border text-xs ${inputBg}`}
                                >
                                  <option value="">Chưa phân phòng</option>
                                  {rooms.map((r) => (
                                    <option key={r.id} value={r.id}>
                                      {r.name} ({r.house_name || 'Nhà'})
                                    </option>
                                  ))}
                                </select>
                              </div>
                            </div>

                            <div>
                              <label className="block text-[11px] text-slate-400 mb-1">
                                MQTT Topic
                              </label>
                              <input
                                type="text"
                                required
                                value={editingDevice.mqtt_topic}
                                onChange={(e) =>
                                  setEditingDevice({
                                    ...editingDevice,
                                    mqtt_topic: e.target.value,
                                  })
                                }
                                placeholder="smarthome/devices/..."
                                className={`w-full px-3 py-1.5 rounded-xl border text-xs font-mono ${inputBg}`}
                              />
                            </div>
                          </div>

                          <div className="grid grid-cols-2 gap-2 pt-1">
                            <button
                              type="submit"
                              className="py-2 rounded-xl bg-emerald-500 hover:bg-emerald-400 text-slate-950 font-bold text-xs transition"
                            >
                              ✓ Lưu thay đổi
                            </button>
                            <button
                              type="button"
                              onClick={() => setEditingDevice(null)}
                              className="py-2 rounded-xl bg-slate-800 hover:bg-slate-700 text-slate-300 font-semibold text-xs transition"
                            >
                              Hủy
                            </button>
                          </div>
                        </form>
                      );
                    }

                    return (
                      <div
                        key={dev.id}
                        className={`p-4 rounded-2xl border flex flex-col justify-between gap-4 ${cardBg}`}
                      >
                        <div className="flex items-start justify-between gap-2">
                          <div className="min-w-0">
                            <div className="font-bold text-sm truncate">{dev.name}</div>
                            <div className="text-xs text-slate-400 mt-0.5">
                              {dev.room_name || 'Chưa phân phòng'} •{' '}
                              <span className="uppercase text-cyan-400">{dev.device_type}</span>
                            </div>
                            <div className="text-[11px] font-mono text-slate-500 mt-1 truncate">
                              {dev.mqtt_topic}
                            </div>

                            {/* Hiển thị chỉ số cảm biến thời gian thực nếu là thiết bị sensor */}
                            {dev.device_type === 'sensor' && (
                              <div className="mt-2 flex flex-wrap items-center gap-1.5 text-[11px] font-mono">
                                {hasLiveSensor && sensorData ? (
                                  <>
                                    <span className="px-2 py-0.5 rounded bg-amber-500/15 text-amber-300">
                                      🌡️ {sensorData.temperature.toFixed(1)}°C
                                    </span>
                                    <span className="px-2 py-0.5 rounded bg-cyan-500/15 text-cyan-300">
                                      💧 {sensorData.humidity.toFixed(0)}%
                                    </span>
                                    <span className="px-2 py-0.5 rounded bg-emerald-500/15 text-emerald-300">
                                      ☀️ {sensorData.lux} Lux
                                    </span>
                                    <span
                                      className={`px-2 py-0.5 rounded ${
                                        sensorData.motion
                                          ? 'bg-rose-500/20 text-rose-300'
                                          : 'bg-slate-800 text-slate-400'
                                      }`}
                                    >
                                      {sensorData.motion ? '🏃 Có người' : '😴 Yên tĩnh'}
                                    </span>
                                  </>
                                ) : (
                                  <span className="px-2 py-0.5 rounded bg-slate-800 text-slate-400">
                                    ⏳ Đang chờ gói tin MQTT...
                                  </span>
                                )}
                              </div>
                            )}
                          </div>

                          {isOwnerOrAdmin && (
                            <div className="flex items-center gap-1.5 shrink-0">
                              <button
                                onClick={() => setEditingDevice({ ...dev })}
                                className="px-2 py-1 rounded bg-sky-500/15 text-sky-400 hover:bg-sky-500/25 text-xs"
                              >
                                Sửa
                              </button>
                              <button
                                onClick={() => handleDeleteDevice(dev)}
                                className="px-2 py-1 rounded bg-rose-500/15 text-rose-400 hover:bg-rose-500/25 text-xs"
                              >
                                Xóa
                              </button>
                            </div>
                          )}
                        </div>

                        <button
                          onClick={() => handleToggleDevice(dev)}
                          className={`w-full py-2 rounded-xl font-bold text-xs transition ${
                            dev.is_on
                              ? 'bg-emerald-500 text-slate-950'
                              : 'bg-slate-800 text-slate-300 hover:bg-slate-700'
                          }`}
                        >
                          {dev.is_on ? '● ĐANG BẬT (Nhấn để TẮT)' : '○ ĐANG TẮT (Nhấn để BẬT)'}
                        </button>
                      </div>
                    );
                  })
                )}
              </div>
            </div>
          )}

          {/* ==================== TAB 3: TỰ ĐỘNG HÓA ==================== */}
          {activeTab === 'automations' && (
            <div className="space-y-6">
              {isOwnerOrAdmin && (
                <form
                  onSubmit={handleCreateAutomation}
                  className={`p-5 rounded-2xl border grid grid-cols-1 md:grid-cols-4 gap-3 items-end ${cardBg}`}
                >
                  <div>
                    <label className="block text-xs text-slate-400 mb-1">Tên kịch bản</label>
                    <input
                      type="text"
                      required
                      value={newAutoName}
                      onChange={(e) => setNewAutoName(e.target.value)}
                      placeholder="VD: Tự động làm mát"
                      className={`w-full px-3 py-2 rounded-xl border text-xs ${inputBg}`}
                    />
                  </div>
                  <div>
                    <label className="block text-xs text-slate-400 mb-1">Điều kiện (IF)</label>
                    <input
                      type="text"
                      required
                      value={newAutoCondition}
                      onChange={(e) => setNewAutoCondition(e.target.value)}
                      placeholder="VD: temperature > 30"
                      className={`w-full px-3 py-2 rounded-xl border text-xs ${inputBg}`}
                    />
                  </div>
                  <div>
                    <label className="block text-xs text-slate-400 mb-1">Hành động (THEN)</label>
                    <input
                      type="text"
                      required
                      value={newAutoAction}
                      onChange={(e) => setNewAutoAction(e.target.value)}
                      placeholder="VD: Bật quạt phòng khách"
                      className={`w-full px-3 py-2 rounded-xl border text-xs ${inputBg}`}
                    />
                  </div>
                  <button
                    type="submit"
                    className="py-2 px-4 rounded-xl bg-cyan-500 hover:bg-cyan-400 text-slate-950 font-bold text-xs"
                  >
                    + Thêm Kịch bản
                  </button>
                </form>
              )}

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
                          IF <span className="text-amber-400 font-mono">{rule.condition_text}</span>{' '}
                          → THEN <span className="text-cyan-400">{rule.action_text}</span>
                        </div>
                      </div>
                      <div className="flex items-center gap-2 shrink-0">
                        <button
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
            </div>
          )}

        {/* ==================== TAB 4: THỐNG KÊ NĂNG LƯỢNG ==================== */}
          {activeTab === 'energy' && (
            <EnergyAnalyticsPanel
              energyData={energyData}
              devices={devices}
              rooms={rooms}
              isDark={isDark}
              period={energyPeriod}
              onPeriodChange={(p: EnergyPeriod) => {
                setEnergyPeriod(p);
                fetchAllDatabaseData(p);
              }}
            />
          )}

          {/* ==================== TAB 5: TRÍ TUỆ NHÂN TẠO (AI) ==================== */}
          {activeTab === 'ai' && (
            <div className="space-y-4">
              <div className="flex items-center justify-between">
                <div>
                  <h1 className="text-lg font-bold">
                    🤖 Trung tâm Giám sát An ninh & Bất thường AI
                  </h1>
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
                <div
                  className={`p-10 rounded-2xl border text-center text-xs text-emerald-400 ${cardBg}`}
                >
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
                        <div className="text-xs font-bold text-rose-400">
                          {al.title || al.alert_type}
                        </div>
                        <div className="text-sm text-slate-200 mt-0.5">{al.message}</div>
                      </div>
                      <div className="text-xs font-mono text-slate-400 shrink-0">
                        {al.created_at}
                      </div>
                    </div>
                  ))}
                </div>
              )}
            </div>
          )}

          {/* ==================== TAB 6: QUẢN LÝ TÀI KHOẢN (OWNER / ADMIN) ==================== */}
          {activeTab === 'accounts' && isOwnerOrAdmin && (
            <div className="space-y-6">
              <div className="flex flex-wrap items-center justify-between gap-3">
                <div>
                  <h1 className="text-lg font-bold">
                    👥 Quản lý Tài khoản Thành viên trong Gia đình
                  </h1>
                  <p className="text-xs text-slate-400">
                    Cấp tài khoản phụ (Admin / Member / Guest) • Hỗ trợ nhập/xuất hàng loạt qua Excel (cột: HoTen, Email, MatKhau, VaiTro)
                  </p>
                </div>

                <div className="flex items-center gap-2">
                  <input
                    ref={userExcelInputRef}
                    type="file"
                    accept=".xlsx,.xls,.csv"
                    onChange={handleImportUsersExcel}
                    className="hidden"
                  />
                  <button
                    type="button"
                    onClick={() => userExcelInputRef.current?.click()}
                    className="px-3.5 py-2 rounded-xl bg-emerald-500/15 border border-emerald-500/30 text-emerald-400 hover:bg-emerald-500/25 text-xs font-semibold transition"
                  >
                    📥 Nhập Excel
                  </button>
                  <button
                    type="button"
                    onClick={handleExportUsersExcel}
                    className="px-3.5 py-2 rounded-xl bg-cyan-500/15 border border-cyan-500/30 text-cyan-400 hover:bg-cyan-500/25 text-xs font-semibold transition"
                  >
                    📤 Xuất Excel
                  </button>
                </div>
              </div>

              {/* BẢNG XEM TRƯỚC DANH SÁCH TÀI KHOẢN TỪ EXCEL */}
              {excelPreviewUsers.length > 0 && (() => {
                const validRows = excelPreviewUsers.filter((u) => u.isValid);
                const invalidRows = excelPreviewUsers.filter((u) => !u.isValid);

                return (
                  <div className={`p-5 rounded-2xl border border-cyan-500/40 space-y-4 ${cardBg}`}>
                    <div className="flex flex-wrap items-center justify-between gap-3">
                      <div>
                        <h2 className="text-sm font-bold text-cyan-400">
                          📋 Danh sách kiểm tra dữ liệu từ file: {excelFileName}
                        </h2>
                        <div className="flex flex-wrap items-center gap-3 mt-1 text-xs">
                          <span className="text-slate-400">
                            Tổng cộng:{' '}
                            <strong className="text-slate-200">{excelPreviewUsers.length}</strong> dòng
                          </span>
                          <span className="px-2 py-0.5 rounded bg-emerald-500/15 text-emerald-400 font-semibold">
                            ✓ Hợp lệ: {validRows.length}
                          </span>
                          {invalidRows.length > 0 && (
                            <span className="px-2 py-0.5 rounded bg-rose-500/15 text-rose-400 font-semibold">
                              ✕ Không hợp lệ / Bị trùng: {invalidRows.length}
                            </span>
                          )}
                        </div>
                      </div>

                      <div className="flex items-center gap-2">
                        <button
                          type="button"
                          disabled={isImportingUsers}
                          onClick={() => {
                            setExcelPreviewUsers([]);
                            setExcelFileName('');
                          }}
                          className="px-3.5 py-2 rounded-xl bg-slate-800 hover:bg-slate-700 text-slate-300 text-xs font-semibold transition disabled:opacity-50"
                        >
                          ✕ Hủy bỏ
                        </button>
                        <button
                          type="button"
                          disabled={validRows.length === 0 || isImportingUsers}
                          onClick={handleConfirmImportValidUsers}
                          className="px-4 py-2 rounded-xl bg-emerald-500 hover:bg-emerald-400 text-slate-950 text-xs font-bold transition disabled:opacity-40"
                        >
                          {isImportingUsers
                            ? 'Đang tạo tài khoản...'
                            : `✓ Xác nhận tạo ${validRows.length} tài khoản hợp lệ`}
                        </button>
                      </div>
                    </div>

                    <div className="rounded-xl border border-slate-800 overflow-x-auto max-h-72 overflow-y-auto">
                      <table className="w-full text-left text-xs">
                        <thead className="bg-slate-900/90 text-slate-400 uppercase text-[11px] sticky top-0">
                          <tr>
                            <th className="p-2.5">Dòng</th>
                            <th className="p-2.5">Họ và tên</th>
                            <th className="p-2.5">Email</th>
                            <th className="p-2.5">Mật khẩu</th>
                            <th className="p-2.5">Vai trò</th>
                            <th className="p-2.5">Trạng thái kiểm tra</th>
                            <th className="p-2.5 text-right">Bỏ</th>
                          </tr>
                        </thead>
                        <tbody className="divide-y divide-slate-800/70">
                          {excelPreviewUsers.map((item) => (
                            <tr
                              key={item.rowNumber}
                              className={
                                item.isValid ? 'bg-emerald-500/5' : 'bg-rose-500/5 opacity-80'
                              }
                            >
                              <td className="p-2.5 font-mono text-slate-500">#{item.rowNumber}</td>
                              <td className="p-2.5 font-semibold">
                                {item.name || <span className="text-rose-400 italic">(Trống)</span>}
                              </td>
                              <td className="p-2.5 font-mono text-slate-300">
                                {item.email || <span className="text-rose-400 italic">(Trống)</span>}
                              </td>
                              <td className="p-2.5 font-mono text-slate-400">
                                {item.isDefaultPassword ? '123456 (mặc định)' : '••••••'}
                              </td>
                              <td className="p-2.5">
                                <span className="px-2 py-0.5 rounded bg-cyan-500/15 text-cyan-400 font-semibold">
                                  {item.role}
                                </span>
                              </td>
                              <td className="p-2.5">
                                {item.isValid ? (
                                  <span className="text-emerald-400 font-semibold">
                                    ✓ Hợp lệ (Sẵn sàng tạo)
                                  </span>
                                ) : (
                                  <span className="text-rose-400 font-medium">
                                    ✕ {item.errorReason}
                                  </span>
                                )}
                              </td>
                              <td className="p-2.5 text-right">
                                <button
                                  type="button"
                                  onClick={() => handleRemovePreviewUser(item.rowNumber)}
                                  className="px-2 py-0.5 rounded hover:bg-slate-800 text-slate-400 hover:text-slate-200"
                                  title="Loại khỏi danh sách nhập"
                                >
                                  ✕
                                </button>
                              </td>
                            </tr>
                          ))}
                        </tbody>
                      </table>
                    </div>
                  </div>
                );
              })()}

              {/* Form tạo 1 tài khoản thủ công */}
              <form
                onSubmit={handleCreateSubUser}
                className={`p-5 rounded-2xl border grid grid-cols-1 md:grid-cols-5 gap-3 items-end ${cardBg}`}
              >
                <div>
                  <label className="block text-xs text-slate-400 mb-1">Họ và tên</label>
                  <input
                    type="text"
                    required
                    value={newUserName}
                    onChange={(e) => setNewUserName(e.target.value)}
                    placeholder="Nguyễn Văn C"
                    className={`w-full px-3 py-2 rounded-xl border text-xs ${inputBg}`}
                  />
                </div>
                <div>
                  <label className="block text-xs text-slate-400 mb-1">Email đăng nhập</label>
                  <input
                    type="email"
                    required
                    value={newUserEmail}
                    onChange={(e) => setNewUserEmail(e.target.value)}
                    placeholder="member@family.vn"
                    className={`w-full px-3 py-2 rounded-xl border text-xs ${inputBg}`}
                  />
                </div>
                <div>
                  <label className="block text-xs text-slate-400 mb-1">Mật khẩu</label>
                  <input
                    type="password"
                    required
                    value={newUserPassword}
                    onChange={(e) => setNewUserPassword(e.target.value)}
                    placeholder="••••••"
                    className={`w-full px-3 py-2 rounded-xl border text-xs ${inputBg}`}
                  />
                </div>
                <div>
                  <label className="block text-xs text-slate-400 mb-1">Vai trò</label>
                  <select
                    value={newUserRole}
                    onChange={(e) => setNewUserRole(e.target.value)}
                    className={`w-full px-3 py-2 rounded-xl border text-xs ${inputBg}`}
                  >
                    <option value="Member">Member (Thành viên)</option>
                    <option value="Admin">Admin (Quản trị phụ)</option>
                    <option value="Guest">Guest (Khách)</option>
                  </select>
                </div>
                <button
                  type="submit"
                  className="py-2 px-4 rounded-xl bg-cyan-500 hover:bg-cyan-400 text-slate-950 font-bold text-xs"
                >
                  + Tạo Tài khoản
                </button>
              </form>

              {/* Inline Edit User Form */}
              {editingUser && (
                <form
                  onSubmit={handleUpdateUser}
                  className={`p-4 rounded-2xl border border-cyan-500/40 flex flex-wrap items-center gap-3 ${cardBg}`}
                >
                  <span className="text-xs font-bold text-cyan-400">
                    ✏️ Sửa thành viên ({editingUser.email}):
                  </span>
                  <input
                    type="text"
                    required
                    value={editingUser.name}
                    onChange={(e) => setEditingUser({ ...editingUser, name: e.target.value })}
                    className={`px-3 py-1.5 rounded-xl border text-xs ${inputBg}`}
                  />
                  <select
                    value={editingUser.role}
                    onChange={(e) => setEditingUser({ ...editingUser, role: e.target.value })}
                    className={`px-3 py-1.5 rounded-xl border text-xs ${inputBg}`}
                  >
                    <option value="Member">Member</option>
                    <option value="Admin">Admin</option>
                    <option value="Guest">Guest</option>
                  </select>
                  <button
                    type="submit"
                    className="px-3 py-1.5 rounded-xl bg-cyan-500 text-slate-950 font-bold text-xs"
                  >
                    Lưu
                  </button>
                  <button
                    type="button"
                    onClick={() => setEditingUser(null)}
                    className="px-3 py-1.5 rounded-xl bg-slate-800 text-slate-300 text-xs"
                  >
                    Hủy
                  </button>
                </form>
              )}

              {/* Bảng danh sách thành viên hiện tại */}
              <div className={`rounded-2xl border overflow-hidden ${cardBg}`}>
                <table className="w-full text-left text-xs">
                  <thead className="bg-slate-900/80 text-slate-400 uppercase text-[11px]">
                    <tr>
                      <th className="p-3">Tên thành viên</th>
                      <th className="p-3">Email</th>
                      <th className="p-3">Vai trò</th>
                      <th className="p-3 text-right">Thao tác</th>
                    </tr>
                  </thead>
                  <tbody className="divide-y divide-slate-800/70">
                    {(usersList.length > 0 ? usersList : [currentUser]).map((u) => {
                      const isCurrentSelf =
                        u.email.trim().toLowerCase() === currentUser.email.trim().toLowerCase();
                      const isRootOwner = (u.role || '').trim().toLowerCase() === 'owner';

                      return (
                        <tr key={u.id}>
                          <td className="p-3 font-bold">
                            {u.name}
                            {isCurrentSelf && (
                              <span className="ml-2 px-1.5 py-0.5 rounded bg-emerald-500/15 text-emerald-400 text-[10px] font-semibold">
                                Bạn
                              </span>
                            )}
                          </td>
                          <td className="p-3 font-mono text-slate-400">{u.email}</td>
                          <td className="p-3">
                            <span className="px-2 py-0.5 rounded bg-cyan-500/15 text-cyan-400 font-semibold">
                              {u.role}
                            </span>
                          </td>
                          <td className="p-3 text-right">
                            {isCurrentSelf || isRootOwner ? (
                              <span className="text-[11px] text-slate-500 italic">
                                {isCurrentSelf ? 'Đang đăng nhập' : 'Chủ nhà gốc'}
                              </span>
                            ) : (
                              <div className="inline-flex items-center gap-1.5">
                                <button
                                  onClick={() => setEditingUser(u)}
                                  className="px-2.5 py-1 rounded bg-sky-500/15 text-sky-400 hover:bg-sky-500/25 transition"
                                >
                                  Sửa
                                </button>
                                <button
                                  onClick={() => handleDeleteUser(u)}
                                  className="px-2.5 py-1 rounded bg-red-500/15 text-red-400 hover:bg-red-500/25 transition"
                                >
                                  Xóa
                                </button>
                              </div>
                            )}
                          </td>
                        </tr>
                      );
                    })}
                  </tbody>
                </table>
              </div>
            </div>
          )}
        </main>
      </div>
    </div>
  );
}

export default App;