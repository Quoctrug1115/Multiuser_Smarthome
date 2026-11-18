import * as XLSX from 'xlsx';
import type { House, Room, UserAccount, UserRole } from '../types/smarthome';
import { normalizeRole } from '../services/api';

export interface ParsedHouseRow {
  rowIndex: number;
  name: string;
  address: string;
  status: 'valid' | 'exists' | 'invalid';
  note: string;
}

export interface ParsedRoomRow {
  rowIndex: number;
  house_name: string;
  name: string;
  floor: number;
  status: 'valid' | 'exists' | 'invalid';
  note: string;
}

export interface ParsedHouseRoomImport {
  houses: ParsedHouseRow[];
  rooms: ParsedRoomRow[];
}

export interface ParsedAccountRow {
  rowIndex: number;
  name: string;
  email: string;
  password: string;
  role: UserRole;
  status: 'valid' | 'exists' | 'invalid';
  note: string;
}

export interface ExportableDevice {
  id: string;
  name: string;
  device_type: string;
  mqtt_topic: string;
  room_id?: string | null;
  room_name?: string | null;
  is_on: boolean;
}

export interface ParsedDeviceRow {
  rowIndex: number;
  name: string;
  device_type: string;
  mqtt_topic: string;
  room_name: string;
  room_id: string | null;
  status: 'valid' | 'exists' | 'invalid';
  note: string;
}

function getColumnValue(row: Record<string, unknown>, keys: string[]): string {
  for (const key of Object.keys(row)) {
    const normalizedKey = key.trim().toLowerCase();
    if (keys.some((k) => normalizedKey === k.toLowerCase())) {
      const val = row[key];
      return val === undefined || val === null ? '' : String(val).trim();
    }
  }
  return '';
}

// ==================== 1. XUẤT & NHẬP EXCEL NHÀ & PHÒNG ====================

export function exportHousesAndRoomsToExcel(houses: House[], rooms: Room[]) {
  const wb = XLSX.utils.book_new();

  const houseRows = houses.map((h, index) => ({
    STT: index + 1,
    'Tên nhà': h.name,
    'Địa chỉ': h.address || '',
    'Số phòng': rooms.filter((r) => r.house_id === h.id).length,
    'ID Nhà': h.id,
  }));

  const roomRows = rooms.map((r, index) => {
    const houseName =
      r.house_name || houses.find((h) => h.id === r.house_id)?.name || '';
    return {
      STT: index + 1,
      'Tên nhà': houseName,
      'Tên phòng': r.name,
      Tầng: r.floor ?? 1,
      'ID Phòng': r.id,
    };
  });

  const wsHouses = XLSX.utils.json_to_sheet(
    houseRows.length > 0
      ? houseRows
      : [{ STT: 1, 'Tên nhà': '', 'Địa chỉ': '', 'Số phòng': 0, 'ID Nhà': '' }]
  );
  wsHouses['!cols'] = [{ wch: 6 }, { wch: 28 }, { wch: 36 }, { wch: 12 }, { wch: 38 }];

  const wsRooms = XLSX.utils.json_to_sheet(
    roomRows.length > 0
      ? roomRows
      : [{ STT: 1, 'Tên nhà': '', 'Tên phòng': '', Tầng: 1, 'ID Phòng': '' }]
  );
  wsRooms['!cols'] = [{ wch: 6 }, { wch: 28 }, { wch: 28 }, { wch: 10 }, { wch: 38 }];

  XLSX.utils.book_append_sheet(wb, wsHouses, 'Nha');
  XLSX.utils.book_append_sheet(wb, wsRooms, 'Phong');

  const dateStr = new Date().toISOString().slice(0, 10);
  XLSX.writeFile(wb, `Danh_Sach_Nha_Phong_${dateStr}.xlsx`);
}

