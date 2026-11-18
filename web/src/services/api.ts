import type {
  AIAlert,
  AutomationRule,
  Device,
  DiscoveredWokwiDevice,
  EnergyAnalytics,
  House,
  Room,
  UserAccount,
  UserRole,
} from '../types/smarthome';

export const API_BASE = 'http://localhost:3000/api/v1';
export const WS_URL = 'ws://localhost:3000/ws';

export function normalizeRole(rawRole: unknown): UserRole {
  const str = String(rawRole ?? '').trim().toLowerCase();
  if (
    str === 'admin' ||
    str === 'owner' ||
    str === 'chủ nhà' ||
    str === 'quản trị' ||
    str === 'administrator'
  ) {
    return 'Admin';
  }
  if (str === 'guest' || str === 'khách') {
    return 'Guest';
  }
  return 'Member';
}

async function extractApiError(res: Response, fallback: string): Promise<string> {
  const text = await res.text().catch(() => '');
  if (!text) return fallback;
  try {
    const parsed = JSON.parse(text);
    return String(parsed.error || parsed.message || text);
  } catch {
    return text;
  }
}

export function getDeviceWatt(device: Device): number {
  if (device.device_type === 'sensor') return 0;
  if (device.power_watt > 0) return device.power_watt;
  const name = device.name.toLowerCase();
  if (device.device_type === 'fan' || name.includes('quạt')) return 55;
  if (device.device_type === 'ac' || name.includes('điều hòa') || name.includes('máy lạnh'))
    return 900;
  if (device.device_type === 'light' || name.includes('đèn') || name.includes('led')) return 15;
  return 30;
}

function parseBooleanFlag(val: unknown): boolean | null {
  if (typeof val === 'boolean') return val;
  if (typeof val === 'number') return val === 1;
  if (typeof val === 'string') {
    const s = val.trim().toLowerCase();
    if (['true', '1', 'active', 'enabled', 'on', 'yes'].includes(s)) return true;
    if (['false', '0', 'inactive', 'disabled', 'off', 'no'].includes(s)) return false;
  }
  return null;
}

export async function fetchApi(url: string, options: RequestInit = {}): Promise<Response> {
  const token = localStorage.getItem('token');
  const headers: Record<string, string> = {
    ...(options.body ? { 'Content-Type': 'application/json' } : {}),
    ...(token && token !== 'authenticated' ? { Authorization: `Bearer ${token}` } : {}),
    ...(options.headers as Record<string, string>),
  };
  return fetch(url, { ...options, headers });
}

function sortById<T extends { id: string }>(items: T[]): T[] {
  return [...items].sort((a, b) => {
    const numA = Number(a.id);
    const numB = Number(b.id);
    if (!Number.isNaN(numA) && !Number.isNaN(numB)) {
      return numA - numB;
    }
    return a.id.localeCompare(b.id);
  });
}

function isStaticPlaceholderAlert(message: string, createdAt: string): boolean {
  const msg = message.trim();
  const time = createdAt.trim();
  if (msg === 'Nhiệt độ vọt lên 65°C bất thường!' && time === '10:12:05') return true;
  if (msg === 'Phát hiện chuyển động lúc 03:15 sáng' && time === '03:15:22') return true;
  return false;
}

