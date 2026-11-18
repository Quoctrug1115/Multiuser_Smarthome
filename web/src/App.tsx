import { EnergyAnalyticsPanel } from './components/EnergyAnalyticsPanel';
import React, { useState, useEffect, useCallback } from 'react';
import type { House, Room, UserAccount, UserRole } from './types/smarthome';
import { ExcelImportModal, type ExcelImportMode } from './components/ExcelImportModal';
import {
  exportAccountsToExcel,
  exportDevicesToExcel,
  exportHousesAndRoomsToExcel,
} from './utils/excelService';

const API_BASE = 'http://localhost:3000/api/v1';
const WS_URL = 'ws://localhost:3000/ws';

type TabKey = 'overview' | 'rooms' | 'automations' | 'energy' | 'ai' | 'accounts';

interface DeviceItem {
  id: string;
  name: string;
  room_id?: string | null;
  room_name?: string | null;
  device_type: string;
  mqtt_topic: string;
  is_on: boolean;
  status?: string;
}

interface DiscoveredDevice {
  name: string;
  device_type: string;
  mqtt_topic: string;
  chip?: string;
}

interface AutomationRule {
  id: string;
  name: string;
  condition_type?: string;
  trigger_type?: string;
  operator?: string;
  threshold?: number;
  trigger_value?: number;
  action?: string;
  action_text?: string;
  device_id?: string;
  is_active?: boolean;
  enabled?: boolean;
}

interface AiAlert {
  id?: string;
  title?: string;
  message?: string;
  severity?: string;
  created_at?: string;
}

interface CurrentUser {
  id: string;
  name: string;
  email: string;
  role: string;
}

function parseJwtPayload(token: string): Record<string, unknown> | null {
  try {
    const parts = token.split('.');
    if (parts.length !== 3) return null;
    const base64 = parts[1].replace(/-/g, '+').replace(/_/g, '/');
    const padded = base64.padEnd(base64.length + ((4 - (base64.length % 4)) % 4), '=');
    const jsonStr = decodeURIComponent(
      atob(padded)
        .split('')
        .map((c) => '%' + ('00' + c.charCodeAt(0).toString(16)).slice(-2))
        .join('')
    );
    return JSON.parse(jsonStr);
  } catch {
    return null;
  }
}

function extractRoleFromJwt(token: string): string | null {
  const jwt = parseJwtPayload(token);
  if (!jwt) return null;
  const candidate =
    jwt.role ??
    jwt.role_name ??
    jwt.user_role ??
    (Array.isArray(jwt.roles) ? jwt.roles[0] : null);
  return typeof candidate === 'string' && candidate.trim() ? candidate.trim() : null;
}

function getAuthHeaders(hasBody = false): Record<string, string> {
  const token = localStorage.getItem('token');
  return {
    ...(hasBody ? { 'Content-Type': 'application/json' } : {}),
    ...(token && token !== 'authenticated' ? { Authorization: `Bearer ${token}` } : {}),
  };
}

async function readErrorText(res: Response, fallback: string): Promise<string> {
  const txt = await res.text().catch(() => '');
  if (!txt) return `${fallback} (${res.status})`;
  try {
    const parsed = JSON.parse(txt);
    return String(parsed.error || parsed.message || txt);
  } catch {
    return txt;
  }
}