export function downloadHouseRoomTemplate() {
  const wb = XLSX.utils.book_new();

  const sampleHouses = [
    { 'Tên nhà': 'Nhà Chính Quận 1', 'Địa chỉ': '123 Nguyễn Huệ, TP.HCM' },
    { 'Tên nhà': 'Biệt Thự Đà Lạt', 'Địa chỉ': '45 Trần Phú, Đà Lạt' },
  ];

  const sampleRooms = [
    { 'Tên nhà': 'Nhà Chính Quận 1', 'Tên phòng': 'Phòng Khách', Tầng: 1 },
    { 'Tên nhà': 'Nhà Chính Quận 1', 'Tên phòng': 'Phòng Bếp', Tầng: 1 },
    { 'Tên nhà': 'Nhà Chính Quận 1', 'Tên phòng': 'Phòng Ngủ Master', Tầng: 2 },
    { 'Tên nhà': 'Biệt Thự Đà Lạt', 'Tên phòng': 'Phòng Sinh Hoạt Chung', Tầng: 1 },
  ];

  const wsHouses = XLSX.utils.json_to_sheet(sampleHouses);
  wsHouses['!cols'] = [{ wch: 28 }, { wch: 38 }];

  const wsRooms = XLSX.utils.json_to_sheet(sampleRooms);
  wsRooms['!cols'] = [{ wch: 28 }, { wch: 28 }, { wch: 10 }];

  XLSX.utils.book_append_sheet(wb, wsHouses, 'Nha');
  XLSX.utils.book_append_sheet(wb, wsRooms, 'Phong');

  XLSX.writeFile(wb, 'Mau_Nhap_Nha_Phong.xlsx');
}

export async function parseHousesAndRoomsExcel(
  file: File,
  existingHouses: House[],
  existingRooms: Room[]
): Promise<ParsedHouseRoomImport> {
  const buffer = await file.arrayBuffer();
  const wb = XLSX.read(buffer, { type: 'array' });

  const houseSheetName =
    wb.SheetNames.find((s) =>
      ['nha', 'nhà', 'houses', 'house'].includes(s.trim().toLowerCase())
    ) || wb.SheetNames[0];

  const roomSheetName = wb.SheetNames.find((s) =>
    ['phong', 'phòng', 'rooms', 'room'].includes(s.trim().toLowerCase())
  );

  const rawHouseRows = houseSheetName
    ? XLSX.utils.sheet_to_json<Record<string, unknown>>(wb.Sheets[houseSheetName], {
        defval: '',
      })
    : [];

  const rawRoomRows = roomSheetName
    ? XLSX.utils.sheet_to_json<Record<string, unknown>>(wb.Sheets[roomSheetName], {
        defval: '',
      })
    : rawHouseRows;

  const existingHouseNames = new Set(
    existingHouses.map((h) => h.name.trim().toLowerCase())
  );
  const seenHouseNames = new Set<string>();
  const parsedHouses: ParsedHouseRow[] = [];

  rawHouseRows.forEach((row, idx) => {
    const name = getColumnValue(row, ['tên nhà', 'ten nha', 'nhà', 'house', 'house_name', 'name']);
    const address = getColumnValue(row, ['địa chỉ', 'dia chi', 'address']);

    if (!name && !address) return;

    if (!name) {
      parsedHouses.push({
        rowIndex: idx + 2,
        name: '',
        address,
        status: 'invalid',
        note: 'Thiếu tên ngôi nhà',
      });
      return;
    }

    const key = name.toLowerCase();
    if (existingHouseNames.has(key) || seenHouseNames.has(key)) {
      parsedHouses.push({
        rowIndex: idx + 2,
        name,
        address,
        status: 'exists',
        note: 'Nhà đã tồn tại (sẽ dùng nhà hiện có)',
      });
      return;
    }

    seenHouseNames.add(key);
    parsedHouses.push({
      rowIndex: idx + 2,
      name,
      address,
      status: 'valid',
      note: 'Sẵn sàng tạo mới',
    });
  });

  const allKnownHouseNames = new Set<string>([
    ...existingHouseNames,
    ...seenHouseNames,
  ]);

  const existingRoomKeys = new Set(
    existingRooms.map((r) => {
      const hName =
        r.house_name || existingHouses.find((h) => h.id === r.house_id)?.name || '';
      return `${hName.trim().toLowerCase()}::${r.name.trim().toLowerCase()}`;
    })
  );
  const seenRoomKeys = new Set<string>();
  const parsedRooms: ParsedRoomRow[] = [];

  rawRoomRows.forEach((row, idx) => {
    const houseName = getColumnValue(row, [
      'tên nhà',
      'ten nha',
      'nhà',
      'house',
      'house_name',
    ]);
    const roomName = getColumnValue(row, [
      'tên phòng',
      'ten phong',
      'phòng',
      'room',
      'room_name',
      ...(roomSheetName ? ['name'] : []),
    ]);
    const floorRaw = getColumnValue(row, ['tầng', 'tang', 'floor']);
    const floor = floorRaw && !Number.isNaN(Number(floorRaw)) ? Number(floorRaw) : 1;

    if (!roomName) return;

    const targetHouseName =
      houseName || (existingHouses.length === 1 ? existingHouses[0].name : '');

    if (!targetHouseName) {
      parsedRooms.push({
        rowIndex: idx + 2,
        house_name: '',
        name: roomName,
        floor,
        status: 'invalid',
        note: 'Thiếu tên ngôi nhà trực thuộc',
      });
      return;
    }

    if (!allKnownHouseNames.has(targetHouseName.toLowerCase())) {
      parsedRooms.push({
        rowIndex: idx + 2,
        house_name: targetHouseName,
        name: roomName,
        floor,
        status: 'invalid',
        note: `Không tìm thấy nhà "${targetHouseName}"`,
      });
      return;
    }

    const roomKey = `${targetHouseName.toLowerCase()}::${roomName.toLowerCase()}`;
    if (existingRoomKeys.has(roomKey) || seenRoomKeys.has(roomKey)) {
      parsedRooms.push({
        rowIndex: idx + 2,
        house_name: targetHouseName,
        name: roomName,
        floor,
        status: 'exists',
        note: 'Phòng đã tồn tại trong nhà này',
      });
      return;
    }

    seenRoomKeys.add(roomKey);
    parsedRooms.push({
      rowIndex: idx + 2,
      house_name: targetHouseName,
      name: roomName,
      floor,
      status: 'valid',
      note: 'Sẵn sàng tạo mới',
    });
  });

  return { houses: parsedHouses, rooms: parsedRooms };
}