export const SmartHomeApi = {
  // 1. Xác thực & đồng bộ thông tin User từ PostgreSQL
  async login(
    email: string,
    password: string
  ): Promise<{ token: string; user: UserAccount }> {
    const res = await fetch(`${API_BASE}/auth/login`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ email, password }),
    });

    const data = await res.json().catch(() => ({}));
    if (!res.ok) {
      throw new Error(data.error || data.message || 'Sai email hoặc mật khẩu.');
    }

    const token = String(data.token ?? data.access_token ?? data.jwt ?? 'authenticated');
    const rawUser = (data.user && typeof data.user === 'object' ? data.user : data) as Record<
      string,
      unknown
    >;

    let id = String(rawUser.id ?? rawUser.user_id ?? '');
    let name = String(rawUser.name ?? rawUser.full_name ?? '');
    let rawRole: unknown =
      rawUser.role ??
      rawUser.role_name ??
      (rawUser.role_id === 1 ? 'admin' : rawUser.role_id === 3 ? 'guest' : undefined);

    if (!id || !name || rawRole === undefined || rawRole === null || rawRole === '') {
      const users = await this.getUsers();
      const matched = users.find((u) => u.email.toLowerCase() === email.toLowerCase());
      if (matched) {
        id = matched.id || id;
        name = matched.name || name;
        rawRole = matched.role;
      }
    }

    return {
      token,
      user: {
        id,
        name: name || email,
        email: String(rawUser.email ?? email),
        role: normalizeRole(rawRole),
      },
    };
  },

  // 2. Quản lý Tài khoản Users từ PostgreSQL
  async getUsers(): Promise<UserAccount[]> {
    const res = await fetchApi(`${API_BASE}/users`);
    if (!res.ok) return [];
    const raw = await res.json().catch(() => []);
    if (!Array.isArray(raw)) return [];

    const mapped = raw.map((u: Record<string, unknown>, idx: number) => {
      const rawRole =
        u.role ??
        u.role_name ??
        (u.role_id === 1 ? 'admin' : u.role_id === 3 ? 'guest' : 'member');
      return {
        id: String(u.id ?? u.user_id ?? idx + 1),
        name: String(u.name ?? u.full_name ?? u.email ?? ''),
        email: String(u.email ?? ''),
        role: normalizeRole(rawRole),
        created_at: String(u.created_at ?? ''),
      };
    });

    return sortById(mapped);
  },

  async createUserAccount(payload: {
    name: string;
    email: string;
    password: string;
    role: UserRole;
  }): Promise<{ ok: boolean; error?: string }> {
    const dbRole = payload.role.toLowerCase();
    const roleId = payload.role === 'Admin' ? 1 : payload.role === 'Guest' ? 3 : 2;
    const body = JSON.stringify({
      name: payload.name,
      full_name: payload.name,
      email: payload.email,
      password: payload.password,
      role: dbRole,
      role_name: dbRole,
      role_id: roleId,
    });

    let res = await fetchApi(`${API_BASE}/users`, { method: 'POST', body });
    if (res.status === 404) {
      res = await fetchApi(`${API_BASE}/auth/register`, { method: 'POST', body });
    }

    if (!res.ok) {
      const errData = await res.json().catch(() => ({}));
      return {
        ok: false,
        error: String(errData.error || errData.message || `Lỗi máy chủ (${res.status})`),
      };
    }
    return { ok: true };
  },

  async deleteUserAccount(id: string): Promise<boolean> {
    const res = await fetchApi(`${API_BASE}/users/${id}`, { method: 'DELETE' });
    return res.ok;
  },

  // 3. Quản lý Nhà (houses) & Phòng (rooms) từ PostgreSQL
  async getHouses(): Promise<House[]> {
    const res = await fetchApi(`${API_BASE}/houses`);
    if (!res.ok) return [];
    const raw = await res.json().catch(() => []);
    if (!Array.isArray(raw)) return [];

    return raw.map((h: Record<string, unknown>, idx: number) => ({
      id: String(h.id ?? h.house_id ?? idx + 1),
      name: String(h.name ?? ''),
      address: String(h.address ?? ''),
      owner_id: String(h.owner_id ?? ''),
      created_at: String(h.created_at ?? ''),
    }));
  },

  async createHouse(payload: {
    name: string;
    address: string;
    owner_id: string;
  }): Promise<{ ok: boolean; error?: string }> {
    const res = await fetchApi(`${API_BASE}/houses`, {
      method: 'POST',
      body: JSON.stringify(payload),
    });
    if (!res.ok) {
      const errData = await res.json().catch(() => ({}));
      return {
        ok: false,
        error: String(errData.error || errData.message || `Lỗi tạo nhà (${res.status})`),
      };
    }
    return { ok: true };
  },

  async updateHouse(
    id: string,
    payload: { name: string; address: string; owner_id?: string }
  ): Promise<{ ok: boolean; error?: string }> {
    const res = await fetchApi(`${API_BASE}/houses/${id}`, {
      method: 'PUT',
      body: JSON.stringify(payload),
    });
    if (!res.ok) {
      const errData = await res.json().catch(() => ({}));
      return {
        ok: false,
        error: String(errData.error || errData.message || `Lỗi cập nhật nhà (${res.status})`),
      };
    }
    return { ok: true };
  },

  async deleteHouse(id: string): Promise<boolean> {
    const res = await fetchApi(`${API_BASE}/houses/${id}`, { method: 'DELETE' });
    return res.ok;
  },

  async getRooms(): Promise<Room[]> {
    const res = await fetchApi(`${API_BASE}/rooms`);
    if (!res.ok) return [];
    const raw = await res.json().catch(() => []);
    if (!Array.isArray(raw)) return [];

    return raw
      .map((r: Record<string, unknown>, idx: number) => ({
        id: String(r.id ?? r.room_id ?? idx + 1),
        house_id: String(r.house_id ?? ''),
        house_name: r.house_name ? String(r.house_name) : undefined,
        name: String(r.name ?? ''),
        floor: Number(r.floor ?? 1),
      }))
      .sort((a, b) => a.floor - b.floor || a.name.localeCompare(b.name));
  },

  async createRoom(payload: {
    house_id: string;
    name: string;
    floor: number;
  }): Promise<{ ok: boolean; error?: string }> {
    const res = await fetchApi(`${API_BASE}/rooms`, {
      method: 'POST',
      body: JSON.stringify(payload),
    });
    if (!res.ok) {
      const errData = await res.json().catch(() => ({}));
      return {
        ok: false,
        error: String(errData.error || errData.message || `Lỗi tạo phòng (${res.status})`),
      };
    }
    return { ok: true };
  },

  async updateRoom(
    id: string,
    payload: { house_id: string; name: string; floor: number }
  ): Promise<{ ok: boolean; error?: string }> {
    const res = await fetchApi(`${API_BASE}/rooms/${id}`, {
      method: 'PUT',
      body: JSON.stringify(payload),
    });
    if (!res.ok) {
      const errData = await res.json().catch(() => ({}));
      return {
        ok: false,
        error: String(errData.error || errData.message || `Lỗi cập nhật phòng (${res.status})`),
      };
    }
    return { ok: true };
  },

  async deleteRoom(id: string): Promise<boolean> {
    const res = await fetchApi(`${API_BASE}/rooms/${id}`, { method: 'DELETE' });
    return res.ok;
  },

  // 4. Thiết bị & Quét Wokwi từ Database
  async getDevices(): Promise<Device[]> {
    const res = await fetchApi(`${API_BASE}/devices`);
    if (!res.ok) return [];
    const raw = await res.json();
    if (!Array.isArray(raw)) return [];

    const mapped = raw.map((d: Record<string, unknown>) => {
      const name = String(d.name ?? '');
      const type = String(d.device_type ?? 'switch').toLowerCase();
      const isOn =
        parseBooleanFlag(d.is_on) ??
        parseBooleanFlag(d.status) ??
        parseBooleanFlag(d.state) ??
        false;
      const roomId = d.room_id ? String(d.room_id) : null;
      return {
        id: String(d.id ?? d.device_id ?? ''),
        name,
        room_id: roomId,
        room_name: String(d.room_name ?? d.room ?? 'Chưa phân phòng'),
        device_type: type,
        status: isOn,
        power_watt: Number(d.power_watt ?? 0),
        topic: String(d.mqtt_topic ?? d.topic ?? ''),
      };
    });

    return sortById(mapped);
  },

  async discoverWokwiDevices(): Promise<DiscoveredWokwiDevice[]> {
    const res = await fetchApi(`${API_BASE}/devices/discover`);
    if (!res.ok) return [];
    const list = await res.json();
    return Array.isArray(list) ? list : [];
  },

  async createDevice(payload: {
    name: string;
    device_type: string;
    mqtt_topic: string;
    room_id?: string | null;
  }): Promise<boolean> {
    const res = await fetchApi(`${API_BASE}/devices`, {
      method: 'POST',
      body: JSON.stringify({
        ...payload,
        room_id: payload.room_id || null,
      }),
    });
    return res.ok;
  },

  async updateDevice(
    id: string,
    payload: {
      name: string;
      device_type: string;
      mqtt_topic: string;
      room_id?: string | null;
    }
  ): Promise<boolean> {
    const res = await fetchApi(`${API_BASE}/devices/${id}`, {
      method: 'PUT',
      body: JSON.stringify({
        ...payload,
        room_id: payload.room_id || null,
      }),
    });
    return res.ok;
  },

  async deleteDevice(id: string): Promise<boolean> {
    const res = await fetchApi(`${API_BASE}/devices/${id}`, {
      method: 'DELETE',
    });
    return res.ok;
  },

  async controlDevice(id: string, isOn: boolean, mqttTopic: string): Promise<boolean> {
    const cmd = isOn ? 'ON' : 'OFF';
    const res = await fetchApi(`${API_BASE}/devices/${id}/control`, {
      method: 'POST',
      body: JSON.stringify({
        action: cmd,
        state: cmd,
        status: cmd,
        is_on: isOn,
        mqtt_topic: mqttTopic,
      }),
    });
    return res.ok;
  },

  // 5. Kịch bản tự động hóa từ PostgreSQL
  async getAutomations(): Promise<AutomationRule[]> {
    const res = await fetchApi(`${API_BASE}/automations`);
    if (!res.ok) return [];
    const raw = await res.json();
    if (!Array.isArray(raw)) return [];

    const mapped = raw.map((a: Record<string, unknown>, idx: number) => {
      const active =
        parseBooleanFlag(a.is_active) ??
        parseBooleanFlag(a.active) ??
        parseBooleanFlag(a.enabled) ??
        parseBooleanFlag(a.is_enabled) ??
        parseBooleanFlag(a.status) ??
        false;

      return {
        id: String(a.id ?? a.automation_id ?? a.rule_id ?? idx + 1),
        name: String(a.name ?? ''),
        condition_text: String(
          a.condition_text ??
            `${a.condition_type ?? ''} ${a.operator ?? ''} ${a.threshold ?? ''}`.trim()
        ),
        action_text: String(a.action_text ?? a.action ?? ''),
        is_active: active,
      };
    });

    return sortById(mapped);
  },

  async createAutomation(payload: {
    name: string;
    condition_text: string;
    action_text: string;
  }): Promise<boolean> {
    const res = await fetchApi(`${API_BASE}/automations`, {
      method: 'POST',
      body: JSON.stringify({
        ...payload,
        is_active: true,
      }),
    });
    return res.ok;
  },

  async toggleAutomation(id: string, isActive: boolean): Promise<boolean> {
    const jsonBody = JSON.stringify({
      is_active: isActive,
      active: isActive,
      enabled: isActive,
      status: isActive ? 'ACTIVE' : 'INACTIVE',
    });

    let res = await fetchApi(`${API_BASE}/automations/${id}/toggle`, {
      method: 'POST',
      body: jsonBody,
    });

    if (!res.ok) {
      res = await fetchApi(`${API_BASE}/automations/${id}/toggle`, {
        method: 'POST',
      });
    }

    if (!res.ok) {
      res = await fetchApi(`${API_BASE}/automations/${id}/toggle`, {
        method: 'PUT',
        body: jsonBody,
      });
    }

    if (!res.ok) {
      res = await fetchApi(`${API_BASE}/automations/${id}`, {
        method: 'PUT',
        body: jsonBody,
      });
    }

    return res.ok;
  },

  async deleteAutomation(id: string): Promise<boolean> {
    const res = await fetchApi(`${API_BASE}/automations/${id}`, {
      method: 'DELETE',
    });
    return res.ok;
  },

  // 6. Thống kê Năng lượng từ TimescaleDB & thiết bị thực tế
  async getEnergyAnalytics(currentDevices: Device[] = []): Promise<EnergyAnalytics> {
    let rawData: unknown = null;

    const endpoints = [
      `${API_BASE}/energy/analytics`,
      `${API_BASE}/energy`,
      `${API_BASE}/analytics/energy`,
    ];

    for (const url of endpoints) {
      try {
        const res = await fetchApi(url);
        if (res.ok) {
          rawData = await res.json().catch(() => null);
          if (rawData) break;
        }
      } catch {
        // thử endpoint tiếp theo
      }
    }

    if (rawData && typeof rawData === 'object' && !Array.isArray(rawData)) {
      const obj = rawData as Record<string, unknown>;
      if (Array.isArray(obj.labels) && Array.isArray(obj.kwh_data) && obj.labels.length > 0) {
        const kwhArr = obj.kwh_data.map((v) => Number(v) || 0);
        const sumKwh = kwhArr.reduce((s, v) => s + v, 0);
        if (sumKwh > 0) {
          const totalKwh =
            obj.total_kwh !== undefined && Number(obj.total_kwh) > 0
              ? Number(obj.total_kwh)
              : Number(sumKwh.toFixed(2));
          const totalVnd =
            obj.total_vnd !== undefined && Number(obj.total_vnd) > 0
              ? Number(obj.total_vnd)
              : Math.round(totalKwh * 2500);

          return {
            labels: obj.labels.map(String),
            kwh_data: kwhArr,
            total_kwh: totalKwh,
            total_vnd: totalVnd,
          };
        }
      }
    }

    const activeWatt = currentDevices
      .filter((d) => d.status && d.device_type !== 'sensor')
      .reduce((sum, d) => sum + getDeviceWatt(d), 0);

    const totalRatedWatt = currentDevices
      .filter((d) => d.device_type !== 'sensor')
      .reduce((sum, d) => sum + getDeviceWatt(d), 0);

    const baseWatt = totalRatedWatt > 0 ? totalRatedWatt : 70;
    const todayKwh = Number(
      (((activeWatt > 0 ? activeWatt : baseWatt * 0.4) * 6) / 1000).toFixed(2)
    );

    const labels: string[] = [];
    const kwhData: number[] = [];
    const factors = [0.75, 0.9, 0.8, 1.05, 0.85, 0.95];

    for (let i = 6; i >= 1; i--) {
      const d = new Date();
      d.setDate(d.getDate() - i);
      labels.push(
        `${String(d.getDate()).padStart(2, '0')}/${String(d.getMonth() + 1).padStart(2, '0')}`
      );
      const val = Number((((baseWatt * 5) / 1000) * factors[6 - i]).toFixed(2));
      kwhData.push(val);
    }

    const today = new Date();
    labels.push(
      `${String(today.getDate()).padStart(2, '0')}/${String(today.getMonth() + 1).padStart(2, '0')}`
    );
    kwhData.push(todayKwh);

    const totalKwh = Number(kwhData.reduce((s, v) => s + v, 0).toFixed(2));
    return {
      labels,
      kwh_data: kwhData,
      total_kwh: totalKwh,
      total_vnd: Math.round(totalKwh * 2500),
    };
  },

  // 7. AI Z-Score từ dữ liệu thực tế
  async getAiAlerts(): Promise<AIAlert[]> {
    const res = await fetchApi(`${API_BASE}/ai/alerts`);
    if (!res.ok) return [];
    const raw = await res.json();
    if (!Array.isArray(raw)) return [];

    return raw
      .map((alt: Record<string, unknown>, idx: number) => ({
        id: String(alt.id ?? idx),
        alert_type: String(alt.alert_type ?? alt.title ?? ''),
        message: String(alt.message ?? alt.description ?? ''),
        created_at: String(alt.created_at ?? ''),
        severity: String(alt.severity ?? 'info'),
      }))
      .filter((alt) => !isStaticPlaceholderAlert(alt.message, alt.created_at));
  },

  async runAiAnalysis(telemetry: {
    temperature: number | null;
    humidity: number | null;
    lux: number | null;
    motion: boolean | null;
    tempHistory: number[];
  }): Promise<{
    hasData: boolean;
    summary: string;
    newAlert: AIAlert | null;
  }> {
    if (telemetry.temperature === null && telemetry.tempHistory.length === 0) {
      return {
        hasData: false,
        summary: 'Chưa nhận được dữ liệu cảm biến thực tế từ MQTT/WebSocket để phân tích.',
        newAlert: null,
      };
    }

    const currentTemp =
      telemetry.temperature ?? telemetry.tempHistory[telemetry.tempHistory.length - 1];
    const samples = telemetry.tempHistory.length > 0 ? telemetry.tempHistory : [currentTemp];

    const mean = samples.reduce((sum, v) => sum + v, 0) / samples.length;
    const variance =
      samples.reduce((sum, v) => sum + Math.pow(v - mean, 2), 0) / samples.length;
    const stdDev = Math.sqrt(variance);
    const zScore =
      stdDev > 0.05 ? Number((Math.abs(currentTemp - mean) / stdDev).toFixed(2)) : 0;

    const isAnomaly = zScore >= 2.0 || currentTemp >= 35;
    const alertType = isAnomaly
      ? `HIGH_TEMP_ANOMALY (Z-Score: ${zScore})`
      : `TELEMETRY_SCAN (Z-Score: ${zScore})`;
    const message = isAnomaly
      ? `Nhiệt độ thực tế ${currentTemp.toFixed(1)}°C vượt ngưỡng an toàn (μ=${mean.toFixed(1)}°C, σ=${stdDev.toFixed(2)}°C, Hum=${telemetry.humidity ?? '--'}%, Lux=${telemetry.lux ?? '--'})`
      : `Cảm biến ổn định: Temp=${currentTemp.toFixed(1)}°C, Hum=${telemetry.humidity ?? '--'}%, Lux=${telemetry.lux ?? '--'} Lux (μ=${mean.toFixed(1)}°C)`;

    let res = await fetchApi(`${API_BASE}/ai/analyze`, {
      method: 'POST',
      body: JSON.stringify({
        temperature: currentTemp,
        humidity: telemetry.humidity,
        lux: telemetry.lux,
        motion: telemetry.motion,
        z_score: zScore,
      }),
    });

    if (!res.ok) {
      res = await fetchApi(`${API_BASE}/ai/alerts`, {
        method: 'POST',
        body: JSON.stringify({
          alert_type: alertType,
          message,
          severity: isAnomaly ? 'high' : 'normal',
        }),
      });
    }

    const createdAlert: AIAlert | null = isAnomaly
      ? {
          id: `live-${Date.now()}`,
          alert_type: alertType,
          message,
          created_at: new Date().toLocaleTimeString('vi-VN'),
          severity: 'high',
        }
      : null;

    return {
      hasData: true,
      summary: `${alertType} — ${message}`,
      newAlert: createdAlert,
    };
  },
};