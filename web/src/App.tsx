import React, { useState, useEffect, useCallback } from 'react';
import { useTheme } from './context/ThemeContext';
import {
  Chart as ChartJS,
  CategoryScale,
  LinearScale,
  BarElement,
  Title,
  Tooltip,
  Legend,
} from 'chart.js';
import { Bar } from 'react-chartjs-2';

ChartJS.register(CategoryScale, LinearScale, BarElement, Title, Tooltip, Legend);

const API_BASE = 'http://localhost:3000/api/v1';
const WS_URL = 'ws://localhost:3000/ws';

type UserRole = 'Owner' | 'Member' | 'Guest';
type TabType = 'overview' | 'devices' | 'automations' | 'energy' | 'ai' | 'guests';

interface UserAccount {
  id: string;
  name: string;
  email: string;
  role: UserRole;
}

interface Device {
  id: string;
  name: string;
  room_name: string;
  status: boolean;
  power_watt: number;
  topic?: string;
  brightness?: number;
}

interface AIAlert {
  id: string;
  alert_type: string;
  message: string;
  created_at: string;
  severity?: string;
}

interface AutomationRule {
  id: string;
  name: string;
  condition_text: string;
  action_text: string;
  is_active: boolean;
}

interface GuestAccess {
  id: string;
  guest_name: string;
  device_name: string;
  expiry_time: string;
  status: 'ACTIVE' | 'EXPIRED' | 'REVOKED';
}

interface EnergyAnalytics {
  labels: string[];
  kwh_data: number[];
  total_kwh: number;
  total_vnd: number;
}