// ==================== 2. XUẤT & NHẬP EXCEL THIẾT BỊ IOT ====================

export function exportDevicesToExcel(devices: ExportableDevice[], rooms: Room[]) {
  const wb = XLSX.utils.book_new();

  const rows = devices.map((d, idx) => {
    const roomName =
      d.room_name || rooms.find((r) => r.id === d.room_id)?.name || 'Chưa phân phòng';
    return {
      STT: idx + 1,
      'Tên thiết bị': d.name,
      'Loại thiết bị': d.device_type,
      'MQTT Topic': d.mqtt_topic,
      'Tên phòng': roomName,
      'Trạng thái': d.is_on ? 'ON' : 'OFF',
      'ID Thiết bị': d.id,
    };
  });

  const ws = XLSX.utils.json_to_sheet(
    rows.length > 0
      ? rows
      : [
          {
            STT: 1,
            'Tên thiết bị': '',
            'Loại thiết bị': 'light',
            'MQTT Topic': '',
            'Tên phòng': '',
            'Trạng thái': 'OFF',
            'ID Thiết bị': '',
          },
        ]
  );
  ws['!cols'] = [
    { wch: 6 },
    { wch: 28 },
    { wch: 16 },
    { wch: 36 },
    { wch: 24 },
    { wch: 12 },
    { wch: 38 },
  ];

  XLSX.utils.book_append_sheet(wb, ws, 'ThietBi');
  const dateStr = new Date().toISOString().slice(0, 10);
  XLSX.writeFile(wb, `Danh_Sach_Thiet_Bi_${dateStr}.xlsx`);
}

export function downloadDeviceTemplate(rooms: Room[]) {
  const wb = XLSX.utils.book_new();
  const sampleRoomName = rooms[0]?.name || 'Phòng Khách';

  const sampleDevices = [
    {
      'Tên thiết bị': 'Đèn Trần Phòng Khách',
      'Loại thiết bị': 'light',
      'MQTT Topic': 'smarthome/devices/den_tran_pk',
      'Tên phòng': sampleRoomName,
    },
    {
      'Tên thiết bị': 'Quạt Hút Mùi Bếp',
      'Loại thiết bị': 'fan',
      'MQTT Topic': 'smarthome/devices/quat_bep',
      'Tên phòng': rooms[1]?.name || '',
    },
    {
      'Tên thiết bị': 'Công Tắc Ban Công',
      'Loại thiết bị': 'switch',
      'MQTT Topic': 'smarthome/devices/cong_tac_ban_cong',
      'Tên phòng': '',
    },
  ];

  const ws = XLSX.utils.json_to_sheet(sampleDevices);
  ws['!cols'] = [{ wch: 28 }, { wch: 16 }, { wch: 36 }, { wch: 24 }];
  XLSX.utils.book_append_sheet(wb, ws, 'ThietBi');
  XLSX.writeFile(wb, 'Mau_Nhap_Thiet_Bi.xlsx');
}

