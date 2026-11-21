import { useEffect, useState } from 'react';
import { AuthScreen } from './components/AuthScreen';
import { EnergyAnalyticsPanel, type EnergyPeriod } from './components/EnergyAnalyticsPanel';
import { Sidebar } from './components/layout/Sidebar';
import { TopHeader } from './components/layout/TopHeader';
import { AccountsTab } from './components/tabs/AccountsTab';
import { AiAlertsTab } from './components/tabs/AiAlertsTab';
import { AutomationsTab } from './components/tabs/AutomationsTab';
import { DevicesTab } from './components/tabs/DevicesTab';
import { OverviewTab } from './components/tabs/OverviewTab';
import { AuthProvider, useAuth } from './context/AuthContext';
import { useSmartHomeSocket } from './hooks/useSmartHomeSocket';
import type {
  ActiveTab,
  AiAlert,
  AutomationRule,
  Device,
  EnergyPoint,
  EnergyState,
  House,
  Room,
  SensorData,
  UserProfile,
} from './types/smarthome';
import { API_BASE, getAuthHeaders } from './utils/api';

function SmartHomeWorkspace() {
  const { currentUser, isOwnerOrAdmin, syncUserProfile, logout } = useAuth();

  // ==================== UI & NAVIGATION STATE ====================
  const [activeTab, setActiveTab] = useState<ActiveTab>('overview');
  const [isDark, setIsDark] = useState(true);
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
  const [sensorData, setSensorData] = useState<SensorData | null>(null);

  const [energyPeriod, setEnergyPeriod] = useState<EnergyPeriod>('week');
  const [energyData, setEnergyData] = useState<EnergyState>({
    total_kwh: 0,
    estimated_cost: 0,
    peak_watt: 0,
    daily: [],
  });

  const appendLog = (msg: string) => {
    const time = new Date().toLocaleTimeString('vi-VN', { hour12: false });
    setSystemLogs((prev) => [`[${time}] ${msg}`, ...prev].slice(0, 40));
  };

  // ==================== LOGOUT HANDLER ====================
  const handleLogout = () => {
    logout();
    setUsersList([]);
    setHouses([]);
    setRooms([]);
    setDevices([]);
    setAutomations([]);
    setAiAlerts([]);
    setSensorData(null);
    setEnergyData({ total_kwh: 0, estimated_cost: 0, peak_watt: 0, daily: [] });
    setActiveTab('overview');
    setSystemLogs(['SYSTEM: Đã đăng xuất khỏi phiên làm việc.']);
  };

  // ==================== FETCH ALL DATABASE DATA ====================
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
          syncUserProfile(meData);
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
  const wsConnected = useSmartHomeSocket({
    currentUser,
    setSensorData,
    setDevices,
    setAiAlerts,
    appendLog,
  });

  // ==================== SHARED DEVICE TOGGLE ====================
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

  // ==================== AUTH GUARD ====================
  if (!currentUser) {
    return (
      <AuthScreen
        onSuccessLog={(msg) => {
          setActiveTab('overview');
          appendLog(msg);
        }}
      />
    );
  }

  // ==================== STYLING HELPERS ====================
  const pageBg = isDark
    ? 'dark-theme bg-[#080d1a] text-slate-100'
    : 'light-theme bg-[#F0F4F9] text-slate-900';
  const sidebarBg = isDark ? 'bg-[#0b1121] border-slate-800/80' : 'bg-white border-slate-200';
  const cardBg = isDark
    ? 'bg-[#0e1629] border-slate-800/80'
    : 'bg-white border-slate-200/90 shadow-sm';
  const inputBg = isDark
    ? 'bg-[#131c31] border-slate-700 text-slate-100 placeholder-slate-500'
    : 'bg-white border-slate-300 text-slate-900 placeholder-slate-400';

  return (
    <div className={`min-h-screen flex ${pageBg}`}>
      <Sidebar
        currentUser={currentUser}
        isOwnerOrAdmin={isOwnerOrAdmin}
        activeTab={activeTab}
        onSelectTab={setActiveTab}
        onLogout={handleLogout}
        roomsCount={rooms.length}
        devicesCount={devices.length}
        automationsCount={automations.length}
        aiAlertsCount={aiAlerts.length}
        usersCount={usersList.length}
        sidebarBg={sidebarBg}
      />

      <div className="flex-1 flex flex-col min-w-0">
        <TopHeader
          housesCount={houses.length}
          roomsCount={rooms.length}
          devicesCount={devices.length}
          wsConnected={wsConnected}
          userRole={currentUser.role}
          isDark={isDark}
          onToggleTheme={() => setIsDark(!isDark)}
          sidebarBg={sidebarBg}
        />

        <main className="flex-1 p-6 overflow-y-auto space-y-6">
          {activeTab === 'overview' && (
            <OverviewTab
              houses={houses}
              rooms={rooms}
              devices={devices}
              automations={automations}
              aiAlerts={aiAlerts}
              energyData={energyData}
              sensorData={sensorData}
              systemLogs={systemLogs}
              onClearLogs={() => setSystemLogs([])}
              onNavigateTab={setActiveTab}
              onToggleDevice={handleToggleDevice}
              cardBg={cardBg}
            />
          )}

          {activeTab === 'devices' && (
            <DevicesTab
              houses={houses}
              rooms={rooms}
              devices={devices}
              sensorData={sensorData}
              isOwnerOrAdmin={isOwnerOrAdmin}
              cardBg={cardBg}
              inputBg={inputBg}
              appendLog={appendLog}
              onRefresh={() => fetchAllDatabaseData()}
              onToggleDevice={handleToggleDevice}
            />
          )}

          {activeTab === 'automations' && (
            <AutomationsTab
              automations={automations}
              setAutomations={setAutomations}
              isOwnerOrAdmin={isOwnerOrAdmin}
              cardBg={cardBg}
              inputBg={inputBg}
              appendLog={appendLog}
              onRefresh={() => fetchAllDatabaseData()}
            />
          )}

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

          {activeTab === 'ai' && (
            <AiAlertsTab
              aiAlerts={aiAlerts}
              isOwnerOrAdmin={isOwnerOrAdmin}
              cardBg={cardBg}
              appendLog={appendLog}
              onRefresh={() => fetchAllDatabaseData()}
            />
          )}

          {activeTab === 'accounts' && isOwnerOrAdmin && (
            <AccountsTab
              currentUser={currentUser}
              usersList={usersList}
              cardBg={cardBg}
              inputBg={inputBg}
              appendLog={appendLog}
              onRefresh={() => fetchAllDatabaseData()}
            />
          )}
        </main>
      </div>
    </div>
  );
}

export function App() {
  return (
    <AuthProvider>
      <SmartHomeWorkspace />
    </AuthProvider>
  );
}

export default App;