export function App() {
  // ==================== AUTH & THEME ====================
  const [currentUser, setCurrentUser] = useState<CurrentUser | null>(() => {
    try {
      const saved = localStorage.getItem('smarthome_user');
      if (!saved) return null;
      const parsed: CurrentUser = JSON.parse(saved);
      const token = localStorage.getItem('token') || '';
      const jwtRole = extractRoleFromJwt(token);

      // Không tin tưởng role Admin cũ lưu trong cache nếu JWT không xác nhận
      const resolvedRole = jwtRole || 'Member';
      const syncedUser = { ...parsed, role: resolvedRole };
      localStorage.setItem('smarthome_user', JSON.stringify(syncedUser));
      return syncedUser;
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

  const [isDark, setIsDark] = useState(true);
  const [activeTab, setActiveTab] = useState<TabKey>('overview');
  const [clockText, setClockText] = useState('');
  const [wsConnected, setWsConnected] = useState(false);

  // Chỉ Owner hoặc Admin mới có quyền quản trị hệ thống, tài khoản, thêm/sửa/xóa & nhập/xuất Excel
  const normalizedRole = (currentUser?.role || 'Member').trim().toLowerCase();
  const isOwnerOrAdmin = normalizedRole === 'owner' || normalizedRole === 'admin';

  // ==================== DATABASE ENTITIES ====================
  const [houses, setHouses] = useState<House[]>([]);
  const [rooms, setRooms] = useState<Room[]>([]);
  const [devices, setDevices] = useState<DeviceItem[]>([]);
  const [automations, setAutomations] = useState<AutomationRule[]>([]);
  const [usersList, setUsersList] = useState<UserAccount[]>([]);
  const [aiAlerts, setAiAlerts] = useState<AiAlert[]>([]);
  const [energyData, setEnergyData] = useState<{
    total_kwh: number;
    estimated_cost: number;
    daily: { label: string; kwh: number }[];
  }>({
    total_kwh: 0,
    estimated_cost: 0,
    daily: [
      { label: 'T2', kwh: 1.8 },
      { label: 'T3', kwh: 2.1 },
      { label: 'T4', kwh: 1.6 },
      { label: 'T5', kwh: 2.4 },
      { label: 'T6', kwh: 1.9 },
      { label: 'T7', kwh: 2.6 },
      { label: 'CN', kwh: 2.2 },
    ],
  });

  const [sensorData, setSensorData] = useState({
    temperature: 28.5,
    humidity: 65,
    lux: 450,
    motion: false,
  });

  const [systemLogs, setSystemLogs] = useState<string[]>([
    'SYSTEM: Khởi động giao diện quản trị SmartHome IoT.',
  ]);

  const addLog = useCallback((msg: string) => {
    const time = new Date().toLocaleTimeString('vi-VN', { hour12: false });
    setSystemLogs((prev) => [`[${time}] ${msg}`, ...prev.slice(0, 49)]);
  }, []);

  // ==================== FILTER STATES ====================
  const [selectedHouseId, setSelectedHouseId] = useState<string | null>(null);
  const [selectedRoomId, setSelectedRoomId] = useState<string | null>(null);
  const [deviceFilterMode, setDeviceFilterMode] = useState<'all' | 'unassigned' | 'room'>('all');

  // ==================== MODAL STATES ====================
  const [isHouseModalOpen, setIsHouseModalOpen] = useState(false);
  const [editingHouse, setEditingHouse] = useState<House | null>(null);
  const [houseNameInput, setHouseNameInput] = useState('');
  const [houseAddressInput, setHouseAddressInput] = useState('');
  const [houseError, setHouseError] = useState('');
  const [houseSaving, setHouseSaving] = useState(false);

  const [isRoomModalOpen, setIsRoomModalOpen] = useState(false);
  const [editingRoom, setEditingRoom] = useState<Room | null>(null);
  const [roomHouseIdInput, setRoomHouseIdInput] = useState('');
  const [roomNameInput, setRoomNameInput] = useState('');
  const [roomFloorInput, setRoomFloorInput] = useState<number>(1);
  const [roomError, setRoomError] = useState('');
  const [roomSaving, setRoomSaving] = useState(false);

  const [isDeviceModalOpen, setIsDeviceModalOpen] = useState(false);
  const [editingDevice, setEditingDevice] = useState<DeviceItem | null>(null);
  const [devNameInput, setDevNameInput] = useState('');
  const [devTypeInput, setDevTypeInput] = useState('light');
  const [devRoomIdInput, setDevRoomIdInput] = useState('');
  const [devTopicInput, setDevTopicInput] = useState('');
  const [devError, setDevError] = useState('');
  const [devSaving, setDevSaving] = useState(false);

  const [isDiscoverModalOpen, setIsDiscoverModalOpen] = useState(false);
  const [discoveredList, setDiscoveredList] = useState<DiscoveredDevice[]>([]);
  const [isDiscovering, setIsDiscovering] = useState(false);

  const [isAccountModalOpen, setIsAccountModalOpen] = useState(false);
  const [accNameInput, setAccNameInput] = useState('');
  const [accEmailInput, setAccEmailInput] = useState('');
  const [accPasswordInput, setAccPasswordInput] = useState('123456');
  const [accRoleInput, setAccRoleInput] = useState<UserRole>('Member' as UserRole);
  const [accountError, setAccountError] = useState('');
  const [accountSaving, setAccountSaving] = useState(false);

  const [isExcelModalOpen, setIsExcelModalOpen] = useState(false);
  const [excelImportMode, setExcelImportMode] = useState<ExcelImportMode>('houses_rooms');

  const [autoName, setAutoName] = useState('');
  const [autoCondType, setAutoCondType] = useState('temperature');
  const [autoOperator, setAutoOperator] = useState('>');
  const [autoThreshold, setAutoThreshold] = useState(30);
  const [autoDeviceId, setAutoDeviceId] = useState('');
  const [autoAction, setAutoAction] = useState('ON');

  useEffect(() => {
    if (!isOwnerOrAdmin && activeTab === 'accounts') {
      setActiveTab('overview');
    }
  }, [isOwnerOrAdmin, activeTab]);

  // ==================== CLOCK ====================
  useEffect(() => {
    const updateClock = () => {
      const now = new Date();
      const time = now.toLocaleTimeString('vi-VN', { hour12: false });
      const date = now.toLocaleDateString('vi-VN');
      setClockText(`${time} ${date}`);
    };
    updateClock();
    const timer = setInterval(updateClock, 1000);
    return () => clearInterval(timer);
  }, []);

  // ==================== FETCH ALL DATA FROM POSTGRESQL ====================
  const fetchAllDatabaseData = useCallback(async () => {
    const headers = getAuthHeaders(false);

    try {
      const [housesRes, roomsRes, devicesRes, autoRes, usersRes, aiRes, energyRes] =
        await Promise.all([
          fetch(`${API_BASE}/houses`, { headers }).catch(() => null),
          fetch(`${API_BASE}/rooms`, { headers }).catch(() => null),
          fetch(`${API_BASE}/devices`, { headers }).catch(() => null),
          fetch(`${API_BASE}/automations`, { headers }).catch(() => null),
          fetch(`${API_BASE}/users`, { headers }).catch(() => null),
          fetch(`${API_BASE}/ai/alerts`, { headers }).catch(() => null),
          fetch(`${API_BASE}/energy/analytics`, { headers }).catch(() => null),
        ]);

      // Đồng bộ quyền thực tế từ Backend: nếu /users trả về 403 -> chắc chắn là Member
      if (usersRes) {
        if (usersRes.status === 403 || usersRes.status === 401) {
          setUsersList([]);
          setCurrentUser((prev) => {
            if (!prev || prev.role === 'Member') return prev;
            const updated = { ...prev, role: 'Member' };
            localStorage.setItem('smarthome_user', JSON.stringify(updated));
            return updated;
          });
        } else if (usersRes.ok) {
          const data = await usersRes.json();
          const list: UserAccount[] = Array.isArray(data) ? data : [];
          setUsersList(list);
          // Tìm đúng user đang đăng nhập trong danh sách để cập nhật role chuẩn xác
          setCurrentUser((prev) => {
            if (!prev) return prev;
            const me = list.find(
              (u) => u.email.trim().toLowerCase() === prev.email.trim().toLowerCase()
            );
            if (me && me.role && me.role !== prev.role) {
              const updated = { ...prev, id: me.id || prev.id, role: me.role };
              localStorage.setItem('smarthome_user', JSON.stringify(updated));
              return updated;
            }
            return prev;
          });
        }
      }

      if (housesRes && housesRes.ok) {
        const data = await housesRes.json();
        setHouses(Array.isArray(data) ? data : []);
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

      if (aiRes && aiRes.ok) {
        const data = await aiRes.json();
        setAiAlerts(Array.isArray(data) ? data : []);
      }

      if (energyRes && energyRes.ok) {
        const data = await energyRes.json();
        const totalKwh = Number(data?.total_kwh ?? data?.totalKwh ?? 16.86);
        const dailyRaw = Array.isArray(data?.daily) ? data.daily : [];
        const normalizedDaily =
          dailyRaw.length > 0
            ? dailyRaw.map((item: Record<string, unknown>, i: number) => ({
                label: String(item.label ?? item.day ?? item.date ?? `N${i + 1}`),
                kwh: Number(item.kwh ?? item.value ?? 0),
              }))
            : [
                { label: 'T2', kwh: 1.8 },
                { label: 'T3', kwh: 2.1 },
                { label: 'T4', kwh: 1.6 },
                { label: 'T5', kwh: 2.4 },
                { label: 'T6', kwh: 1.9 },
                { label: 'T7', kwh: 2.6 },
                { label: 'CN', kwh: 2.2 },
              ];

        setEnergyData({
          total_kwh: totalKwh,
          estimated_cost: Number(data?.estimated_cost ?? Math.round(totalKwh * 2500)),
          daily: normalizedDaily,
        });
      }
    } catch (err) {
      console.error('Lỗi đồng bộ dữ liệu:', err);
    }
  }, []);

  useEffect(() => {
    if (currentUser) {
      fetchAllDatabaseData();
    }
  }, [currentUser?.email, fetchAllDatabaseData]);

  // ==================== WEBSOCKET REALTIME ====================
  useEffect(() => {
    if (!currentUser) return;
    let ws: WebSocket | null = null;
    let reconnectTimer: ReturnType<typeof setTimeout>;

    const connectWs = () => {
      try {
        ws = new WebSocket(WS_URL);
        ws.onopen = () => setWsConnected(true);
        ws.onclose = () => {
          setWsConnected(false);
          reconnectTimer = setTimeout(connectWs, 3000);
        };
        ws.onerror = () => setWsConnected(false);
        ws.onmessage = (event) => {
          try {
            const msg = JSON.parse(event.data);
            if (msg.type === 'SENSOR_UPDATE' && msg.data) {
              setSensorData((prev) => ({
                temperature: Number(msg.data.temperature ?? prev.temperature),
                humidity: Number(msg.data.humidity ?? prev.humidity),
                lux: Number(msg.data.lux ?? prev.lux),
                motion: Boolean(msg.data.motion ?? prev.motion),
              }));
            } else if (msg.type === 'DEVICE_UPDATE' && msg.data) {
              setDevices((prev) =>
                prev.map((d) =>
                  d.id === msg.data.id || d.mqtt_topic === msg.data.mqtt_topic
                    ? {
                        ...d,
                        is_on: Boolean(msg.data.is_on),
                        status: msg.data.is_on ? 'ON' : 'OFF',
                      }
                    : d
                )
              );
            }
          } catch {
            // ignore
          }
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
  }, [currentUser]);

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

      if (!res.ok) {
        const errMsg = await readErrorText(res, 'Đăng nhập thất bại');
        setAuthError(errMsg);
        setAuthLoading(false);
        return;
      }

      const data = await res.json();
      const token = data.token || data.access_token || '';
      const jwt = parseJwtPayload(token);
      const jwtRole = extractRoleFromJwt(token);

      const resolvedRole =
        (typeof data.user?.role === 'string' && data.user.role.trim()) ||
        (typeof data.role === 'string' && data.role.trim()) ||
        jwtRole ||
        'Member';

      const userObj: CurrentUser = {
        id:
          data.user?.id ||
          data.id ||
          (typeof jwt?.sub === 'string' ? jwt.sub : '') ||
          '',
        name:
          data.user?.name ||
          data.name ||
          (typeof jwt?.name === 'string' ? jwt.name : '') ||
          authEmail.split('@')[0],
        email:
          data.user?.email ||
          data.email ||
          (typeof jwt?.email === 'string' ? jwt.email : '') ||
          authEmail,
        role: resolvedRole,
      };

      localStorage.setItem('token', token || 'authenticated');
      localStorage.setItem('smarthome_user', JSON.stringify(userObj));
      setCurrentUser(userObj);
      setActiveTab('overview');
    } catch {
      setAuthError('Không thể kết nối tới Backend Rust (http://localhost:3000)');
    } finally {
      setAuthLoading(false);
    }
  };

  const handleLogout = () => {
    localStorage.removeItem('token');
    localStorage.removeItem('smarthome_user');
    setCurrentUser(null);
    setUsersList([]);
  };

  // ==================== HOUSE MANUAL CRUD HANDLERS ====================
  const openCreateHouseModal = () => {
    if (!isOwnerOrAdmin) return;
    setEditingHouse(null);
    setHouseNameInput('');
    setHouseAddressInput('');
    setHouseError('');
    setIsHouseModalOpen(true);
  };

  const openEditHouseModal = (house: House, e: React.MouseEvent) => {
    e.stopPropagation();
    if (!isOwnerOrAdmin) return;
    setEditingHouse(house);
    setHouseNameInput(house.name);
    setHouseAddressInput(house.address || '');
    setHouseError('');
    setIsHouseModalOpen(true);
  };

  const handleSaveHouse = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!isOwnerOrAdmin) return;
    if (!houseNameInput.trim()) {
      setHouseError('Tên ngôi nhà không được để trống');
      return;
    }

    setHouseSaving(true);
    setHouseError('');
    try {
      const url = editingHouse
        ? `${API_BASE}/houses/${editingHouse.id}`
        : `${API_BASE}/houses`;
      const method = editingHouse ? 'PUT' : 'POST';

      const res = await fetch(url, {
        method,
        headers: getAuthHeaders(true),
        body: JSON.stringify({
          name: houseNameInput.trim(),
          address: houseAddressInput.trim(),
        }),
      });

      if (!res.ok) {
        setHouseError(
          await readErrorText(res, editingHouse ? 'Lỗi cập nhật nhà' : 'Lỗi tạo nhà')
        );
        return;
      }

      addLog(
        editingHouse
          ? `HOUSE UPDATED: Đã cập nhật nhà "${houseNameInput.trim()}"`
          : `HOUSE CREATED: Đã tạo ngôi nhà "${houseNameInput.trim()}"`
      );
      setIsHouseModalOpen(false);
      await fetchAllDatabaseData();
    } catch {
      setHouseError('Lỗi kết nối tới server Backend');
    } finally {
      setHouseSaving(false);
    }
  };

  const handleDeleteHouse = async (house: House, e: React.MouseEvent) => {
    e.stopPropagation();
    if (!isOwnerOrAdmin) return;
    if (!window.confirm(`Xóa ngôi nhà "${house.name}"? Các phòng bên trong cũng sẽ bị xóa.`)) {
      return;
    }

    try {
      const res = await fetch(`${API_BASE}/houses/${house.id}`, {
        method: 'DELETE',
        headers: getAuthHeaders(false),
      });
      if (!res.ok) {
        alert(await readErrorText(res, 'Không thể xóa ngôi nhà'));
        return;
      }
      if (selectedHouseId === house.id) {
        setSelectedHouseId(null);
        setSelectedRoomId(null);
      }
      addLog(`HOUSE DELETED: Đã xóa ngôi nhà "${house.name}"`);
      await fetchAllDatabaseData();
    } catch {
      alert('Lỗi kết nối khi xóa ngôi nhà');
    }
  };

  // ==================== ROOM MANUAL CRUD HANDLERS ====================
  const openCreateRoomModal = () => {
    if (!isOwnerOrAdmin) return;
    if (houses.length === 0) {
      alert('Bạn cần tạo ít nhất 1 Ngôi nhà trước khi thêm Phòng.');
      return;
    }
    setEditingRoom(null);
    setRoomHouseIdInput(selectedHouseId || houses[0].id);
    setRoomNameInput('');
    setRoomFloorInput(1);
    setRoomError('');
    setIsRoomModalOpen(true);
  };

  const openEditRoomModal = (room: Room, e: React.MouseEvent) => {
    e.stopPropagation();
    if (!isOwnerOrAdmin) return;
    setEditingRoom(room);
    setRoomHouseIdInput(room.house_id);
    setRoomNameInput(room.name);
    setRoomFloorInput(room.floor ?? 1);
    setRoomError('');
    setIsRoomModalOpen(true);
  };

  const handleSaveRoom = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!isOwnerOrAdmin) return;
    if (!roomHouseIdInput) {
      setRoomError('Vui lòng chọn ngôi nhà trực thuộc');
      return;
    }
    if (!roomNameInput.trim()) {
      setRoomError('Tên phòng không được để trống');
      return;
    }

    setRoomSaving(true);
    setRoomError('');
    try {
      const url = editingRoom
        ? `${API_BASE}/rooms/${editingRoom.id}`
        : `${API_BASE}/rooms`;
      const method = editingRoom ? 'PUT' : 'POST';

      const res = await fetch(url, {
        method,
        headers: getAuthHeaders(true),
        body: JSON.stringify({
          house_id: roomHouseIdInput,
          name: roomNameInput.trim(),
          floor: Number(roomFloorInput) || 1,
        }),
      });

      if (!res.ok) {
        setRoomError(
          await readErrorText(res, editingRoom ? 'Lỗi cập nhật phòng' : 'Lỗi tạo phòng')
        );
        return;
      }

      addLog(
        editingRoom
          ? `ROOM UPDATED: Đã cập nhật phòng "${roomNameInput.trim()}"`
          : `ROOM CREATED: Đã tạo phòng "${roomNameInput.trim()}"`
      );
      setIsRoomModalOpen(false);
      await fetchAllDatabaseData();
    } catch {
      setRoomError('Lỗi kết nối tới server Backend');
    } finally {
      setRoomSaving(false);
    }
  };

  const handleDeleteRoom = async (room: Room, e: React.MouseEvent) => {
    e.stopPropagation();
    if (!isOwnerOrAdmin) return;
    if (!window.confirm(`Bạn có chắc muốn xóa phòng "${room.name}"?`)) {
      return;
    }

    try {
      const res = await fetch(`${API_BASE}/rooms/${room.id}`, {
        method: 'DELETE',
        headers: getAuthHeaders(false),
      });
      if (!res.ok) {
        alert(await readErrorText(res, 'Không thể xóa phòng'));
        return;
      }
      if (selectedRoomId === room.id) {
        setSelectedRoomId(null);
        setDeviceFilterMode('all');
      }
      addLog(`ROOM DELETED: Đã xóa phòng "${room.name}"`);
      await fetchAllDatabaseData();
    } catch {
      alert('Lỗi kết nối khi xóa phòng');
    }
  };

  // ==================== DEVICE MANUAL CRUD & CONTROL ====================
  const openCreateDeviceModal = () => {
    if (!isOwnerOrAdmin) return;
    setEditingDevice(null);
    setDevNameInput('');
    setDevTypeInput('light');
    setDevRoomIdInput(selectedRoomId || '');
    setDevTopicInput('smarthome/devices/');
    setDevError('');
    setIsDeviceModalOpen(true);
  };

  const openEditDeviceModal = (dev: DeviceItem) => {
    if (!isOwnerOrAdmin) return;
    setEditingDevice(dev);
    setDevNameInput(dev.name);
    setDevTypeInput(dev.device_type || 'switch');
    setDevRoomIdInput(dev.room_id || '');
    setDevTopicInput(dev.mqtt_topic || '');
    setDevError('');
    setIsDeviceModalOpen(true);
  };

  const handleSaveDevice = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!isOwnerOrAdmin) return;
    if (!devNameInput.trim() || !devTopicInput.trim()) {
      setDevError('Tên thiết bị và MQTT Topic không được để trống');
      return;
    }

    setDevSaving(true);
    setDevError('');
    try {
      const url = editingDevice
        ? `${API_BASE}/devices/${editingDevice.id}`
        : `${API_BASE}/devices`;
      const method = editingDevice ? 'PUT' : 'POST';

      const res = await fetch(url, {
        method,
        headers: getAuthHeaders(true),
        body: JSON.stringify({
          name: devNameInput.trim(),
          device_type: devTypeInput,
          mqtt_topic: devTopicInput.trim(),
          room_id: devRoomIdInput || null,
        }),
      });

      if (!res.ok) {
        setDevError(await readErrorText(res, 'Không thể lưu thiết bị'));
        return;
      }

      addLog(
        editingDevice
          ? `DEVICE UPDATED: Đã cập nhật thiết bị "${devNameInput.trim()}"`
          : `DEVICE CREATED: Đã thêm thiết bị "${devNameInput.trim()}"`
      );
      setIsDeviceModalOpen(false);
      await fetchAllDatabaseData();
    } catch {
      setDevError('Lỗi kết nối Backend khi lưu thiết bị');
    } finally {
      setDevSaving(false);
    }
  };

  const handleToggleDevice = async (dev: DeviceItem) => {
    const nextState = !dev.is_on;
    setDevices((prev) =>
      prev.map((d) =>
        d.id === dev.id ? { ...d, is_on: nextState, status: nextState ? 'ON' : 'OFF' } : d
      )
    );

    try {
      await fetch(`${API_BASE}/devices/${dev.id}/control`, {
        method: 'POST',
        headers: getAuthHeaders(true),
        body: JSON.stringify({
          action: nextState ? 'ON' : 'OFF',
          is_on: nextState,
          mqtt_topic: dev.mqtt_topic,
        }),
      });
      addLog(`MQTT CONTROL: ${dev.name} -> ${nextState ? 'ON' : 'OFF'}`);
    } catch {
      await fetchAllDatabaseData();
    }
  };

  const handleDeleteDevice = async (dev: DeviceItem) => {
    if (!isOwnerOrAdmin) return;
    if (!window.confirm(`Xóa thiết bị "${dev.name}" khỏi hệ thống?`)) return;
    try {
      const res = await fetch(`${API_BASE}/devices/${dev.id}`, {
        method: 'DELETE',
        headers: getAuthHeaders(false),
      });
      if (res.ok) {
        addLog(`DEVICE DELETED: Đã xóa "${dev.name}"`);
        await fetchAllDatabaseData();
      }
    } catch {
      alert('Lỗi khi xóa thiết bị');
    }
  };

  const handleDiscoverWokwi = async () => {
    if (!isOwnerOrAdmin) return;
    setIsDiscoverModalOpen(true);
    setIsDiscovering(true);
    try {
      const res = await fetch(`${API_BASE}/devices/discover`, {
        headers: getAuthHeaders(false),
      });
      if (res.ok) {
        const data = await res.json();
        setDiscoveredList(Array.isArray(data) ? data : []);
      }
    } catch {
      setDiscoveredList([]);
    } finally {
      setIsDiscovering(false);
    }
  };

  const handleAddDiscoveredDevice = async (item: DiscoveredDevice) => {
    if (!isOwnerOrAdmin) return;
    try {
      const res = await fetch(`${API_BASE}/devices`, {
        method: 'POST',
        headers: getAuthHeaders(true),
        body: JSON.stringify({
          name: item.name,
          device_type: item.device_type,
          mqtt_topic: item.mqtt_topic,
          room_id: selectedRoomId || null,
        }),
      });
      if (res.ok) {
        setDiscoveredList((prev) => prev.filter((d) => d.mqtt_topic !== item.mqtt_topic));
        addLog(`WOKWI PAIRED: Đã thêm "${item.name}"`);
        await fetchAllDatabaseData();
      }
    } catch {
      alert('Không thể thêm thiết bị Wokwi');
    }
  };

  // ==================== ACCOUNT MANUAL CRUD HANDLERS (CHỈ OWNER/ADMIN) ====================
  const handleCreateAccountManual = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!isOwnerOrAdmin) return;
    if (!accNameInput.trim() || !accEmailInput.trim()) {
      setAccountError('Họ tên và Email không được để trống');
      return;
    }

    setAccountSaving(true);
    setAccountError('');
    try {
      const res = await fetch(`${API_BASE}/users`, {
        method: 'POST',
        headers: getAuthHeaders(true),
        body: JSON.stringify({
          name: accNameInput.trim(),
          email: accEmailInput.trim(),
          password: accPasswordInput || '123456',
          role: accRoleInput,
        }),
      });

      if (!res.ok) {
        setAccountError(await readErrorText(res, 'Không thể tạo tài khoản'));
        return;
      }

      addLog(`ACCOUNT CREATED: Đã tạo tài khoản "${accEmailInput.trim()}"`);
      setAccNameInput('');
      setAccEmailInput('');
      setAccPasswordInput('123456');
      setIsAccountModalOpen(false);
      await fetchAllDatabaseData();
    } catch {
      setAccountError('Lỗi kết nối tới Backend');
    } finally {
      setAccountSaving(false);
    }
  };

  const handleDeleteUser = async (user: UserAccount) => {
    if (!isOwnerOrAdmin) return;
    if (!window.confirm(`Xóa tài khoản "${user.email}"?`)) return;
    try {
      const res = await fetch(`${API_BASE}/users/${user.id}`, {
        method: 'DELETE',
        headers: getAuthHeaders(false),
      });
      if (!res.ok) {
        alert(await readErrorText(res, 'Không thể xóa tài khoản'));
        return;
      }
      addLog(`ACCOUNT DELETED: Đã xóa "${user.email}"`);
      await fetchAllDatabaseData();
    } catch {
      alert('Không thể xóa tài khoản');
    }
  };

  // ==================== AUTOMATION & AI HANDLERS ====================
  const handleCreateAutomation = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!isOwnerOrAdmin || !autoName.trim()) return;
    try {
      const res = await fetch(`${API_BASE}/automations`, {
        method: 'POST',
        headers: getAuthHeaders(true),
        body: JSON.stringify({
          name: autoName.trim(),
          condition_type: autoCondType,
          operator: autoOperator,
          threshold: Number(autoThreshold),
          device_id: autoDeviceId,
          action: autoAction,
          is_active: true,
        }),
      });
      if (res.ok) {
        setAutoName('');
        addLog(`AUTOMATION CREATED: Đã tạo kịch bản "${autoName.trim()}"`);
        await fetchAllDatabaseData();
      }
    } catch {
      alert('Không thể tạo kịch bản');
    }
  };

  const handleToggleAutomation = async (rule: AutomationRule) => {
    if (!isOwnerOrAdmin) return;
    try {
      await fetch(`${API_BASE}/automations/${rule.id}/toggle`, {
        method: 'POST',
        headers: getAuthHeaders(false),
      });
      await fetchAllDatabaseData();
    } catch {
      // ignore
    }
  };

  const handleDeleteAutomation = async (id: string) => {
    if (!isOwnerOrAdmin) return;
    try {
      await fetch(`${API_BASE}/automations/${id}`, {
        method: 'DELETE',
        headers: getAuthHeaders(false),
      });
      await fetchAllDatabaseData();
    } catch {
      // ignore
    }
  };

  const handleSimulateAnomaly = async () => {
    if (!isOwnerOrAdmin) return;
    try {
      await fetch(`${API_BASE}/ai/simulate-anomaly`, {
        method: 'POST',
        headers: getAuthHeaders(false),
      });
      addLog('AI ENGINE: Đã chạy mô phỏng phát hiện bất thường');
      await fetchAllDatabaseData();
    } catch {
      // ignore
    }
  };

  // ==================== COMPUTED DATA ====================
  const filteredRooms = selectedHouseId
    ? rooms.filter((r) => r.house_id === selectedHouseId)
    : rooms;

  const unassignedDevicesCount = devices.filter((d) => !d.room_id).length;

  const filteredDevices = devices.filter((d) => {
    if (selectedRoomId) {
      return d.room_id === selectedRoomId;
    }
    if (deviceFilterMode === 'unassigned') {
      return !d.room_id;
    }
    if (selectedHouseId) {
      const houseRoomIds = new Set(
        rooms.filter((r) => r.house_id === selectedHouseId).map((r) => r.id)
      );
      return d.room_id ? houseRoomIds.has(d.room_id) : false;
    }
    return true;
  });

  const activeDevices = devices.filter((d) => d.is_on);
  const estimatedLiveWatt = activeDevices.reduce((sum, d) => {
    if (d.device_type === 'fan') return sum + 45;
    if (d.device_type === 'light') return sum + 15;
    if (d.device_type === 'sensor') return sum + 2;
    return sum + 25;
  }, 0);

  const maxDailyKwh = Math.max(
    ...energyData.daily.map((d) => (Number.isFinite(d.kwh) ? d.kwh : 0)),
    0.1
  );
  const avgDailyKwh =
    energyData.daily.length > 0
      ? energyData.daily.reduce((s, d) => s + d.kwh, 0) / energyData.daily.length
      : 0;
  const peakDay = energyData.daily.reduce(
    (best, cur) => (cur.kwh > best.kwh ? cur : best),
    energyData.daily[0] || { label: '--', kwh: 0 }
  );

  // ==================== LOGIN VIEW ====================
  if (!currentUser) {
    return (
      <div className="min-h-screen bg-[#070b14] text-slate-100 flex items-center justify-center p-4">
        <div className="w-full max-w-md rounded-2xl bg-[#0d131f] border border-slate-800 p-8 shadow-2xl">
          <div className="flex items-center gap-3 mb-6">
            <div className="w-11 h-11 rounded-xl bg-cyan-500/15 border border-cyan-500/30 flex items-center justify-center text-2xl">
              🏠
            </div>
            <div>
              <h1 className="text-lg font-bold text-cyan-400">SmartHome IoT</h1>
              <p className="text-xs text-slate-400">Hệ thống Quản trị Nhà Thông Minh</p>
            </div>
          </div>

          {authError && (
            <div className="mb-4 p-3 rounded-lg bg-red-500/15 border border-red-500/40 text-red-400 text-xs">
              {authError}
            </div>
          )}

          <form onSubmit={handleAuthSubmit} className="space-y-4">
            {authMode === 'register' && (
              <div>
                <label className="block text-xs font-semibold text-slate-300 mb-1.5">
                  Họ và tên *
                </label>
                <input
                  type="text"
                  required
                  value={authName}
                  onChange={(e) => setAuthName(e.target.value)}
                  placeholder="Nguyễn Văn A"
                  className="w-full px-3.5 py-2.5 rounded-xl bg-[#131b2e] border border-slate-700 text-sm focus:outline-none focus:border-cyan-500"
                />
              </div>
            )}

            <div>
              <label className="block text-xs font-semibold text-slate-300 mb-1.5">
                Email *
              </label>
              <input
                type="email"
                required
                value={authEmail}
                onChange={(e) => setAuthEmail(e.target.value)}
                placeholder="admin@smarthome.vn"
                className="w-full px-3.5 py-2.5 rounded-xl bg-[#131b2e] border border-slate-700 text-sm focus:outline-none focus:border-cyan-500"
              />
            </div>

            <div>
              <label className="block text-xs font-semibold text-slate-300 mb-1.5">
                Mật khẩu *
              </label>
              <input
                type="password"
                required
                value={authPassword}
                onChange={(e) => setAuthPassword(e.target.value)}
                placeholder="••••••"
                className="w-full px-3.5 py-2.5 rounded-xl bg-[#131b2e] border border-slate-700 text-sm focus:outline-none focus:border-cyan-500"
              />
            </div>

            <button
              type="submit"
              disabled={authLoading}
              className="w-full py-2.5 rounded-xl bg-cyan-500 hover:bg-cyan-400 text-slate-950 font-bold text-sm transition disabled:opacity-50"
            >
              {authLoading
                ? 'Đang xử lý...'
                : authMode === 'login'
                ? 'Đăng nhập hệ thống'
                : 'Đăng ký tài khoản'}
            </button>
          </form>

          <div className="mt-4 text-center">
            <button
              type="button"
              onClick={() => {
                setAuthMode(authMode === 'login' ? 'register' : 'login');
                setAuthError('');
              }}
              className="text-xs text-cyan-400 hover:underline"
            >
              {authMode === 'login'
                ? 'Chưa có tài khoản? Đăng ký ngay'
                : 'Đã có tài khoản? Quay lại đăng nhập'}
            </button>
          </div>
        </div>
      </div>
    );
  }

  // ==================== MAIN DASHBOARD LAYOUT ====================
  const cardBg = isDark
    ? 'bg-[#0d131f] border-slate-800/90'
    : 'bg-white border-slate-200 shadow-sm';
  const subCardBg = isDark
    ? 'bg-[#121927] border-slate-800 hover:border-slate-700'
    : 'bg-slate-50 border-slate-200 hover:border-slate-300';

  return (
    <div
      className={`min-h-screen flex ${
        isDark ? 'bg-[#070b14] text-slate-100' : 'bg-slate-100 text-slate-800'
      }`}
    >
      {/* ==================== SIDEBAR ==================== */}
      <aside
        className={`w-64 shrink-0 border-r flex flex-col justify-between ${
          isDark ? 'bg-[#0a0f1a] border-slate-800/80' : 'bg-white border-slate-200'
        }`}
      >
        <div>
          <div className="p-5 flex items-center gap-3 border-b border-slate-800/60">
            <div className="w-10 h-10 rounded-xl bg-cyan-500/15 border border-cyan-500/30 flex items-center justify-center text-xl">
              🏠
            </div>
            <div className="min-w-0">
              <div className="text-sm font-bold text-cyan-400 truncate">SmartHome IoT</div>
              <div className="text-xs text-slate-400 truncate">{currentUser.name}</div>
            </div>
          </div>

          <div className="p-4">
            <div className="text-[10px] font-bold uppercase tracking-wider text-slate-500 px-3 mb-2">
              {isOwnerOrAdmin ? 'PHÂN HỆ QUẢN TRỊ' : 'ĐIỀU KHIỂN NHÀ THÔNG MINH'}
            </div>

            <nav className="space-y-1">
              <button
                onClick={() => setActiveTab('overview')}
                className={`w-full flex items-center justify-between px-3 py-2.5 rounded-xl text-xs font-semibold transition ${
                  activeTab === 'overview'
                    ? 'bg-cyan-500/15 text-cyan-400 border border-cyan-500/30'
                    : 'text-slate-400 hover:bg-slate-800/40 hover:text-slate-200'
                }`}
              >
                <span className="flex items-center gap-2.5">
                  <span>📊</span>
                  <span>Tổng quan</span>
                </span>
              </button>

              <button
                onClick={() => setActiveTab('rooms')}
                className={`w-full flex items-center justify-between px-3 py-2.5 rounded-xl text-xs font-semibold transition ${
                  activeTab === 'rooms'
                    ? 'bg-cyan-500/15 text-cyan-400 border border-cyan-500/30'
                    : 'text-slate-400 hover:bg-slate-800/40 hover:text-slate-200'
                }`}
              >
                <span className="flex items-center gap-2.5">
                  <span>📱</span>
                  <span>Phòng & Thiết bị</span>
                </span>
                <span className="px-2 py-0.5 rounded-md bg-cyan-500/15 text-cyan-400 text-[10px] font-mono">
                  {rooms.length}P • {devices.length}
                </span>
              </button>

              <button
                onClick={() => setActiveTab('automations')}
                className={`w-full flex items-center justify-between px-3 py-2.5 rounded-xl text-xs font-semibold transition ${
                  activeTab === 'automations'
                    ? 'bg-cyan-500/15 text-cyan-400 border border-cyan-500/30'
                    : 'text-slate-400 hover:bg-slate-800/40 hover:text-slate-200'
                }`}
              >
                <span className="flex items-center gap-2.5">
                  <span>⚡</span>
                  <span>Tự động hóa (IF-THEN)</span>
                </span>
                <span className="px-2 py-0.5 rounded-md bg-amber-500/15 text-amber-400 text-[10px] font-mono">
                  {automations.length}
                </span>
              </button>

              <button
                onClick={() => setActiveTab('energy')}
                className={`w-full flex items-center justify-between px-3 py-2.5 rounded-xl text-xs font-semibold transition ${
                  activeTab === 'energy'
                    ? 'bg-cyan-500/15 text-cyan-400 border border-cyan-500/30'
                    : 'text-slate-400 hover:bg-slate-800/40 hover:text-slate-200'
                }`}
              >
                <span className="flex items-center gap-2.5">
                  <span>📈</span>
                  <span>Thống kê Năng lượng</span>
                </span>
              </button>

              <button
                onClick={() => setActiveTab('ai')}
                className={`w-full flex items-center justify-between px-3 py-2.5 rounded-xl text-xs font-semibold transition ${
                  activeTab === 'ai'
                    ? 'bg-cyan-500/15 text-cyan-400 border border-cyan-500/30'
                    : 'text-slate-400 hover:bg-slate-800/40 hover:text-slate-200'
                }`}
              >
                <span className="flex items-center gap-2.5">
                  <span>🤖</span>
                  <span>Trí tuệ Nhân tạo (AI)</span>
                </span>
                <span className="px-2 py-0.5 rounded-md bg-red-500/15 text-red-400 text-[10px] font-mono">
                  {aiAlerts.length}
                </span>
              </button>

              {isOwnerOrAdmin && (
                <button
                  onClick={() => setActiveTab('accounts')}
                  className={`w-full flex items-center justify-between px-3 py-2.5 rounded-xl text-xs font-semibold transition ${
                    activeTab === 'accounts'
                      ? 'bg-cyan-500/15 text-cyan-400 border border-cyan-500/30'
                      : 'text-slate-400 hover:bg-slate-800/40 hover:text-slate-200'
                  }`}
                >
                  <span className="flex items-center gap-2.5">
                    <span>👥</span>
                    <span>Quản lý Tài khoản</span>
                  </span>
                  <span className="px-2 py-0.5 rounded-md bg-sky-500/15 text-sky-400 text-[10px] font-mono">
                    {usersList.length}
                  </span>
                </button>
              )}
            </nav>
          </div>
        </div>

        {/* User Footer */}
        <div className="p-4 border-t border-slate-800/60">
          <div
            className={`p-3 rounded-xl border flex items-center justify-between gap-2 ${
              isDark ? 'bg-[#0f1624] border-slate-800' : 'bg-slate-50 border-slate-200'
            }`}
          >
            <div className="flex items-center gap-2.5 min-w-0">
              <div className="w-8 h-8 rounded-full bg-cyan-500/20 text-cyan-400 flex items-center justify-center text-xs font-bold shrink-0">
                👤
              </div>
              <div className="min-w-0">
                <div className="text-xs font-semibold truncate">{currentUser.email}</div>
                <div className="text-[11px] text-emerald-400 truncate">
                  {currentUser.name} ({currentUser.role})
                </div>
              </div>
            </div>
            <button
              onClick={handleLogout}
              title="Đăng xuất"
              className="p-1.5 rounded-lg bg-red-500/15 text-red-400 hover:bg-red-500/25 text-xs shrink-0"
            >
              🚪
            </button>
          </div>
        </div>
      </aside>

      {/* ==================== MAIN CONTENT ==================== */}
      <div className="flex-1 flex flex-col min-w-0">
        {/* Top Status Header */}
        <header
          className={`h-14 border-b px-6 flex items-center justify-between gap-4 ${
            isDark ? 'bg-[#0a0f1a]/90 border-slate-800/80' : 'bg-white border-slate-200'
          }`}
        >
          <div className="flex items-center gap-2 px-3 py-1.5 rounded-lg bg-slate-900/70 border border-slate-800 text-xs text-slate-300">
            <span>🗄️</span>
            <span>
              PostgreSQL Sync: <strong>{houses.length}</strong> nhà •{' '}
              <strong>{rooms.length}</strong> phòng • <strong>{devices.length}</strong> thiết bị
            </span>
          </div>

          <div className="flex items-center gap-2.5 flex-wrap">
            <span
              className={`px-3 py-1 rounded-full text-[11px] font-semibold border ${
                wsConnected
                  ? 'bg-emerald-500/15 text-emerald-400 border-emerald-500/30'
                  : 'bg-red-500/15 text-red-400 border-red-500/30'
              }`}
            >
              ● WebSocket: {wsConnected ? 'Connected' : 'Disconnected'}
            </span>

            <span className="px-3 py-1 rounded-full text-[11px] font-semibold bg-sky-500/15 text-sky-400 border border-sky-500/30">
              ● MQTT Broker: Online
            </span>

            <span className="px-3 py-1 rounded-lg text-[11px] bg-slate-900 border border-slate-800 text-slate-300">
              Vai trò:{' '}
              <strong className={isOwnerOrAdmin ? 'text-cyan-400' : 'text-amber-400'}>
                {currentUser.role || 'Member'}
              </strong>
            </span>

            <button
              onClick={() => setIsDark(!isDark)}
              className="p-1.5 rounded-lg bg-slate-800/80 border border-slate-700 text-xs"
              title="Đổi giao diện Sáng/Tối"
            >
              {isDark ? '🌙' : '☀️'}
            </button>

            <span className="px-3 py-1 rounded-lg bg-slate-900 border border-slate-800 text-xs font-mono text-slate-300">
              {clockText}
            </span>
          </div>
        </header>

        {/* Body Content */}
        <main className="flex-1 p-6 space-y-6 overflow-y-auto">
          {/* ==================== TAB 1: TỔNG QUAN ==================== */}
          {activeTab === 'overview' && (
            <div className="space-y-6">
              {/* 1. 4 thẻ KPI Môi trường & Năng lượng */}
              <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-4">
                <div className={`p-5 rounded-2xl border ${cardBg}`}>
                  <div className="flex items-center justify-between text-xs text-slate-400 mb-1">
                    <span>🌡️ Nhiệt độ phòng</span>
                    <span className="px-2 py-0.5 rounded bg-amber-500/15 text-amber-400 text-[10px] font-semibold">
                      {sensorData.temperature > 31
                        ? 'Nóng'
                        : sensorData.temperature < 20
                        ? 'Lạnh'
                        : 'Ổn định'}
                    </span>
                  </div>
                  <div className="text-2xl font-bold text-amber-400">
                    {sensorData.temperature.toFixed(1)}°C
                  </div>
                  <div className="text-[11px] text-slate-500 mt-1">
                    Cảm biến DHT22 thời gian thực
                  </div>
                </div>

                <div className={`p-5 rounded-2xl border ${cardBg}`}>
                  <div className="flex items-center justify-between text-xs text-slate-400 mb-1">
                    <span>💧 Độ ẩm không khí</span>
                    <span className="px-2 py-0.5 rounded bg-cyan-500/15 text-cyan-400 text-[10px] font-semibold">
                      {sensorData.humidity > 80 ? 'Ẩm cao' : 'Thoáng'}
                    </span>
                  </div>
                  <div className="text-2xl font-bold text-cyan-400">
                    {sensorData.humidity.toFixed(0)}%
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
                        sensorData.motion
                          ? 'bg-emerald-500/20 text-emerald-400'
                          : 'bg-slate-800 text-slate-400'
                      }`}
                    >
                      {sensorData.motion ? 'Phát hiện người' : 'Yên tĩnh'}
                    </span>
                  </div>
                  <div className="text-2xl font-bold text-emerald-400">
                    {sensorData.lux} Lux
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
                    Điện năng tích lũy: {energyData.total_kwh.toFixed(2)} kWh
                  </div>
                </div>
              </div>

              {/* 2. Điều khiển nhanh thiết bị & Tổng quan Nhà/Phòng */}
              <div className="grid grid-cols-1 lg:grid-cols-3 gap-6">
                {/* Cột trái (2/3): Điều khiển nhanh thiết bị IoT */}
                <div className={`lg:col-span-2 p-5 rounded-2xl border space-y-4 ${cardBg}`}>
                  <div className="flex items-center justify-between">
                    <div>
                      <h3 className="text-sm font-bold">⚡ Điều khiển nhanh Thiết bị IoT</h3>
                      <p className="text-xs text-slate-400 mt-0.5">
                        Bật/tắt trực tiếp các thiết bị trong nhà qua giao thức MQTT
                      </p>
                    </div>
                    <button
                      onClick={() => setActiveTab('rooms')}
                      className="text-xs text-cyan-400 hover:underline font-semibold"
                    >
                      Xem tất cả ({devices.length}) →
                    </button>
                  </div>

                  {devices.length === 0 ? (
                    <div className="text-xs text-slate-400 py-8 text-center border border-dashed border-slate-800 rounded-xl">
                      Chưa có thiết bị IoT nào được kết nối.
                    </div>
                  ) : (
                    <div className="grid grid-cols-1 sm:grid-cols-2 gap-3">
                      {devices.slice(0, 6).map((dev) => {
                        const isSensor = dev.device_type === 'sensor';
                        const roomLabel =
                          dev.room_name ||
                          rooms.find((r) => r.id === dev.room_id)?.name ||
                          'Chưa phân phòng';
                        const icon =
                          dev.device_type === 'fan'
                            ? '🌀'
                            : dev.device_type === 'light'
                            ? '💡'
                            : isSensor
                            ? '📡'
                            : '🔌';

                        return (
                          <div
                            key={dev.id}
                            className={`p-3.5 rounded-xl border flex items-center justify-between gap-3 ${subCardBg}`}
                          >
                            <div className="flex items-center gap-3 min-w-0">
                              <div className="w-9 h-9 rounded-lg bg-slate-800 flex items-center justify-center text-lg shrink-0">
                                {icon}
                              </div>
                              <div className="min-w-0">
                                <div className="text-xs font-bold truncate">{dev.name}</div>
                                <div className="text-[11px] text-slate-400 truncate">
                                  {roomLabel}
                                </div>
                              </div>
                            </div>

                            {isSensor ? (
                              <span className="px-2 py-0.5 rounded bg-amber-500/15 text-amber-400 text-[10px] font-bold shrink-0">
                                ONLINE
                              </span>
                            ) : (
                              <button
                                onClick={() => handleToggleDevice(dev)}
                                className={`w-10 h-5 rounded-full transition p-0.5 shrink-0 ${
                                  dev.is_on ? 'bg-cyan-500' : 'bg-slate-700'
                                }`}
                              >
                                <div
                                  className={`w-4 h-4 rounded-full bg-white transition-transform ${
                                    dev.is_on ? 'translate-x-5' : 'translate-x-0'
                                  }`}
                                />
                              </button>
                            )}
                          </div>
                        );
                      })}
                    </div>
                  )}
                </div>

                {/* Cột phải (1/3): Tổng quan Nhà & Phòng */}
                <div className={`p-5 rounded-2xl border space-y-4 ${cardBg}`}>
                  <div className="flex items-center justify-between">
                    <h3 className="text-sm font-bold">🏡 Không gian Nhà & Phòng</h3>
                    <span className="text-xs font-mono text-slate-400">
                      {houses.length}N • {rooms.length}P
                    </span>
                  </div>

                  <div className="space-y-2.5 max-h-64 overflow-y-auto pr-1">
                    {rooms.length === 0 ? (
                      <div className="text-xs text-slate-400 py-6 text-center">
                        Chưa có phòng nào.
                      </div>
                    ) : (
                      rooms.map((r) => {
                        const roomDevs = devices.filter((d) => d.room_id === r.id);
                        const onCount = roomDevs.filter((d) => d.is_on).length;
                        const hName =
                          r.house_name ||
                          houses.find((h) => h.id === r.house_id)?.name ||
                          'Nhà';
                        return (
                          <div
                            key={r.id}
                            onClick={() => {
                              setSelectedHouseId(r.house_id);
                              setSelectedRoomId(r.id);
                              setDeviceFilterMode('room');
                              setActiveTab('rooms');
                            }}
                            className={`p-3 rounded-xl border cursor-pointer flex items-center justify-between ${subCardBg}`}
                          >
                            <div className="min-w-0">
                              <div className="text-xs font-bold truncate">🛏️ {r.name}</div>
                              <div className="text-[11px] text-slate-400 truncate">
                                Tầng {r.floor ?? 1} • {hName}
                              </div>
                            </div>
                            <span className="px-2 py-0.5 rounded bg-cyan-500/15 text-cyan-400 text-[10px] font-mono shrink-0">
                              {onCount}/{roomDevs.length} bật
                            </span>
                          </div>
                        );
                      })
                    )}
                  </div>
                </div>
              </div>

              {/* 3. Kịch bản Tự động hóa & Cảnh báo AI */}
              <div className="grid grid-cols-1 lg:grid-cols-2 gap-6">
                <div className={`p-5 rounded-2xl border space-y-3 ${cardBg}`}>
                  <div className="flex items-center justify-between">
                    <h3 className="text-sm font-bold">
                      ⚙️ Kịch bản Tự động hóa ({automations.length})
                    </h3>
                    <button
                      onClick={() => setActiveTab('automations')}
                      className="text-xs text-cyan-400 hover:underline font-semibold"
                    >
                      Chi tiết →
                    </button>
                  </div>
                  {automations.length === 0 ? (
                    <div className="text-xs text-slate-400 py-4">
                      Chưa thiết lập kịch bản tự động hóa nào.
                    </div>
                  ) : (
                    <div className="space-y-2">
                      {automations.slice(0, 4).map((rule) => {
                        const active = rule.is_active ?? rule.enabled ?? true;
                        return (
                          <div
                            key={rule.id}
                            className={`p-3 rounded-xl border flex items-center justify-between text-xs ${subCardBg}`}
                          >
                            <div>
                              <div className="font-bold">{rule.name}</div>
                              <div className="text-[11px] text-slate-400">
                                IF {rule.condition_type || rule.trigger_type}{' '}
                                {rule.operator || '>'} {rule.threshold ?? rule.trigger_value} →{' '}
                                {rule.action || 'ON'}
                              </div>
                            </div>
                            <span
                              className={`px-2 py-0.5 rounded text-[10px] font-bold ${
                                active
                                  ? 'bg-emerald-500/20 text-emerald-400'
                                  : 'bg-slate-800 text-slate-400'
                              }`}
                            >
                              {active ? 'BẬT' : 'TẮT'}
                            </span>
                          </div>
                        );
                      })}
                    </div>
                  )}
                </div>

                <div className={`p-5 rounded-2xl border space-y-3 ${cardBg}`}>
                  <div className="flex items-center justify-between">
                    <h3 className="text-sm font-bold">
                      🤖 Cảnh báo An ninh & AI ({aiAlerts.length})
                    </h3>
                    <button
                      onClick={() => setActiveTab('ai')}
                      className="text-xs text-cyan-400 hover:underline font-semibold"
                    >
                      Trung tâm AI →
                    </button>
                  </div>
                  {aiAlerts.length === 0 ? (
                    <div className="text-xs text-emerald-400/90 py-4">
                      ✓ Hệ thống vận hành ổn định, không có bất thường.
                    </div>
                  ) : (
                    <div className="space-y-2">
                      {aiAlerts.slice(0, 3).map((a, i) => (
                        <div
                          key={a.id || i}
                          className="p-3 rounded-xl bg-red-500/10 border border-red-500/30 text-xs"
                        >
                          <div className="font-bold text-red-400">
                            {a.title || 'Cảnh báo AI'}
                          </div>
                          <div className="text-slate-300 mt-0.5">{a.message}</div>
                        </div>
                      ))}
                    </div>
                  )}
                </div>
              </div>

              {/* 4. Nhật ký hoạt động hệ thống */}
              <div className={`p-5 rounded-2xl border ${cardBg}`}>
                <div className="flex items-center justify-between mb-3">
                  <h3 className="text-sm font-bold">📜 Nhật ký hoạt động hệ thống</h3>
                  <button
                    onClick={() => setSystemLogs([])}
                    className="text-[11px] text-slate-400 hover:text-slate-200"
                  >
                    Xóa nhật ký
                  </button>
                </div>
                <div className="space-y-1.5 max-h-48 overflow-y-auto font-mono text-xs text-slate-400">
                  {systemLogs.length === 0 ? (
                    <div className="text-slate-500">Chưa có sự kiện mới.</div>
                  ) : (
                    systemLogs.map((log, i) => (
                      <div key={i} className="py-1 border-b border-slate-800/50">
                        {log}
                      </div>
                    ))
                  )}
                </div>
              </div>
            </div>
          )}

          {/* ==================== TAB 2: PHÒNG & THIẾT BỊ ==================== */}
          {activeTab === 'rooms' && (
            <div className="space-y-6">
              {/* KHỐI 1: DANH SÁCH NGÔI NHÀ */}
              <section className={`p-5 rounded-2xl border ${cardBg}`}>
                <div className="flex flex-wrap items-center justify-between gap-3 mb-4">
                  <div>
                    <h2 className="text-sm font-bold flex items-center gap-2">
                      <span>🏡</span>
                      <span>
                        {isOwnerOrAdmin
                          ? `Quản lý Ngôi nhà (${houses.length})`
                          : `Danh sách Ngôi nhà (${houses.length})`}
                      </span>
                    </h2>
                    <p className="text-xs text-slate-400 mt-0.5">
                      Chọn nhà để lọc danh sách phòng và thiết bị bên dưới.
                    </p>
                  </div>

                  {/* CHỈ OWNER / ADMIN MỚI CÓ NÚT XUẤT / NHẬP EXCEL & THÊM NHÀ */}
                  {isOwnerOrAdmin && (
                    <div className="flex flex-wrap items-center gap-2">
                      <button
                        onClick={() => {
                          exportHousesAndRoomsToExcel(houses, rooms);
                          addLog('EXCEL EXPORT: Đã xuất danh sách Nhà & Phòng ra file .xlsx');
                        }}
                        className={`px-3 py-1.5 rounded-lg border text-xs font-bold transition ${
                          isDark
                            ? 'bg-slate-900 text-emerald-400 border-emerald-500/40 hover:bg-emerald-500/15'
                            : 'bg-emerald-50 text-emerald-700 border-emerald-300 hover:bg-emerald-100'
                        }`}
                      >
                        📤 Xuất Excel
                      </button>

                      <button
                        onClick={() => {
                          setExcelImportMode('houses_rooms');
                          setIsExcelModalOpen(true);
                        }}
                        className={`px-3 py-1.5 rounded-lg border text-xs font-bold transition ${
                          isDark
                            ? 'bg-slate-900 text-amber-400 border-amber-500/40 hover:bg-amber-500/15'
                            : 'bg-amber-50 text-amber-700 border-amber-300 hover:bg-amber-100'
                        }`}
                      >
                        📥 Nhập Excel
                      </button>

                      <button
                        onClick={openCreateHouseModal}
                        className="px-3.5 py-1.5 rounded-lg bg-cyan-500 hover:bg-cyan-400 text-slate-950 font-bold text-xs transition"
                      >
                        + Thêm Nhà
                      </button>
                    </div>
                  )}
                </div>

                <div className="flex flex-wrap gap-3">
                  <button
                    onClick={() => {
                      setSelectedHouseId(null);
                      setSelectedRoomId(null);
                    }}
                    className={`px-4 py-3 rounded-xl border text-xs font-bold transition ${
                      selectedHouseId === null
                        ? 'bg-cyan-500/15 text-cyan-400 border-cyan-500'
                        : `${subCardBg} text-slate-300`
                    }`}
                  >
                    Tất cả Nhà ({houses.length})
                  </button>

                  {houses.map((house) => {
                    const roomCount = rooms.filter((r) => r.house_id === house.id).length;
                    const isSelected = selectedHouseId === house.id;
                    return (
                      <div
                        key={house.id}
                        onClick={() => {
                          setSelectedHouseId(isSelected ? null : house.id);
                          setSelectedRoomId(null);
                        }}
                        className={`px-4 py-3 rounded-xl border cursor-pointer transition flex items-center gap-4 ${
                          isSelected
                            ? 'bg-cyan-500/15 border-cyan-500 text-cyan-300'
                            : subCardBg
                        }`}
                      >
                        <div>
                          <div className="text-xs font-bold">
                            {house.name}{' '}
                            <span className="font-normal text-slate-400">
                              ({roomCount} phòng)
                            </span>
                          </div>
                          <div className="text-[11px] text-slate-400 mt-0.5">
                            {house.address || 'Chưa cập nhật địa chỉ'}
                          </div>
                        </div>

                        {isOwnerOrAdmin && (
                          <div className="flex items-center gap-1.5">
                            <button
                              onClick={(e) => openEditHouseModal(house, e)}
                              title="Sửa ngôi nhà"
                              className="p-1.5 rounded-lg hover:bg-slate-800 text-amber-400 text-xs"
                            >
                              ✏️
                            </button>
                            <button
                              onClick={(e) => handleDeleteHouse(house, e)}
                              title="Xóa ngôi nhà"
                              className="p-1.5 rounded-lg hover:bg-slate-800 text-red-400 text-xs"
                            >
                              🗑️
                            </button>
                          </div>
                        )}
                      </div>
                    );
                  })}
                </div>
              </section>

              {/* KHỐI 2: DANH SÁCH PHÒNG */}
              <section className={`p-5 rounded-2xl border ${cardBg}`}>
                <div className="flex flex-wrap items-center justify-between gap-3 mb-4">
                  <div>
                    <h2 className="text-sm font-bold flex items-center gap-2">
                      <span>🚪</span>
                      <span>
                        {isOwnerOrAdmin
                          ? `Quản lý Phòng (${filteredRooms.length})`
                          : `Danh sách Phòng (${filteredRooms.length})`}
                      </span>
                    </h2>
                    <p className="text-xs text-slate-400 mt-0.5">
                      Nhấn vào từng phòng để xem và điều khiển thiết bị IoT bên trong phòng đó.
                    </p>
                  </div>

                  {isOwnerOrAdmin && (
                    <button
                      onClick={openCreateRoomModal}
                      className="px-3.5 py-1.5 rounded-lg bg-emerald-500 hover:bg-emerald-400 text-slate-950 font-bold text-xs transition"
                    >
                      + Thêm Phòng
                    </button>
                  )}
                </div>

                {filteredRooms.length === 0 ? (
                  <div className="text-xs text-slate-400 py-6 text-center border border-dashed border-slate-800 rounded-xl">
                    {isOwnerOrAdmin ? (
                      <>
                        Chưa có phòng nào. Nhấn <strong>+ Thêm Phòng</strong> để tạo phòng mới hoặc
                        dùng <strong>📥 Nhập Excel</strong> ở trên.
                      </>
                    ) : (
                      'Chưa có phòng nào được thiết lập trong ngôi nhà này.'
                    )}
                  </div>
                ) : (
                  <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-4">
                    {filteredRooms.map((room) => {
                      const devCount = devices.filter((d) => d.room_id === room.id).length;
                      const houseName =
                        room.house_name ||
                        houses.find((h) => h.id === room.house_id)?.name ||
                        'Nhà';
                      const isSelected = selectedRoomId === room.id;

                      return (
                        <div
                          key={room.id}
                          onClick={() => {
                            if (isSelected) {
                              setSelectedRoomId(null);
                              setDeviceFilterMode('all');
                            } else {
                              setSelectedRoomId(room.id);
                              setDeviceFilterMode('room');
                            }
                          }}
                          className={`p-4 rounded-xl border cursor-pointer transition flex flex-col justify-between gap-3 ${
                            isSelected ? 'bg-cyan-500/15 border-cyan-500' : subCardBg
                          }`}
                        >
                          <div className="flex items-start justify-between gap-2">
                            <div>
                              <div className="text-sm font-bold flex items-center gap-1.5">
                                <span>🛏️</span>
                                <span>{room.name}</span>
                              </div>
                              <div className="text-[11px] text-slate-400 mt-0.5">
                                Tầng {room.floor ?? 1} • {houseName}
                              </div>
                            </div>

                            {isOwnerOrAdmin && (
                              <div className="flex items-center gap-1">
                                <button
                                  onClick={(e) => openEditRoomModal(room, e)}
                                  title="Sửa phòng"
                                  className="p-1.5 rounded-lg bg-slate-800/80 hover:bg-slate-700 text-amber-400 text-xs"
                                >
                                  ✏️
                                </button>
                                <button
                                  onClick={(e) => handleDeleteRoom(room, e)}
                                  title="Xóa phòng"
                                  className="p-1.5 rounded-lg bg-slate-800/80 hover:bg-slate-700 text-red-400 text-xs"
                                >
                                  🗑️
                                </button>
                              </div>
                            )}
                          </div>

                          <div className="flex items-center justify-between pt-2 border-t border-slate-800/60 text-[11px]">
                            <span className="font-bold text-cyan-400">{devCount} thiết bị</span>
                            <span className="text-slate-400">
                              {isSelected ? 'Đang lọc ✓' : 'Nhấn để lọc'}
                            </span>
                          </div>
                        </div>
                      );
                    })}
                  </div>
                )}
              </section>

              {/* KHỐI 3: DANH SÁCH THIẾT BỊ IOT */}
              <section className="space-y-4">
                <div className="flex flex-wrap items-center justify-between gap-3">
                  <div className="flex flex-wrap items-center gap-2">
                    <button
                      onClick={() => {
                        setSelectedRoomId(null);
                        setDeviceFilterMode('all');
                      }}
                      className={`px-3.5 py-1.5 rounded-lg text-xs font-bold border transition ${
                        !selectedRoomId && deviceFilterMode === 'all'
                          ? 'bg-cyan-500/20 text-cyan-400 border-cyan-500/50'
                          : 'bg-slate-900 text-slate-400 border-slate-800'
                      }`}
                    >
                      Tất cả thiết bị
                    </button>

                    <button
                      onClick={() => {
                        setSelectedRoomId(null);
                        setDeviceFilterMode('unassigned');
                      }}
                      className={`px-3.5 py-1.5 rounded-lg text-xs font-bold border transition ${
                        !selectedRoomId && deviceFilterMode === 'unassigned'
                          ? 'bg-amber-500 text-slate-950 border-amber-400'
                          : 'bg-slate-900 text-amber-400 border-slate-800'
                      }`}
                    >
                      Chưa phân phòng ({unassignedDevicesCount})
                    </button>

                    {selectedRoomId && (
                      <span className="px-3 py-1.5 rounded-lg text-xs font-bold bg-emerald-500/15 text-emerald-400 border border-emerald-500/30 flex items-center gap-2">
                        <span>
                          Phòng: {rooms.find((r) => r.id === selectedRoomId)?.name}
                        </span>
                        <button
                          onClick={() => {
                            setSelectedRoomId(null);
                            setDeviceFilterMode('all');
                          }}
                          className="hover:text-white"
                        >
                          ✕
                        </button>
                      </span>
                    )}
                  </div>

                  {/* CHỈ OWNER / ADMIN ĐƯỢC XUẤT / NHẬP EXCEL THIẾT BỊ & THÊM / QUÉT THIẾT BỊ */}
                  {isOwnerOrAdmin && (
                    <div className="flex flex-wrap items-center gap-2">
                      <button
                        onClick={() => {
                          exportDevicesToExcel(devices, rooms);
                          addLog('EXCEL EXPORT: Đã xuất danh sách Thiết bị IoT ra file .xlsx');
                        }}
                        className={`px-3 py-1.5 rounded-lg border text-xs font-bold transition ${
                          isDark
                            ? 'bg-slate-900 text-emerald-400 border-emerald-500/40 hover:bg-emerald-500/15'
                            : 'bg-emerald-50 text-emerald-700 border-emerald-300 hover:bg-emerald-100'
                        }`}
                      >
                        📤 Xuất Thiết bị
                      </button>

                      <button
                        onClick={() => {
                          setExcelImportMode('devices');
                          setIsExcelModalOpen(true);
                        }}
                        className={`px-3 py-1.5 rounded-lg border text-xs font-bold transition ${
                          isDark
                            ? 'bg-slate-900 text-amber-400 border-amber-500/40 hover:bg-amber-500/15'
                            : 'bg-amber-50 text-amber-700 border-amber-300 hover:bg-amber-100'
                        }`}
                      >
                        📥 Nhập Thiết bị
                      </button>

                      <button
                        onClick={handleDiscoverWokwi}
                        className="px-3.5 py-1.5 rounded-lg bg-sky-500/15 hover:bg-sky-500/25 text-sky-400 border border-sky-500/40 font-bold text-xs transition"
                      >
                        📡 Quét Wokwi
                      </button>

                      <button
                        onClick={openCreateDeviceModal}
                        className="px-3.5 py-1.5 rounded-lg bg-cyan-500 hover:bg-cyan-400 text-slate-950 font-bold text-xs transition"
                      >
                        + Thêm thiết bị IoT
                      </button>
                    </div>
                  )}
                </div>

                <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
                  {filteredDevices.map((dev) => {
                    const isSensor = dev.device_type === 'sensor';
                    const roomLabel =
                      dev.room_name ||
                      rooms.find((r) => r.id === dev.room_id)?.name ||
                      'Chưa phân phòng';

                    const icon =
                      dev.device_type === 'fan'
                        ? '🌀'
                        : dev.device_type === 'light'
                        ? '💡'
                        : isSensor
                        ? '📡'
                        : '🔌';

                    return (
                      <div
                        key={dev.id}
                        className={`p-4 rounded-2xl border flex flex-col justify-between gap-4 ${cardBg}`}
                      >
                        <div className="flex items-start justify-between gap-3">
                          <div className="flex items-center gap-3">
                            <div className="w-11 h-11 rounded-xl bg-slate-800/90 border border-slate-700 flex items-center justify-center text-xl">
                              {icon}
                            </div>
                            <div>
                              <div className="text-xs font-bold">{dev.name}</div>
                              <div className="text-[11px] text-slate-400 mt-0.5">
                                {roomLabel} •{' '}
                                <span
                                  className={
                                    isSensor
                                      ? 'text-amber-400 font-semibold'
                                      : dev.is_on
                                      ? 'text-cyan-400 font-semibold'
                                      : 'text-slate-500'
                                  }
                                >
                                  {isSensor ? 'ONLINE' : dev.is_on ? 'ON' : 'OFF'}
                                </span>
                              </div>
                            </div>
                          </div>

                          {isSensor ? (
                            <span className="px-2 py-0.5 rounded bg-amber-500/15 text-amber-400 border border-amber-500/30 text-[10px] font-bold">
                              SENSOR
                            </span>
                          ) : (
                            <button
                              onClick={() => handleToggleDevice(dev)}
                              className={`w-11 h-6 rounded-full transition p-0.5 ${
                                dev.is_on ? 'bg-cyan-500' : 'bg-slate-700'
                              }`}
                            >
                              <div
                                className={`w-5 h-5 rounded-full bg-white transition-transform ${
                                  dev.is_on ? 'translate-x-5' : 'translate-x-0'
                                }`}
                              />
                            </button>
                          )}
                        </div>

                        <div className="flex items-center justify-between pt-3 border-t border-slate-800/70 text-[11px] text-slate-400">
                          <span className="font-mono truncate max-w-[75%]">
                            Topic: {dev.mqtt_topic}
                          </span>
                          {isOwnerOrAdmin && (
                            <div className="flex items-center gap-1">
                              <button
                                onClick={() => openEditDeviceModal(dev)}
                                title="Chỉnh sửa / Gán phòng"
                                className="p-1.5 rounded-lg bg-slate-800/80 hover:bg-slate-700 text-amber-400"
                              >
                                ✏️
                              </button>
                              <button
                                onClick={() => handleDeleteDevice(dev)}
                                title="Xóa thiết bị"
                                className="p-1.5 rounded-lg bg-slate-800/80 hover:bg-slate-700 text-red-400"
                              >
                                🗑️
                              </button>
                            </div>
                          )}
                        </div>
                      </div>
                    );
                  })}
                </div>
              </section>
            </div>
          )}

          {/* ==================== TAB 3: TỰ ĐỘNG HÓA ==================== */}
          {activeTab === 'automations' && (
            <div className="space-y-6">
              {isOwnerOrAdmin && (
                <form
                  onSubmit={handleCreateAutomation}
                  className={`p-5 rounded-2xl border grid grid-cols-1 md:grid-cols-6 gap-3 items-end ${cardBg}`}
                >
                  <div className="md:col-span-2">
                    <label className="block text-xs text-slate-400 mb-1">Tên kịch bản</label>
                    <input
                      type="text"
                      required
                      value={autoName}
                      onChange={(e) => setAutoName(e.target.value)}
                      placeholder="VD: Nóng > 30°C tự bật quạt"
                      className="w-full px-3 py-2 rounded-lg bg-slate-900 border border-slate-700 text-xs"
                    />
                  </div>
                  <div>
                    <label className="block text-xs text-slate-400 mb-1">Cảm biến</label>
                    <select
                      value={autoCondType}
                      onChange={(e) => setAutoCondType(e.target.value)}
                      className="w-full px-3 py-2 rounded-lg bg-slate-900 border border-slate-700 text-xs"
                    >
                      <option value="temperature">Nhiệt độ (°C)</option>
                      <option value="humidity">Độ ẩm (%)</option>
                      <option value="lux">Ánh sáng (Lux)</option>
                    </select>
                  </div>
                  <div className="flex gap-2">
                    <select
                      value={autoOperator}
                      onChange={(e) => setAutoOperator(e.target.value)}
                      className="w-16 px-2 py-2 rounded-lg bg-slate-900 border border-slate-700 text-xs"
                    >
                      <option value=">">&gt;</option>
                      <option value="<">&lt;</option>
                    </select>
                    <input
                      type="number"
                      value={autoThreshold}
                      onChange={(e) => setAutoThreshold(Number(e.target.value))}
                      className="w-full px-2 py-2 rounded-lg bg-slate-900 border border-slate-700 text-xs"
                    />
                  </div>
                  <div>
                    <label className="block text-xs text-slate-400 mb-1">Hành động</label>
                    <select
                      value={autoDeviceId}
                      onChange={(e) => setAutoDeviceId(e.target.value)}
                      className="w-full px-3 py-2 rounded-lg bg-slate-900 border border-slate-700 text-xs"
                    >
                      <option value="">-- Chọn thiết bị --</option>
                      {devices
                        .filter((d) => d.device_type !== 'sensor')
                        .map((d) => (
                          <option key={d.id} value={d.id}>
                            {d.name}
                          </option>
                        ))}
                    </select>
                  </div>
                  <div className="flex gap-2">
                    <select
                      value={autoAction}
                      onChange={(e) => setAutoAction(e.target.value)}
                      className="px-2 py-2 rounded-lg bg-slate-900 border border-slate-700 text-xs"
                    >
                      <option value="ON">BẬT</option>
                      <option value="OFF">TẮT</option>
                    </select>
                    <button
                      type="submit"
                      className="flex-1 py-2 px-3 rounded-lg bg-cyan-500 text-slate-950 font-bold text-xs"
                    >
                      + Thêm
                    </button>
                  </div>
                </form>
              )}

              <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
                {automations.map((rule) => {
                  const active = rule.is_active ?? rule.enabled ?? true;
                  return (
                    <div
                      key={rule.id}
                      className={`p-4 rounded-2xl border flex items-center justify-between ${cardBg}`}
                    >
                      <div>
                        <div className="text-xs font-bold">{rule.name}</div>
                        <div className="text-[11px] text-slate-400 mt-1">
                          IF {rule.condition_type || rule.trigger_type} {rule.operator || '>'}{' '}
                          {rule.threshold ?? rule.trigger_value} → THEN {rule.action || 'ON'}
                        </div>
                      </div>
                      <div className="flex items-center gap-2">
                        <button
                          disabled={!isOwnerOrAdmin}
                          onClick={() => handleToggleAutomation(rule)}
                          className={`px-2.5 py-1 rounded text-[11px] font-bold ${
                            active
                              ? 'bg-emerald-500/20 text-emerald-400'
                              : 'bg-slate-800 text-slate-400'
                          } disabled:cursor-default`}
                        >
                          {active ? 'Đang BẬT' : 'Đang TẮT'}
                        </button>
                        {isOwnerOrAdmin && (
                          <button
                            onClick={() => handleDeleteAutomation(rule.id)}
                            className="p-1.5 rounded bg-red-500/15 text-red-400 text-xs"
                          >
                            🗑️
                          </button>
                        )}
                      </div>
                    </div>
                  );
                })}
              </div>
            </div>
          )}

          {/* ==================== TAB 4: THỐNG KÊ NĂNG LƯỢNG (ĐÃ SỬA BIỂU ĐỒ) ==================== */}
          {activeTab === 'energy' && (
            <EnergyAnalyticsPanel
              isDark={isDark}
              energyData={energyData}
              devices={devices}
              rooms={rooms}
            />
          )}

          {/* ==================== TAB 5: TRÍ TUỆ NHÂN TẠO (AI) ==================== */}
          {activeTab === 'ai' && (
            <div className={`p-5 rounded-2xl border space-y-4 ${cardBg}`}>
              <div className="flex items-center justify-between">
                <h2 className="text-sm font-bold">🤖 Cảnh báo bất thường từ AI Engine</h2>
                {isOwnerOrAdmin && (
                  <button
                    onClick={handleSimulateAnomaly}
                    className="px-3.5 py-1.5 rounded-lg bg-amber-500 text-slate-950 font-bold text-xs"
                  >
                    ⚡ Mô phỏng bất thường
                  </button>
                )}
              </div>
              {aiAlerts.length === 0 ? (
                <div className="text-xs text-slate-400 py-6 text-center">
                  Hệ thống vận hành bình thường, chưa ghi nhận cảnh báo bất thường nào.
                </div>
              ) : (
                <div className="space-y-2">
                  {aiAlerts.map((a, i) => (
                    <div
                      key={a.id || i}
                      className="p-3 rounded-xl bg-red-500/10 border border-red-500/30 text-xs"
                    >
                      <div className="font-bold text-red-400">{a.title || 'Cảnh báo AI'}</div>
                      <div className="text-slate-300 mt-0.5">{a.message}</div>
                    </div>
                  ))}
                </div>
              )}
            </div>
          )}

          {/* ==================== TAB 6: QUẢN LÝ TÀI KHOẢN (CHỈ OWNER / ADMIN) ==================== */}
          {activeTab === 'accounts' && isOwnerOrAdmin && (
            <div className={`p-5 rounded-2xl border space-y-4 ${cardBg}`}>
              <div className="flex flex-wrap items-center justify-between gap-3">
                <div>
                  <h2 className="text-sm font-bold">
                    👥 Quản lý Tài khoản Người dùng ({usersList.length})
                  </h2>
                  <p className="text-xs text-slate-400 mt-0.5">
                    Thêm tài khoản thủ công hoặc nhập / xuất danh sách qua file Excel (.xlsx).
                  </p>
                </div>

                <div className="flex flex-wrap items-center gap-2">
                  <button
                    onClick={() => {
                      exportAccountsToExcel(usersList);
                      addLog('EXCEL EXPORT: Đã xuất danh sách Tài khoản ra file .xlsx');
                    }}
                    className={`px-3.5 py-2 rounded-lg border text-xs font-bold transition ${
                      isDark
                        ? 'bg-slate-900 text-emerald-400 border-emerald-500/40 hover:bg-emerald-500/15'
                        : 'bg-emerald-50 text-emerald-700 border-emerald-300 hover:bg-emerald-100'
                    }`}
                  >
                    📤 Xuất Excel
                  </button>

                  <button
                    onClick={() => {
                      setExcelImportMode('accounts');
                      setIsExcelModalOpen(true);
                    }}
                    className={`px-3.5 py-2 rounded-lg border text-xs font-bold transition ${
                      isDark
                        ? 'bg-slate-900 text-amber-400 border-amber-500/40 hover:bg-amber-500/15'
                        : 'bg-amber-50 text-amber-700 border-amber-300 hover:bg-amber-100'
                    }`}
                  >
                    📥 Nhập Excel
                  </button>

                  <button
                    onClick={() => {
                      setAccountError('');
                      setIsAccountModalOpen(true);
                    }}
                    className="px-4 py-2 bg-sky-600 hover:bg-sky-700 text-white font-bold rounded-lg text-xs transition"
                  >
                    + Tạo tài khoản mới
                  </button>
                </div>
              </div>

              <div className="overflow-x-auto rounded-xl border border-slate-800">
                <table className="w-full text-left text-xs">
                  <thead className="bg-slate-900/90 text-slate-300">
                    <tr>
                      <th className="p-3">Họ và tên</th>
                      <th className="p-3">Email</th>
                      <th className="p-3">Vai trò</th>
                      <th className="p-3 text-right">Thao tác</th>
                    </tr>
                  </thead>
                  <tbody className="divide-y divide-slate-800/70">
                    {usersList.map((u) => (
                      <tr key={u.id}>
                        <td className="p-3 font-bold">{u.name}</td>
                        <td className="p-3 font-mono text-slate-400">{u.email}</td>
                        <td className="p-3">
                          <span className="px-2 py-0.5 rounded bg-cyan-500/15 text-cyan-400 font-semibold">
                            {u.role}
                          </span>
                        </td>
                        <td className="p-3 text-right">
                          <button
                            onClick={() => handleDeleteUser(u)}
                            className="px-2.5 py-1 rounded bg-red-500/15 text-red-400 hover:bg-red-500/25"
                          >
                            Xóa
                          </button>
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            </div>
          )}
        </main>
      </div>

      {/* ==================== MODAL 1: THÊM / SỬA NGÔI NHÀ ==================== */}
      {isHouseModalOpen && isOwnerOrAdmin && (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/65 p-4">
          <form
            onSubmit={handleSaveHouse}
            className={`w-full max-w-md rounded-2xl border p-6 shadow-2xl space-y-4 ${cardBg}`}
          >
            <h3 className="text-sm font-bold flex items-center gap-2">
              <span>🏡</span>
              <span>{editingHouse ? 'Cập nhật Ngôi nhà' : 'Thêm Ngôi nhà Mới'}</span>
            </h3>

            {houseError && (
              <div className="p-3 rounded-lg bg-red-500/15 border border-red-500/40 text-red-400 text-xs">
                {houseError}
              </div>
            )}

            <div>
              <label className="block text-xs font-semibold mb-1.5">Tên ngôi nhà *</label>
              <input
                type="text"
                required
                value={houseNameInput}
                onChange={(e) => setHouseNameInput(e.target.value)}
                placeholder="VD: Nhà Chính Quận 1"
                className="w-full px-3.5 py-2.5 rounded-xl bg-slate-900 border border-slate-700 text-xs focus:outline-none focus:border-cyan-500"
              />
            </div>

            <div>
              <label className="block text-xs font-semibold mb-1.5">Địa chỉ</label>
              <input
                type="text"
                value={houseAddressInput}
                onChange={(e) => setHouseAddressInput(e.target.value)}
                placeholder="VD: 111 Lê Trọng Tấn"
                className="w-full px-3.5 py-2.5 rounded-xl bg-slate-900 border border-slate-700 text-xs focus:outline-none focus:border-cyan-500"
              />
            </div>

            <div className="flex justify-end gap-2 pt-2">
              <button
                type="button"
                onClick={() => setIsHouseModalOpen(false)}
                className="px-4 py-2 rounded-lg border border-slate-700 text-xs font-semibold"
              >
                Hủy
              </button>
              <button
                type="submit"
                disabled={houseSaving}
                className="px-4 py-2 rounded-lg bg-cyan-500 hover:bg-cyan-400 text-slate-950 font-bold text-xs disabled:opacity-50"
              >
                {houseSaving ? 'Đang lưu...' : editingHouse ? 'Lưu thay đổi' : 'Tạo nhà'}
              </button>
            </div>
          </form>
        </div>
      )}

      {/* ==================== MODAL 2: THÊM / SỬA PHÒNG ==================== */}
      {isRoomModalOpen && isOwnerOrAdmin && (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/65 p-4">
          <form
            onSubmit={handleSaveRoom}
            className={`w-full max-w-md rounded-2xl border p-6 shadow-2xl space-y-4 ${cardBg}`}
          >
            <h3 className="text-sm font-bold flex items-center gap-2">
              <span>🚪</span>
              <span>{editingRoom ? 'Cập nhật Phòng' : 'Thêm Phòng Mới'}</span>
            </h3>

            {roomError && (
              <div className="p-3 rounded-lg bg-red-500/15 border border-red-500/40 text-red-400 text-xs">
                {roomError}
              </div>
            )}

            <div>
              <label className="block text-xs font-semibold mb-1.5">Ngôi nhà trực thuộc *</label>
              <select
                required
                value={roomHouseIdInput}
                onChange={(e) => setRoomHouseIdInput(e.target.value)}
                className="w-full px-3.5 py-2.5 rounded-xl bg-slate-900 border border-slate-700 text-xs focus:outline-none focus:border-cyan-500"
              >
                {houses.map((h) => (
                  <option key={h.id} value={h.id}>
                    {h.name}
                  </option>
                ))}
              </select>
            </div>

            <div>
              <label className="block text-xs font-semibold mb-1.5">Tên phòng *</label>
              <input
                type="text"
                required
                value={roomNameInput}
                onChange={(e) => setRoomNameInput(e.target.value)}
                placeholder="VD: Phòng Khách, Phòng Ngủ..."
                className="w-full px-3.5 py-2.5 rounded-xl bg-slate-900 border border-slate-700 text-xs focus:outline-none focus:border-cyan-500"
              />
            </div>

            <div>
              <label className="block text-xs font-semibold mb-1.5">Tầng</label>
              <input
                type="number"
                min={0}
                max={50}
                value={roomFloorInput}
                onChange={(e) => setRoomFloorInput(Number(e.target.value))}
                className="w-full px-3.5 py-2.5 rounded-xl bg-slate-900 border border-slate-700 text-xs focus:outline-none focus:border-cyan-500"
              />
            </div>

            <div className="flex justify-end gap-2 pt-2">
              <button
                type="button"
                onClick={() => setIsRoomModalOpen(false)}
                className="px-4 py-2 rounded-lg border border-slate-700 text-xs font-semibold"
              >
                Hủy
              </button>
              <button
                type="submit"
                disabled={roomSaving}
                className="px-4 py-2 rounded-lg bg-emerald-500 hover:bg-emerald-400 text-slate-950 font-bold text-xs disabled:opacity-50"
              >
                {roomSaving ? 'Đang lưu...' : editingRoom ? 'Lưu phòng' : 'Tạo phòng'}
              </button>
            </div>
          </form>
        </div>
      )}

      {/* ==================== MODAL 3: THÊM / SỬA THIẾT BỊ IOT ==================== */}
      {isDeviceModalOpen && isOwnerOrAdmin && (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/65 p-4">
          <form
            onSubmit={handleSaveDevice}
            className={`w-full max-w-md rounded-2xl border p-6 shadow-2xl space-y-4 ${cardBg}`}
          >
            <h3 className="text-sm font-bold flex items-center gap-2">
              <span>🔌</span>
              <span>{editingDevice ? 'Cập nhật Thiết bị IoT' : 'Thêm Thiết bị IoT Mới'}</span>
            </h3>

            {devError && (
              <div className="p-3 rounded-lg bg-red-500/15 border border-red-500/40 text-red-400 text-xs">
                {devError}
              </div>
            )}

            <div>
              <label className="block text-xs font-semibold mb-1.5">Tên thiết bị *</label>
              <input
                type="text"
                required
                value={devNameInput}
                onChange={(e) => setDevNameInput(e.target.value)}
                placeholder="VD: Đèn Phòng Khách"
                className="w-full px-3.5 py-2.5 rounded-xl bg-slate-900 border border-slate-700 text-xs"
              />
            </div>

            <div>
              <label className="block text-xs font-semibold mb-1.5">Loại thiết bị</label>
              <select
                value={devTypeInput}
                onChange={(e) => setDevTypeInput(e.target.value)}
                className="w-full px-3.5 py-2.5 rounded-xl bg-slate-900 border border-slate-700 text-xs"
              >
                <option value="light">Đèn chiếu sáng (Light)</option>
                <option value="fan">Quạt / Điều hòa (Fan)</option>
                <option value="switch">Công tắc thông minh (Switch)</option>
                <option value="sensor">Cảm biến môi trường (Sensor)</option>
              </select>
            </div>

            <div>
              <label className="block text-xs font-semibold mb-1.5">Phòng trực thuộc</label>
              <select
                value={devRoomIdInput}
                onChange={(e) => setDevRoomIdInput(e.target.value)}
                className="w-full px-3.5 py-2.5 rounded-xl bg-slate-900 border border-slate-700 text-xs"
              >
                <option value="">-- Chưa phân phòng --</option>
                {rooms.map((r) => {
                  const hName =
                    r.house_name || houses.find((h) => h.id === r.house_id)?.name || '';
                  return (
                    <option key={r.id} value={r.id}>
                      {r.name} (Tầng {r.floor ?? 1}
                      {hName ? ` — ${hName}` : ''})
                    </option>
                  );
                })}
              </select>
            </div>

            <div>
              <label className="block text-xs font-semibold mb-1.5">MQTT Topic *</label>
              <input
                type="text"
                required
                value={devTopicInput}
                onChange={(e) => setDevTopicInput(e.target.value)}
                placeholder="smarthome/devices/led_phong_khach"
                className="w-full px-3.5 py-2.5 rounded-xl bg-slate-900 border border-slate-700 text-xs font-mono"
              />
            </div>

            <div className="flex justify-end gap-2 pt-2">
              <button
                type="button"
                onClick={() => setIsDeviceModalOpen(false)}
                className="px-4 py-2 rounded-lg border border-slate-700 text-xs font-semibold"
              >
                Hủy
              </button>
              <button
                type="submit"
                disabled={devSaving}
                className="px-4 py-2 rounded-lg bg-cyan-500 hover:bg-cyan-400 text-slate-950 font-bold text-xs disabled:opacity-50"
              >
                {devSaving ? 'Đang lưu...' : 'Lưu thiết bị'}
              </button>
            </div>
          </form>
        </div>
      )}

      {/* ==================== MODAL 4: QUÉT THIẾT BỊ WOKWI ==================== */}
      {isDiscoverModalOpen && isOwnerOrAdmin && (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/65 p-4">
          <div className={`w-full max-w-lg rounded-2xl border p-6 shadow-2xl space-y-4 ${cardBg}`}>
            <div className="flex justify-between items-center">
              <h3 className="text-sm font-bold">📡 Quét thiết bị ESP32 Wokwi</h3>
              <button
                onClick={() => setIsDiscoverModalOpen(false)}
                className="text-xs text-slate-400"
              >
                ✕
              </button>
            </div>

            {isDiscovering ? (
              <div className="py-6 text-center text-xs text-slate-400">
                Đang gửi gói tin Discovery qua MQTT Broker...
              </div>
            ) : discoveredList.length === 0 ? (
              <div className="py-6 text-center text-xs text-slate-400">
                Tất cả thiết bị Wokwi đã được thêm vào hệ thống.
              </div>
            ) : (
              <div className="space-y-2.5">
                {discoveredList.map((item, idx) => (
                  <div
                    key={idx}
                    className={`p-3 rounded-xl border flex items-center justify-between ${subCardBg}`}
                  >
                    <div>
                      <div className="text-xs font-bold">{item.name}</div>
                      <div className="text-[11px] font-mono text-slate-400">
                        {item.mqtt_topic}
                      </div>
                    </div>
                    <button
                      onClick={() => handleAddDiscoveredDevice(item)}
                      className="px-3 py-1.5 rounded-lg bg-cyan-500 text-slate-950 font-bold text-xs"
                    >
                      + Kết nối
                    </button>
                  </div>
                ))}
              </div>
            )}
          </div>
        </div>
      )}

      {/* ==================== MODAL 5: TẠO TÀI KHOẢN THỦ CÔNG ==================== */}
      {isAccountModalOpen && isOwnerOrAdmin && (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/65 p-4">
          <form
            onSubmit={handleCreateAccountManual}
            className={`w-full max-w-md rounded-2xl border p-6 shadow-2xl space-y-4 ${cardBg}`}
          >
            <h3 className="text-sm font-bold">👤 Tạo Tài khoản Mới</h3>

            {accountError && (
              <div className="p-3 rounded-lg bg-red-500/15 border border-red-500/40 text-red-400 text-xs">
                {accountError}
              </div>
            )}

            <div>
              <label className="block text-xs font-semibold mb-1.5">Họ và tên *</label>
              <input
                type="text"
                required
                value={accNameInput}
                onChange={(e) => setAccNameInput(e.target.value)}
                className="w-full px-3.5 py-2.5 rounded-xl bg-slate-900 border border-slate-700 text-xs"
              />
            </div>

            <div>
              <label className="block text-xs font-semibold mb-1.5">Email *</label>
              <input
                type="email"
                required
                value={accEmailInput}
                onChange={(e) => setAccEmailInput(e.target.value)}
                className="w-full px-3.5 py-2.5 rounded-xl bg-slate-900 border border-slate-700 text-xs"
              />
            </div>

            <div>
              <label className="block text-xs font-semibold mb-1.5">Mật khẩu *</label>
              <input
                type="password"
                required
                value={accPasswordInput}
                onChange={(e) => setAccPasswordInput(e.target.value)}
                className="w-full px-3.5 py-2.5 rounded-xl bg-slate-900 border border-slate-700 text-xs"
              />
            </div>

            <div>
              <label className="block text-xs font-semibold mb-1.5">Vai trò</label>
              <select
                value={accRoleInput}
                onChange={(e) => setAccRoleInput(e.target.value as UserRole)}
                className="w-full px-3.5 py-2.5 rounded-xl bg-slate-900 border border-slate-700 text-xs"
              >
                <option value="Member">Member</option>
                <option value="Guest">Guest</option>
                <option value="Admin">Admin</option>
              </select>
            </div>

            <div className="flex justify-end gap-2 pt-2">
              <button
                type="button"
                onClick={() => setIsAccountModalOpen(false)}
                className="px-4 py-2 rounded-lg border border-slate-700 text-xs font-semibold"
              >
                Hủy
              </button>
              <button
                type="submit"
                disabled={accountSaving}
                className="px-4 py-2 rounded-lg bg-sky-600 hover:bg-sky-700 text-white font-bold text-xs disabled:opacity-50"
              >
                {accountSaving ? 'Đang tạo...' : 'Tạo tài khoản'}
              </button>
            </div>
          </form>
        </div>
      )}

      {/* ==================== MODAL 6: NHẬP DỮ LIỆU EXCEL (.XLSX) ==================== */}
      {isOwnerOrAdmin && (
        <ExcelImportModal
          isOpen={isExcelModalOpen}
          isDark={isDark}
          mode={excelImportMode}
          houses={houses}
          rooms={rooms}
          devices={devices}
          users={usersList}
          ownerId={
            currentUser?.id ||
            usersList.find(
              (u) => u.email.toLowerCase() === (currentUser?.email ?? '').toLowerCase()
            )?.id ||
            usersList[0]?.id ||
            ''
          }
          onClose={() => setIsExcelModalOpen(false)}
          onSuccess={async (msg) => {
            addLog(msg);
            await fetchAllDatabaseData();
          }}
        />
      )}
    </div>
  );
}

export default App;