export async function parseDevicesExcel(
  file: File,
  existingDevices: ExportableDevice[],
  existingRooms: Room[]
): Promise<ParsedDeviceRow[]> {
  const buffer = await file.arrayBuffer();
  const wb = XLSX.read(buffer, { type: 'array' });

  const sheetName =
    wb.SheetNames.find((s) =>
      ['thietbi', 'thiết bị', 'devices', 'device'].includes(s.trim().toLowerCase())
    ) || wb.SheetNames[0];

  if (!sheetName) return [];

  const rawRows = XLSX.utils.sheet_to_json<Record<string, unknown>>(
    wb.Sheets[sheetName],
    { defval: '' }
  );

  const existingTopics = new Set(
    existingDevices.map((d) => d.mqtt_topic.trim().toLowerCase())
  );
  const seenTopics = new Set<string>();

  const roomMap = new Map<string, string>();
  existingRooms.forEach((r) => roomMap.set(r.name.trim().toLowerCase(), r.id));

  const validTypes = new Set(['light', 'fan', 'switch', 'sensor']);
  const parsed: ParsedDeviceRow[] = [];

  rawRows.forEach((row, idx) => {
    const name = getColumnValue(row, [
      'tên thiết bị',
      'ten thiet bi',
      'thiết bị',
      'device',
      'name',
    ]);
    const rawType = getColumnValue(row, [
      'loại thiết bị',
      'loai thiet bi',
      'loại',
      'device_type',
      'type',
    ]).toLowerCase();
    const mqttTopic = getColumnValue(row, [
      'mqtt topic',
      'topic',
      'mqtt_topic',
    ]);
    const roomName = getColumnValue(row, [
      'tên phòng',
      'ten phong',
      'phòng',
      'room',
      'room_name',
    ]);

    if (!name && !mqttTopic && !roomName) return;

    const normalizedType = validTypes.has(rawType) ? rawType : 'switch';

    if (!name || !mqttTopic) {
      parsed.push({
        rowIndex: idx + 2,
        name,
        device_type: normalizedType,
        mqtt_topic: mqttTopic,
        room_name: roomName,
        room_id: null,
        status: 'invalid',
        note: 'Thiếu Tên thiết bị hoặc MQTT Topic',
      });
      return;
    }

    const topicKey = mqttTopic.toLowerCase();
    if (existingTopics.has(topicKey) || seenTopics.has(topicKey)) {
      parsed.push({
        rowIndex: idx + 2,
        name,
        device_type: normalizedType,
        mqtt_topic: mqttTopic,
        room_name: roomName,
        room_id: null,
        status: 'exists',
        note: 'MQTT Topic đã tồn tại trong hệ thống',
      });
      return;
    }

    let resolvedRoomId: string | null = null;
    if (roomName && roomName.toLowerCase() !== 'chưa phân phòng') {
      const foundId = roomMap.get(roomName.toLowerCase());
      if (!foundId) {
        parsed.push({
          rowIndex: idx + 2,
          name,
          device_type: normalizedType,
          mqtt_topic: mqttTopic,
          room_name: roomName,
          room_id: null,
          status: 'invalid',
          note: `Không tìm thấy phòng "${roomName}"`,
        });
        return;
      }
      resolvedRoomId = foundId;
    }

    seenTopics.add(topicKey);
    parsed.push({
      rowIndex: idx + 2,
      name,
      device_type: normalizedType,
      mqtt_topic: mqttTopic,
      room_name: roomName || 'Chưa phân phòng',
      room_id: resolvedRoomId,
      status: 'valid',
      note: 'Sẵn sàng tạo mới',
    });
  });

  return parsed;
}

// ==================== 3. XUẤT & NHẬP EXCEL TÀI KHOẢN ====================

export function exportAccountsToExcel(users: UserAccount[]) {
  const wb = XLSX.utils.book_new();

  const rows = users.map((u, idx) => ({
    STT: idx + 1,
    'Họ và tên': u.name,
    Email: u.email,
    'Vai trò': u.role,
    'Ngày tạo': u.created_at || '',
    'ID Tài khoản': u.id,
  }));

  const ws = XLSX.utils.json_to_sheet(
    rows.length > 0
      ? rows
      : [
          {
            STT: 1,
            'Họ và tên': '',
            Email: '',
            'Vai trò': 'Member',
            'Ngày tạo': '',
            'ID Tài khoản': '',
          },
        ]
  );
  ws['!cols'] = [{ wch: 6 }, { wch: 26 }, { wch: 30 }, { wch: 14 }, { wch: 24 }, { wch: 38 }];

  XLSX.utils.book_append_sheet(wb, ws, 'TaiKhoan');

  const dateStr = new Date().toISOString().slice(0, 10);
  XLSX.writeFile(wb, `Danh_Sach_Tai_Khoan_${dateStr}.xlsx`);
}