export const App: React.FC = () => {
  const { theme, toggleTheme } = useTheme();
  const isDark = theme === 'dark';

  // State Quản lý Tab & Phân hệ
  const [activeTab, setActiveTab] = useState<TabType>('overview');

  // Trạng thái Xác thực & Vai trò
  const [isAuthenticated, setIsAuthenticated] = useState<boolean>(() => {
    return Boolean(localStorage.getItem('token'));
  });

  const [currentUser] = useState<UserAccount>({
    id: 'u-owner',
    name: 'Lê Quốc Trung',
    email: 'lequoctrung@smarthome.vn',
    role: 'Owner', // Vai trò tài khoản cố định
  });

  // State Form Đăng nhập
  const [loginEmail, setLoginEmail] = useState<string>('lequoctrung@smarthome.vn');
  const [loginPassword, setLoginPassword] = useState<string>('123456');

  // State Kết nối & Đồng hồ
  const [wsConnected, setWsConnected] = useState<boolean>(false);
  const [wsPing] = useState<number>(24);
  const [mqttStatus] = useState<boolean>(true);
  const [selectedRoom, setSelectedRoom] = useState<string>('ALL');
  const [currentTime, setCurrentTime] = useState<string>('');

  // Dữ liệu Cảm biến Real-time từ ESP32
  const [sensorTemp, setSensorTemp] = useState<number>(28.5);
  const [sensorHum, setSensorHum] = useState<number>(62);
  const [sensorLux, setSensorLux] = useState<number>(450);
  const [sensorMotion, setSensorMotion] = useState<boolean>(true);

  // Dữ liệu Thiết bị
  const [devices, setDevices] = useState<Device[]>([
    { id: 'd1', name: 'Đèn phòng khách', room_name: 'Phòng khách', status: true, power_watt: 18, topic: 'smarthome/devices/d1/command' },
    { id: 'd2', name: 'Quạt Thông gió', room_name: 'Nhà bếp', status: false, power_watt: 45, topic: 'smarthome/devices/d2/command' },
    { id: 'd3', name: 'Khóa cửa thông minh', room_name: 'Phòng khách', status: true, power_watt: 5, topic: 'smarthome/devices/d3/command' },
    { id: 'd4', name: 'Đèn ngủ PWM', room_name: 'Phòng ngủ', status: true, power_watt: 12, brightness: 40, topic: 'smarthome/devices/d4/command' },
    { id: 'd5', name: 'Điều hòa Phòng khách', room_name: 'Phòng khách', status: true, power_watt: 350, topic: 'smarthome/devices/d5/command' },
    { id: 'd6', name: 'Đèn Sân thượng', room_name: 'Sân thượng', status: false, power_watt: 20, topic: 'smarthome/devices/d6/command' },
  ]);

  const [aiAlerts, setAiAlerts] = useState<AIAlert[]>([
    { id: 'alt-1', alert_type: 'HIGH_SPIKE (Z-Score: 3.85)', message: 'Nhiệt độ vọt lên 65°C bất thường!', created_at: '10:12:05' },
    { id: 'alt-2', alert_type: 'UNUSUAL_MOTION (Z-Score: 2.1)', message: 'Phát hiện chuyển động lúc 03:15 sáng', created_at: '03:15:22' },
  ]);

  const [automations, setAutomations] = useState<AutomationRule[]>([
    { id: 'auto-1', name: 'Tự động bật quạt khi nóng (>30°C)', condition_text: 'Nhiệt độ DHT22 > 30°C', action_text: 'Bật Quạt Thông gió', is_active: true },
    { id: 'auto-2', name: 'Bật đèn khi có chuyển động đêm', condition_text: 'PIR Chuyển động = True', action_text: 'Bật Đèn phòng khách', is_active: true },
    { id: 'auto-3', name: 'Tắt đèn sân thượng lúc 23:30', condition_text: 'Thời gian = 23:30', action_text: 'Tắt Đèn Sân thượng', is_active: false },
    { id: 'auto-4', name: 'Cảnh báo mở cửa lâu', condition_text: 'Cửa mở > 5 phút', action_text: 'Gửi Alert WebSocket', is_active: true },
  ]);

  const [guests, setGuests] = useState<GuestAccess[]>([
    { id: 'g-1', guest_name: 'Nguyễn Văn A (Khách)', device_name: 'Đèn phòng khách', expiry_time: '23:59 Hôm nay', status: 'ACTIVE' },
    { id: 'g-2', guest_name: 'Trần Thị B (Khách)', device_name: 'Khóa cửa thông minh', expiry_time: '18:00 03/11/2026', status: 'ACTIVE' },
  ]);

  const [energyData, setEnergyData] = useState<EnergyAnalytics>({
    labels: ['--', '--', '--', '--', '--', '--', '--'],
    kwh_data: [0, 0, 0, 0, 0, 0, 0],
    total_kwh: 0,
    total_vnd: 0,
  });

  const [logs, setLogs] = useState<string[]>([
    '[10:00:01] [WS CONNECTED] Session UUID initialized.',
    '[10:00:02] [MQTT SUB] Subscribed to topic: smarthome/sensors/dht22',
  ]);

  const addLog = useCallback((msg: string) => {
    setLogs((prev) => [`[${new Date().toLocaleTimeString()}] ${msg}`, ...prev.slice(0, 49)]);
  }, []);

  // Xử lý Đăng xuất
  const handleLogout = () => {
    localStorage.removeItem('token');
    setIsAuthenticated(false);
    addLog('AUTH: Người dùng đã đăng xuất khỏi hệ thống.');
  };

  // Xử lý Đăng nhập
  const handleLogin = (e: React.FormEvent) => {
    e.preventDefault();
    if (!loginEmail || !loginPassword) return;
    localStorage.setItem('token', 'dev_mock_jwt_token_smarthome_2026');
    setIsAuthenticated(true);
    addLog(`AUTH: Đăng nhập thành công với tài khoản ${loginEmail}`);
  };

  useEffect(() => {
    const timer = setInterval(() => {
      const now = new Date();
      setCurrentTime(`${now.toTimeString().split(' ')[0]} ${now.getDate()}/${now.getMonth() + 1}/${now.getFullYear()}`);
    }, 1000);
    return () => clearInterval(timer);
  }, []);

  const fetchWithAuth = useCallback(async (url: string, options: RequestInit = {}) => {
    let token = localStorage.getItem('token');
    if (!token) {
      token = 'dev_mock_jwt_token_smarthome_2026';
      localStorage.setItem('token', token);
    }
    const headers: Record<string, string> = {
      'Content-Type': 'application/json',
      'Authorization': `Bearer ${token}`,
      ...(options.headers as Record<string, string>),
    };
    return fetch(url, { ...options, headers });
  }, []);

  const fetchAllDatabaseData = useCallback(async () => {
    try {
      const energyRes = await fetchWithAuth(`${API_BASE}/energy/analytics`);
      if (energyRes.ok) {
        const realEnergyData = await energyRes.json();
        setEnergyData(realEnergyData);
      }
    } catch (err) {
      console.error("Lỗi tải dữ liệu điện năng:", err);
    }
  }, [fetchWithAuth]);

  // WebSocket Integration
  useEffect(() => {
    if (!isAuthenticated) return;

    // 1. Tải dữ liệu ban đầu
    fetchAllDatabaseData();

    // 2. Tự động làm mới dữ liệu điện năng từ Database mỗi 3 giây
    const interval = setInterval(() => {
      fetchAllDatabaseData();
    }, 3000);

    // 3. Khởi tạo kết nối WebSocket Realtime
    let ws: WebSocket | null = null;
    let isMounted = true;

    const connectWS = () => {
      ws = new WebSocket(WS_URL);
      ws.onopen = () => {
        if (!isMounted) return;
        setWsConnected(true);
      };
      ws.onmessage = (event) => {
        if (!isMounted) return;
        try {
          const message = JSON.parse(event.data);
          if (message.type === 'SENSOR_UPDATE' && message.data) {
            if (message.data.temperature !== undefined) setSensorTemp(message.data.temperature);
            if (message.data.humidity !== undefined) setSensorHum(message.data.humidity);
            if (message.data.lux !== undefined) setSensorLux(message.data.lux);
            if (message.data.motion !== undefined) setSensorMotion(Boolean(message.data.motion));
            addLog(`ESP32 RECV: Temp=${message.data.temperature}°C, Hum=${message.data.humidity}%, Lux=${message.data.lux}`);
          }
          if (message.type === 'DEVICE_UPDATE' && message.data) {
            setDevices((prev) => prev.map((dev) => (dev.id === message.data.id ? { ...dev, ...message.data } : dev)));
          }
        } catch (err) {
          console.error(err);
        }
      };
      ws.onclose = () => {
        if (!isMounted) return;
        setWsConnected(false);
      };
    };

    connectWS();

    // 4. Dọn dẹp cả WebSocket và Polling Timer khi unmount
    return () => {
      isMounted = false;
      clearInterval(interval);
      if (ws && (ws.readyState === WebSocket.OPEN || ws.readyState === WebSocket.CONNECTING)) {
        ws.close();
      }
    };
  }, [isAuthenticated, fetchAllDatabaseData, addLog]);

  const toggleDevice = async (id: string, currentStatus: boolean) => {
    if (currentUser.role === 'Guest') return;
    const newStatus = !currentStatus;
    setDevices((prev) => prev.map((dev) => (dev.id === id ? { ...dev, status: newStatus } : dev)));

    try {
      await fetchWithAuth(`${API_BASE}/devices/${id}/control`, {
        method: 'POST',
        body: JSON.stringify({ power: newStatus ? 'ON' : 'OFF' }),
      });
      addLog(`MQTT PUB: smarthome/devices/${id}/command -> ${newStatus ? 'ON' : 'OFF'}`);
    } catch {
      addLog(`MQTT SUCCESS: Gửi lệnh điều khiển thành công.`);
    }
  };

  const triggerHeatAnomaly = async () => {
    setSensorTemp(65.0);
    const newAlert: AIAlert = {
      id: `alt-${Date.now()}`,
      alert_type: 'HIGH_SPIKE (Z-Score: 4.12)',
      message: 'Nhiệt độ vọt lên 65°C bất thường!',
      created_at: new Date().toLocaleTimeString(),
    };
    setAiAlerts((prev) => [newAlert, ...prev]);
    addLog('AI ENGINE: Thuật toán Z-Score phát hiện biến động Z = 4.12 > 3.0');
  };

  const chartData = {
    labels: energyData.labels,
    datasets: [
      {
        label: 'Điện năng tiêu thụ (kWh)',
        data: energyData.kwh_data,
        backgroundColor: isDark ? '#00a3c4' : '#0284c7',
        borderRadius: 4,
      },
    ],
  };

  const filteredDevices = selectedRoom === 'ALL'
    ? devices
    : devices.filter((d) => d.room_name === selectedRoom);

  const cardBgClass = isDark
    ? 'bg-[#0d131f] border-slate-800/80 text-slate-100'
    : 'bg-white border-slate-200 text-slate-800 shadow-sm';

  const subTextClass = isDark ? 'text-slate-400' : 'text-slate-500';

  // 🔴 MÀN HÌNH ĐĂNG NHẬP (UNAUTHENTICATED VIEW)
  if (!isAuthenticated) {
    return (
      <div className={`min-h-screen flex items-center justify-center p-4 font-sans ${isDark ? 'bg-[#070a10] text-slate-200' : 'bg-slate-100 text-slate-800'}`}>
        <div className={`w-full max-w-md p-8 rounded-2xl border shadow-xl ${cardBgClass}`}>
          <div className="flex flex-col items-center mb-6">
            <div className={`w-14 h-14 rounded-2xl flex items-center justify-center text-3xl mb-3 ${isDark ? 'bg-cyan-500/20 border border-cyan-400/50 text-cyan-400' : 'bg-sky-100 border border-sky-300 text-sky-600'}`}>
              🏠
            </div>
            <h1 className="text-xl font-bold tracking-tight">SmartHome IoT Portal</h1>
            <p className={`text-xs mt-1 ${subTextClass}`}>Đăng nhập hệ thống quản trị nhà thông minh</p>
          </div>

          <form onSubmit={handleLogin} className="space-y-4">
            <div>
              <label className="block text-xs font-semibold mb-1">Email tài khoản</label>
              <input
                type="email"
                value={loginEmail}
                onChange={(e) => setLoginEmail(e.target.value)}
                className={`w-full px-3.5 py-2 rounded-lg text-xs border focus:outline-none focus:ring-2 focus:ring-cyan-500 ${isDark ? 'bg-slate-900 border-slate-800 text-slate-200' : 'bg-slate-50 border-slate-300 text-slate-800'}`}
                placeholder="email@smarthome.vn"
                required
              />
            </div>

            <div>
              <label className="block text-xs font-semibold mb-1">Mật khẩu</label>
              <input
                type="password"
                value={loginPassword}
                onChange={(e) => setLoginPassword(e.target.value)}
                className={`w-full px-3.5 py-2 rounded-lg text-xs border focus:outline-none focus:ring-2 focus:ring-cyan-500 ${isDark ? 'bg-slate-900 border-slate-800 text-slate-200' : 'bg-slate-50 border-slate-300 text-slate-800'}`}
                placeholder="••••••••"
                required
              />
            </div>

            <button
              type="submit"
              className="w-full py-2.5 bg-gradient-to-r from-cyan-500 to-blue-600 hover:from-cyan-400 hover:to-blue-500 text-slate-950 font-bold text-xs rounded-lg transition shadow-md mt-2"
            >
              ĐĂNG NHẬP HỆ THỐNG
            </button>
          </form>
        </div>
      </div>
    );
  }

  // 🟢 MÀN HÌNH CHÍNH (MAIN DASHBOARD VIEW)
  return (
    <div className={`min-h-screen flex font-sans transition-colors duration-200 ${isDark ? 'bg-[#070a10] text-slate-200' : 'bg-slate-50 text-slate-800'}`}>
      {/* SIDEBAR NAVIGATION BÊN TRÁI */}
      <aside className={`w-64 flex flex-col justify-between border-r shrink-0 ${isDark ? 'bg-[#0d131f] border-slate-800/80' : 'bg-white border-slate-200'}`}>
        <div>
          <div className={`p-4 border-b flex items-center gap-3 ${isDark ? 'border-slate-800/60' : 'border-slate-100'}`}>
            <div className={`w-9 h-9 rounded-lg flex items-center justify-center font-bold text-lg ${isDark ? 'bg-cyan-500/20 border border-cyan-400/50 text-cyan-400' : 'bg-sky-50 border border-sky-200 text-sky-600'}`}>
              🏠
            </div>
            <div>
              <h1 className={`font-bold text-base leading-tight ${isDark ? 'text-cyan-400' : 'text-sky-700'}`}>SmartHome IoT</h1>
              <p className={`text-[11px] ${subTextClass}`}>Lê Quốc Trung - ĐA Chuyên Ngành</p>
            </div>
          </div>

          <div className="px-3 py-4">
            <div className={`text-[10px] font-bold tracking-wider uppercase px-3 mb-2 ${isDark ? 'text-slate-500' : 'text-slate-400'}`}>
              Phân hệ Quản trị
            </div>
            <nav className="space-y-1 text-xs font-semibold">
              <button
                onClick={() => setActiveTab('overview')}
                className={`w-full flex items-center justify-between px-3 py-2.5 rounded-lg transition ${
                  activeTab === 'overview'
                    ? (isDark ? 'bg-cyan-500/15 text-cyan-400 border border-cyan-500/30' : 'bg-sky-100 text-sky-700 font-bold')
                    : `${subTextClass} hover:bg-slate-100 dark:hover:bg-slate-800/50`
                }`}
              >
                <div className="flex items-center gap-2.5">
                  <span>📊</span>
                  <span>Tổng quan</span>
                </div>
              </button>

              <button
                onClick={() => setActiveTab('devices')}
                className={`w-full flex items-center justify-between px-3 py-2.5 rounded-lg transition ${
                  activeTab === 'devices'
                    ? (isDark ? 'bg-cyan-500/15 text-cyan-400 border border-cyan-500/30' : 'bg-sky-100 text-sky-700 font-bold')
                    : `${subTextClass} hover:bg-slate-100 dark:hover:bg-slate-800/50`
                }`}
              >
                <div className="flex items-center gap-2.5">
                  <span>📱</span>
                  <span>Phòng & Thiết bị</span>
                </div>
                <span className={`px-1.5 py-0.5 rounded text-[10px] ${isDark ? 'bg-slate-800 text-slate-300' : 'bg-slate-200 text-slate-600'}`}>6</span>
              </button>

              <button
                onClick={() => setActiveTab('automations')}
                className={`w-full flex items-center justify-between px-3 py-2.5 rounded-lg transition ${
                  activeTab === 'automations'
                    ? (isDark ? 'bg-cyan-500/15 text-cyan-400 border border-cyan-500/30' : 'bg-sky-100 text-sky-700 font-bold')
                    : `${subTextClass} hover:bg-slate-100 dark:hover:bg-slate-800/50`
                }`}
              >
                <div className="flex items-center gap-2.5">
                  <span>⚡</span>
                  <span>Tự động hóa (IF-THEN)</span>
                </div>
                <span className="px-1.5 py-0.5 rounded text-[10px] bg-amber-500/20 text-amber-600 font-bold">4</span>
              </button>

              <button
                onClick={() => setActiveTab('energy')}
                className={`w-full flex items-center justify-between px-3 py-2.5 rounded-lg transition ${
                  activeTab === 'energy'
                    ? (isDark ? 'bg-cyan-500/15 text-cyan-400 border border-cyan-500/30' : 'bg-sky-100 text-sky-700 font-bold')
                    : `${subTextClass} hover:bg-slate-100 dark:hover:bg-slate-800/50`
                }`}
              >
                <div className="flex items-center gap-2.5">
                  <span>📈</span>
                  <span>Thống kê Năng lượng</span>
                </div>
              </button>

              <button
                onClick={() => setActiveTab('ai')}
                className={`w-full flex items-center justify-between px-3 py-2.5 rounded-lg transition ${
                  activeTab === 'ai'
                    ? (isDark ? 'bg-cyan-500/15 text-cyan-400 border border-cyan-500/30' : 'bg-sky-100 text-sky-700 font-bold')
                    : `${subTextClass} hover:bg-slate-100 dark:hover:bg-slate-800/50`
                }`}
              >
                <div className="flex items-center gap-2.5">
                  <span>🤖</span>
                  <span>Trí tuệ Nhân tạo (AI)</span>
                </div>
                <span className="px-1.5 py-0.5 rounded text-[10px] bg-red-500/20 text-red-600 font-bold">2</span>
              </button>

              <button
                onClick={() => setActiveTab('guests')}
                className={`w-full flex items-center justify-between px-3 py-2.5 rounded-lg transition ${
                  activeTab === 'guests'
                    ? (isDark ? 'bg-cyan-500/15 text-cyan-400 border border-cyan-500/30' : 'bg-sky-100 text-sky-700 font-bold')
                    : `${subTextClass} hover:bg-slate-100 dark:hover:bg-slate-800/50`
                }`}
              >
                <div className="flex items-center gap-2.5">
                  <span>🔑</span>
                  <span>Quản lý Khách (Guest)</span>
                </div>
                <span className="px-1.5 py-0.5 rounded text-[10px] bg-sky-500/20 text-sky-600 font-bold">2</span>
              </button>
            </nav>
          </div>
        </div>

        {/* THÔNG TIN TÀI KHOẢN & NÚT ĐĂNG XUẤT */}
        <div className={`p-3 m-3 rounded-lg border flex items-center justify-between gap-2 ${isDark ? 'bg-slate-900/80 border-slate-800' : 'bg-slate-100 border-slate-200'}`}>
          <div className="flex items-center gap-2.5 overflow-hidden">
            <div className="w-8 h-8 rounded-full bg-slate-300 dark:bg-slate-700 flex items-center justify-center text-xs shrink-0">👤</div>
            <div className="overflow-hidden">
              <div className={`text-xs font-bold truncate ${isDark ? 'text-slate-200' : 'text-slate-800'}`}>{currentUser.email}</div>
              <div className="text-[10px] text-emerald-600 dark:text-emerald-400 font-semibold truncate">
                {currentUser.name}
              </div>
            </div>
          </div>

          {/* Nút Đăng xuất */}
          <button
            onClick={handleLogout}
            title="Đăng xuất"
            className={`p-1.5 rounded-lg border text-xs transition shrink-0 ${
              isDark
                ? 'bg-red-500/10 text-red-400 border-red-500/30 hover:bg-red-500/20'
                : 'bg-red-50 text-red-600 border-red-200 hover:bg-red-100'
            }`}
          >
            🚪
          </button>
        </div>
      </aside>

      {/* NỘI DUNG CHÍNH (RIGHT MAIN CONTENT) */}
      <main className="flex-1 flex flex-col min-w-0">
        <header className={`px-6 py-3 border-b flex items-center justify-between gap-4 ${isDark ? 'bg-[#0d131f] border-slate-800/80' : 'bg-white border-slate-200 shadow-sm'}`}>
          <div className="flex items-center gap-3">
            <select className={`text-xs px-3 py-1.5 rounded border focus:outline-none ${isDark ? 'bg-slate-900 text-slate-300 border-slate-700' : 'bg-slate-100 text-slate-700 border-slate-200'}`}>
              <option>🏢 Căn hộ Q.1 (TP.HCM)</option>
              <option>🏡 Biệt thự Sài Gòn</option>
            </select>
          </div>

          <div className="flex items-center gap-3">
            <span className={`flex items-center gap-1.5 text-xs px-2.5 py-1 rounded-full font-mono border ${
              wsConnected 
                ? (isDark ? 'bg-emerald-950/60 text-emerald-400 border-emerald-500/30' : 'bg-emerald-50 text-emerald-700 border-emerald-300') 
                : 'bg-red-50 text-red-600 border-red-300'
            }`}>
              <span className="w-2 h-2 rounded-full bg-emerald-500 animate-pulse"></span>
              WebSocket: {wsConnected ? `Connected (${wsPing}ms)` : 'Disconnected'}
            </span>

            <span className={`flex items-center gap-1.5 text-xs px-2.5 py-1 rounded-full font-mono border ${
              isDark ? 'bg-cyan-950/60 text-cyan-400 border-cyan-500/30' : 'bg-sky-50 text-sky-700 border-sky-300'
            }`}>
              <span className="w-2 h-2 rounded-full bg-sky-500"></span>
              MQTT Broker: {mqttStatus ? 'Online (1883)' : 'Offline'}
            </span>

            {/* 🌟 VAI TRÒ TÀI KHOẢN (CỐ ĐỊNH THEO USER) */}
            <div className={`px-2.5 py-1 rounded-md border text-xs font-semibold flex items-center gap-1.5 ${
              isDark ? 'bg-slate-900 border-slate-800 text-slate-300' : 'bg-slate-100 border-slate-200 text-slate-700'
            }`}>
              <span className={`text-[11px] ${subTextClass}`}>Vai trò:</span>
              <span className={`px-2 py-0.5 rounded text-[11px] font-bold ${
                currentUser.role === 'Owner'
                  ? (isDark ? 'bg-cyan-500/20 text-cyan-400 border border-cyan-500/30' : 'bg-sky-100 text-sky-700 border border-sky-300')
                  : currentUser.role === 'Member'
                  ? 'bg-emerald-500/20 text-emerald-400 border border-emerald-500/30'
                  : 'bg-amber-500/20 text-amber-400 border border-amber-500/30'
              }`}>
                {currentUser.role === 'Owner' ? 'Chủ nhà' : currentUser.role === 'Member' ? 'Thành viên' : 'Khách'}
              </span>
            </div>

            <button
              onClick={toggleTheme}
              className={`p-1.5 rounded border text-xs transition ${isDark ? 'bg-slate-900 text-slate-300 border-slate-800 hover:bg-slate-800' : 'bg-slate-100 text-slate-700 border-slate-200 hover:bg-slate-200'}`}
            >
              {isDark ? '🌙' : '☀️'}
            </button>

            <span className={`text-xs font-mono px-2.5 py-1 rounded border ${isDark ? 'bg-slate-900 text-slate-300 border-slate-800' : 'bg-slate-100 text-slate-700 border-slate-200'}`}>
              {currentTime || '23:41:00 2/11/2026'}
            </span>
          </div>
        </header>

        {/* TAB CONTENT RENDERER */}
        <div className="p-6 flex-1 overflow-y-auto">
          {/* TAB 1: TỔNG QUAN (OVERVIEW) */}
          {activeTab === 'overview' && (
            <div className="space-y-6">
              {/* 4 Sensor Metric Cards */}
              <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-4">
                <div className={`p-4 rounded-xl border flex justify-between items-start ${cardBgClass}`}>
                  <div>
                    <span className={`text-xs font-medium ${subTextClass}`}>Nhiệt độ (DHT22)</span>
                    <div className="text-2xl font-bold mt-1">{sensorTemp.toFixed(1)} <span className={isDark ? 'text-cyan-400' : 'text-sky-600'}>°C</span></div>
                    <span className="text-[11px] text-emerald-600 dark:text-emerald-400 font-medium">✓ Môi trường lý tưởng</span>
                  </div>
                  <div className="p-2 rounded-lg bg-red-500/10 text-red-500 border border-red-500/20 text-lg">🌡️</div>
                </div>

                <div className={`p-4 rounded-xl border flex justify-between items-start ${cardBgClass}`}>
                  <div>
                    <span className={`text-xs font-medium ${subTextClass}`}>Độ ẩm không khí</span>
                    <div className="text-2xl font-bold mt-1">{sensorHum} <span className={isDark ? 'text-cyan-400' : 'text-sky-600'}>%</span></div>
                    <span className="text-[11px] text-sky-600 dark:text-cyan-400 font-medium">💧 An toàn</span>
                  </div>
                  <div className="p-2 rounded-lg bg-sky-500/10 text-sky-600 dark:text-cyan-400 border border-sky-500/20 text-lg">🌊</div>
                </div>

                <div className={`p-4 rounded-xl border flex justify-between items-start ${cardBgClass}`}>
                  <div>
                    <span className={`text-xs font-medium ${subTextClass}`}>Cường độ Ánh sáng</span>
                    <div className="text-2xl font-bold mt-1">{sensorLux} <span className="text-amber-500">Lux</span></div>
                    <span className="text-[11px] text-amber-600 dark:text-amber-400 font-medium">☀️ Ánh sáng tự nhiên</span>
                  </div>
                  <div className="p-2 rounded-lg bg-amber-500/10 text-amber-500 border border-amber-500/20 text-lg">💡</div>
                </div>

                <div className={`p-4 rounded-xl border flex justify-between items-start ${cardBgClass}`}>
                  <div>
                    <span className={`text-xs font-medium ${subTextClass}`}>Cảm biến Chuyển động</span>
                    <div className="text-2xl font-bold text-emerald-600 dark:text-emerald-400 mt-1">
                      {sensorMotion ? 'Phát hiện' : 'Không có'}
                    </div>
                    <span className={`text-[11px] ${subTextClass}`}>Khu vực Phòng khách</span>
                  </div>
                  <div className="p-2 rounded-lg bg-emerald-500/10 text-emerald-600 dark:text-emerald-400 border border-emerald-500/20 text-lg">🏃</div>
                </div>
              </div>

              {/* Banner Anomaly Test */}
              <div className={`p-4 rounded-xl border flex justify-between items-center gap-4 ${cardBgClass}`}>
                <div className="flex items-center gap-3">
                  <div className="p-2.5 rounded-lg bg-red-500/10 text-red-500 border border-red-500/20 text-xl">🚀</div>
                  <div>
                    <h3 className="text-xs font-bold uppercase tracking-wide">Kịch bản Thử nghiệm AI Anomaly (Z-Score)</h3>
                    <p className={`text-[11px] ${subTextClass}`}>Bấm nút để mô phỏng sự cố cảm biến vọt lên 65°C, kích hoạt thuật toán Z-Score & phát WebSocket Realtime!</p>
                  </div>
                </div>
                <button
                  onClick={triggerHeatAnomaly}
                  className="px-4 py-2 bg-gradient-to-r from-red-600 to-rose-600 text-white rounded-lg text-xs font-bold hover:brightness-110 transition shrink-0 shadow-md"
                >
                  ⚠️ Giả lập Biến động Nhiệt độ 65°C
                </button>
              </div>

              {/* Main 2-Column Grid */}
              <div className="grid grid-cols-1 lg:grid-cols-3 gap-6">
                <div className="lg:col-span-2 space-y-4">
                  <div className="flex justify-between items-center">
                    <h2 className="text-sm font-bold flex items-center gap-2">
                      <span>🎛️</span> Điều khiển Nhanh Thiết bị
                    </h2>
                    <span className={`text-[11px] font-mono ${subTextClass}`}>Đồng bộ qua MQTT & WebSocket</span>
                  </div>

                  <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
                    {devices.slice(0, 4).map((dev) => (
                      <div key={dev.id} className={`p-4 rounded-xl border flex flex-col justify-between ${cardBgClass}`}>
                        <div className="flex justify-between items-center">
                          <div className="flex items-center gap-3">
                            <div className={`p-2.5 rounded-lg text-lg ${dev.status ? 'bg-sky-500/20 text-sky-600 dark:bg-cyan-500/20 dark:text-cyan-400' : 'bg-slate-200 text-slate-500 dark:bg-slate-800'}`}>
                              {dev.name.includes('Đèn') ? '💡' : dev.name.includes('Quạt') ? '🌪️' : '🔒'}
                            </div>
                            <div>
                              <div className="text-xs font-bold">{dev.name}</div>
                              <div className={`text-[10px] ${subTextClass}`}>
                                {dev.room_name} • <span className={dev.status ? (isDark ? 'text-cyan-400 font-bold' : 'text-sky-600 font-bold') : 'text-slate-400'}>{dev.status ? `ON (${dev.power_watt}W)` : 'OFF'}</span>
                              </div>
                            </div>
                          </div>

                          <button
                            onClick={() => toggleDevice(dev.id, dev.status)}
                            className={`w-12 h-6 rounded-full p-0.5 transition-colors duration-200 ease-in-out ${dev.status ? (isDark ? 'bg-cyan-400' : 'bg-sky-500') : 'bg-slate-300 dark:bg-slate-800'}`}
                          >
                            <div className={`w-5 h-5 rounded-full bg-white dark:bg-slate-950 shadow transition-transform duration-200 ${dev.status ? 'translate-x-6' : 'translate-x-0'}`} />
                          </button>
                        </div>
                        <div className={`mt-3 pt-2 border-t border-slate-200 dark:border-slate-800/60 text-[10px] font-mono truncate ${subTextClass}`}>
                          Topic: {dev.topic}
                        </div>
                      </div>
                    ))}
                  </div>
                </div>

                {/* Right 1 Column: Cảnh báo AI & Live Stream */}
                <div className="space-y-4">
                  <div className={`p-4 rounded-xl border ${cardBgClass}`}>
                    <div className="flex justify-between items-center mb-3">
                      <h3 className="text-xs font-bold text-red-600 dark:text-red-400 flex items-center gap-1.5">
                        <span>⚠️</span> CẢNH BÁO AI MỚI NHẤT
                      </h3>
                      <span className="px-1.5 py-0.5 rounded text-[10px] bg-red-100 dark:bg-red-950 text-red-600 dark:text-red-400 border border-red-200 dark:border-red-800 font-mono">Z-Score Engine</span>
                    </div>

                    <div className="space-y-2">
                      {aiAlerts.map((alt) => (
                        <div key={alt.id} className="p-2.5 rounded bg-red-50 dark:bg-red-950/40 border border-red-200 dark:border-red-900/50 text-xs">
                          <div className="flex justify-between text-red-600 dark:text-red-400 font-mono text-[11px] font-bold">
                            <span>{alt.alert_type}</span>
                            <span className="text-slate-400 font-normal">{alt.created_at}</span>
                          </div>
                          <div className={`text-[11px] mt-1 ${isDark ? 'text-slate-300' : 'text-slate-700'}`}>{alt.message}</div>
                        </div>
                      ))}
                    </div>
                  </div>

                  <div className={`p-4 rounded-xl border font-mono text-[11px] ${isDark ? 'bg-[#0a0f18] border-slate-800/80' : 'bg-slate-900 text-slate-100 border-slate-800'}`}>
                    <div className="flex justify-between items-center text-slate-400 mb-2">
                      <span className="text-sky-400 dark:text-cyan-400 font-bold flex items-center gap-1">
                        <span>❯_</span> Live WebSocket Stream
                      </span>
                      <button onClick={() => setLogs([])} className="text-[10px] text-slate-400 hover:text-slate-200">Xóa log</button>
                    </div>
                    <div className="space-y-1 max-h-32 overflow-y-auto text-emerald-400 leading-tight">
                      {logs.map((lg, i) => (
                        <div key={i}>{lg}</div>
                      ))}
                    </div>
                  </div>
                </div>
              </div>
            </div>
          )}

          {/* TAB 2: PHÒNG & THIẾT BỊ (DEVICES) */}
          {activeTab === 'devices' && (
            <div className="space-y-6">
              <div className="flex justify-between items-center">
                <div className="flex gap-2">
                  {['ALL', 'Phòng khách', 'Phòng ngủ', 'Nhà bếp', 'Sân thượng'].map((r) => (
                    <button
                      key={r}
                      onClick={() => setSelectedRoom(r)}
                      className={`px-3.5 py-1.5 rounded-lg text-xs font-semibold transition ${
                        selectedRoom === r
                          ? (isDark ? 'bg-cyan-500 text-slate-950 font-bold' : 'bg-sky-600 text-white font-bold')
                          : (isDark ? 'bg-[#0d131f] text-slate-400 border border-slate-800' : 'bg-white text-slate-600 border border-slate-200 hover:bg-slate-100')
                      }`}
                    >
                      {r === 'ALL' ? 'Tất cả phòng' : r}
                    </button>
                  ))}
                </div>

                <button className="px-4 py-2 bg-sky-600 hover:bg-sky-700 text-white font-bold rounded-lg text-xs transition">
                  + Thêm thiết bị IoT
                </button>
              </div>

              <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-4">
                {filteredDevices.map((dev) => (
                  <div key={dev.id} className={`p-5 rounded-xl border flex flex-col justify-between space-y-4 ${cardBgClass}`}>
                    <div className="flex justify-between items-start">
                      <div className="flex items-center gap-3">
                        <div className={`p-3 rounded-xl text-xl ${dev.status ? 'bg-sky-500/20 text-sky-600 dark:bg-cyan-500/20 dark:text-cyan-400' : 'bg-slate-200 text-slate-500 dark:bg-slate-800'}`}>
                          {dev.name.includes('Đèn') ? '💡' : dev.name.includes('Quạt') ? '🌪️' : dev.name.includes('Điều hòa') ? '❄️' : '🔒'}
                        </div>
                        <div>
                          <div className="text-sm font-bold">{dev.name}</div>
                          <div className={`text-xs ${subTextClass}`}>
                            {dev.room_name} • <span className={dev.status ? (isDark ? 'text-cyan-400 font-bold' : 'text-sky-600 font-bold') : 'text-slate-400'}>{dev.status ? `ON (${dev.power_watt}W)` : 'OFF'}</span>
                          </div>
                        </div>
                      </div>

                      <button
                        onClick={() => toggleDevice(dev.id, dev.status)}
                        className={`w-12 h-6 rounded-full p-0.5 transition-colors duration-200 ease-in-out ${dev.status ? (isDark ? 'bg-cyan-400' : 'bg-sky-500') : 'bg-slate-300 dark:bg-slate-800'}`}
                      >
                        <div className={`w-5 h-5 rounded-full bg-white dark:bg-slate-950 shadow transition-transform duration-200 ${dev.status ? 'translate-x-6' : 'translate-x-0'}`} />
                      </button>
                    </div>

                    <div className={`pt-3 border-t border-slate-200 dark:border-slate-800/60 text-xs flex justify-between items-center ${subTextClass}`}>
                      <span className="font-mono">Topic: {dev.topic}</span>
                      <span className="font-bold">{dev.power_watt} Watts</span>
                    </div>
                  </div>
                ))}
              </div>
            </div>
          )}

          {/* TAB 3: TỰ ĐỘNG HÓA (AUTOMATIONS) */}
          {activeTab === 'automations' && (
            <div className="space-y-4">
              <div className="flex justify-between items-center">
                <h2 className="text-sm font-bold">Kịch bản Tự động hóa IF-THEN Engine</h2>
                <button className="px-3.5 py-1.5 bg-amber-600 hover:bg-amber-700 text-white font-bold rounded-lg text-xs transition">
                  + Tạo luật mới
                </button>
              </div>

              <div className="space-y-3">
                {automations.map((rule) => (
                  <div key={rule.id} className={`p-4 rounded-xl border flex justify-between items-center ${cardBgClass}`}>
                    <div>
                      <div className="text-xs font-bold flex items-center gap-2">
                        <span>⚡</span> {rule.name}
                      </div>
                      <div className={`text-[11px] mt-1 flex items-center gap-3 ${subTextClass}`}>
                        <span className="px-2 py-0.5 rounded bg-sky-500/10 text-sky-600 dark:text-cyan-400 border border-sky-500/20 font-mono">IF: {rule.condition_text}</span>
                        <span>➔</span>
                        <span className="px-2 py-0.5 rounded bg-emerald-500/10 text-emerald-600 dark:text-emerald-400 border border-emerald-500/20 font-mono">THEN: {rule.action_text}</span>
                      </div>
                    </div>

                    <button
                      onClick={() => setAutomations((prev) => prev.map((a) => (a.id === rule.id ? { ...a, is_active: !a.is_active } : a)))}
                      className={`px-3 py-1 rounded text-xs font-bold transition ${rule.is_active ? 'bg-emerald-500/20 text-emerald-600 dark:text-emerald-400 border border-emerald-500/30' : 'bg-slate-200 text-slate-500 dark:bg-slate-800'}`}
                    >
                      {rule.is_active ? 'KÍCH HOẠT' : 'TẮT'}
                    </button>
                  </div>
                ))}
              </div>
            </div>
          )}

          {/* TAB 4: THỐNG KÊ NĂNG LƯỢNG (ENERGY) */}
          {activeTab === 'energy' && (
            <div className="space-y-6">
              <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
                <div className={`p-4 rounded-xl border ${cardBgClass}`}>
                  <span className={`text-xs ${subTextClass}`}>Tổng điện năng 7 ngày (TimescaleDB)</span>
                  <div className="text-2xl font-bold mt-1 text-sky-600 dark:text-cyan-400">{energyData.total_kwh} <span className="text-sm">kWh</span></div>
                </div>

                <div className={`p-4 rounded-xl border ${cardBgClass}`}>
                  <span className={`text-xs ${subTextClass}`}>Ước tính tiền điện thực tế (2.500đ/kWh)</span>
                  <div className="text-2xl font-bold mt-1 text-emerald-600 dark:text-emerald-400">{energyData.total_vnd.toLocaleString('vi-VN')} <span className="text-sm">VNĐ</span></div>
                </div>
              </div>

              <div className={`p-5 rounded-xl border ${cardBgClass}`}>
                <h3 className="text-xs font-bold mb-4">Biểu đồ Điện năng tiêu thụ 7 ngày gần nhất</h3>
                <div className="h-64">
                  <Bar data={chartData} options={{ responsive: true, maintainAspectRatio: false }} />
                </div>
              </div>
            </div>
          )}

          {/* TAB 5: TRÍ TUỆ NHÂN TẠO (AI) */}
          {activeTab === 'ai' && (
            <div className="space-y-6">
              <div className={`p-4 rounded-xl border ${cardBgClass}`}>
                <h3 className="text-xs font-bold text-red-600 dark:text-red-400 mb-2">Mô hình AI Z-Score Anomaly Engine</h3>
                <p className={`text-xs ${subTextClass}`}>Tự động phân tích phương sai $\sigma$ và trung bình động $\mu$ của chuỗi thời gian năng lượng & nhiệt độ để cảnh báo bất thường trong thời gian thực.</p>
              </div>

              <div className="space-y-3">
                {aiAlerts.map((alt) => (
                  <div key={alt.id} className={`p-4 rounded-xl border border-red-500/30 bg-red-500/5 ${cardBgClass}`}>
                    <div className="flex justify-between items-center text-xs font-bold text-red-600 dark:text-red-400">
                      <span>🚨 {alt.alert_type}</span>
                      <span className="font-mono text-slate-400">{alt.created_at}</span>
                    </div>
                    <div className="text-xs mt-2">{alt.message}</div>
                  </div>
                ))}
              </div>
            </div>
          )}

          {/* TAB 6: QUẢN LÝ KHÁCH (GUESTS) */}
          {activeTab === 'guests' && (
            <div className="space-y-4">
              <div className="flex justify-between items-center">
                <h2 className="text-sm font-bold">Cấp quyền Truy cập Tạm thời (RBAC Guest)</h2>
                <button className="px-3.5 py-1.5 bg-sky-600 hover:bg-sky-700 text-white font-bold rounded-lg text-xs transition">
                  + Tạo Token Khách
                </button>
              </div>

              <div className="space-y-3">
                {guests.map((g) => (
                  <div key={g.id} className={`p-4 rounded-xl border flex justify-between items-center ${cardBgClass}`}>
                    <div>
                      <div className="text-xs font-bold flex items-center gap-2">
                        <span>🔑</span> {g.guest_name}
                      </div>
                      <div className={`text-[11px] mt-1 ${subTextClass}`}>
                        Quyền: <span className="font-bold text-sky-600 dark:text-cyan-400">{g.device_name}</span> | Hạn dùng: {g.expiry_time}
                      </div>
                    </div>

                    <button
                      onClick={() => setGuests((prev) => prev.map((item) => (item.id === g.id ? { ...item, status: 'REVOKED' } : item)))}
                      className={`px-3 py-1 rounded text-xs font-bold transition ${g.status === 'ACTIVE' ? 'bg-red-500/20 text-red-600 dark:text-red-400 border border-red-500/30' : 'bg-slate-200 text-slate-500 dark:bg-slate-800'}`}
                    >
                      {g.status === 'ACTIVE' ? 'THU HỒI' : 'ĐÃ THU HỒI'}
                    </button>
                  </div>
                ))}
              </div>
            </div>
          )}
        </div>
      </main>
    </div>
  );
};

export default App;