export function downloadAccountTemplate() {
  const wb = XLSX.utils.book_new();

  const sampleAccounts = [
    {
      'Họ và tên': 'Nguyễn Văn An',
      Email: 'nguyenvanan@gmail.com',
      'Mật khẩu': '123456',
      'Vai trò': 'Member',
    },
    {
      'Họ và tên': 'Trần Thị Bình',
      Email: 'tranthibinh@gmail.com',
      'Mật khẩu': '123456',
      'Vai trò': 'Guest',
    },
    {
      'Họ và tên': 'Lê Quản Trị',
      Email: 'lequantri@gmail.com',
      'Mật khẩu': 'Admin@123',
      'Vai trò': 'Admin',
    },
  ];

  const ws = XLSX.utils.json_to_sheet(sampleAccounts);
  ws['!cols'] = [{ wch: 26 }, { wch: 30 }, { wch: 18 }, { wch: 14 }];

  XLSX.utils.book_append_sheet(wb, ws, 'TaiKhoan');
  XLSX.writeFile(wb, 'Mau_Nhap_Tai_Khoan.xlsx');
}

export async function parseAccountsExcel(
  file: File,
  existingUsers: UserAccount[]
): Promise<ParsedAccountRow[]> {
  const buffer = await file.arrayBuffer();
  const wb = XLSX.read(buffer, { type: 'array' });

  const sheetName =
    wb.SheetNames.find((s) =>
      ['taikhoan', 'tài khoản', 'users', 'accounts', 'user'].includes(
        s.trim().toLowerCase()
      )
    ) || wb.SheetNames[0];

  if (!sheetName) return [];

  const rawRows = XLSX.utils.sheet_to_json<Record<string, unknown>>(
    wb.Sheets[sheetName],
    { defval: '' }
  );

  const existingEmails = new Set(
    existingUsers.map((u) => u.email.trim().toLowerCase())
  );
  const seenEmails = new Set<string>();
  const parsed: ParsedAccountRow[] = [];

  rawRows.forEach((row, idx) => {
    const name = getColumnValue(row, [
      'họ và tên',
      'ho va ten',
      'họ tên',
      'tên',
      'name',
      'full_name',
    ]);
    const email = getColumnValue(row, ['email', 'e-mail', 'tài khoản']);
    const passwordRaw = getColumnValue(row, ['mật khẩu', 'mat khau', 'password', 'pass']);
    const roleRaw = getColumnValue(row, ['vai trò', 'vai tro', 'role', 'quyền']);

    if (!name && !email && !passwordRaw) return;

    if (!name || !email) {
      parsed.push({
        rowIndex: idx + 2,
        name,
        email,
        password: passwordRaw || '123456',
        role: normalizeRole(roleRaw),
        status: 'invalid',
        note: 'Thiếu Họ tên hoặc Email',
      });
      return;
    }

    const emailRegex = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
    if (!emailRegex.test(email)) {
      parsed.push({
        rowIndex: idx + 2,
        name,
        email,
        password: passwordRaw || '123456',
        role: normalizeRole(roleRaw),
        status: 'invalid',
        note: 'Email không đúng định dạng',
      });
      return;
    }

    const emailKey = email.toLowerCase();
    if (existingEmails.has(emailKey) || seenEmails.has(emailKey)) {
      parsed.push({
        rowIndex: idx + 2,
        name,
        email,
        password: passwordRaw || '123456',
        role: normalizeRole(roleRaw),
        status: 'exists',
        note: 'Email đã tồn tại trong hệ thống',
      });
      return;
    }

    seenEmails.add(emailKey);
    const finalPassword = passwordRaw || '123456';
    parsed.push({
      rowIndex: idx + 2,
      name,
      email,
      password: finalPassword,
      role: normalizeRole(roleRaw),
      status: 'valid',
      note: passwordRaw ? 'Sẵn sàng tạo mới' : 'Dùng mật khẩu mặc định: 123456',
    });
  });

  return parsed;
}