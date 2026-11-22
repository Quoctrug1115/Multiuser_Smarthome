import React, { useMemo, useRef, useState } from 'react';
import type {
  Device,
  ExcelSpacePreviewItem,
  House,
  Room,
  SensorData,
} from '../../types/smarthome';
import { API_BASE, getAuthHeaders } from '../../utils/api';
import { getXlsxLib, normalizeExcelKey, readAllExcelSheets } from '../../utils/excelHelpers';

interface DevicesTabProps {
  houses: House[];
  rooms: Room[];
  devices: Device[];
  sensorData: SensorData | null;
  isOwnerOrAdmin: boolean;
  cardBg: string;
  inputBg: string;
  appendLog: (msg: string) => void;
  onRefresh: () => Promise<void>;
  onToggleDevice: (device: Device) => void;
}

export function DevicesTab({
  houses,
  rooms,
  devices,
  sensorData,
  isOwnerOrAdmin,
  cardBg,
  inputBg,
  appendLog,
  onRefresh,
  onToggleDevice,
}: DevicesTabProps) {
  const hasLiveSensor = sensorData !== null && devices.length > 0;

  // Filter states
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

  // Excel Preview States
  const fileInputRef = useRef<HTMLInputElement | null>(null);
  const [excelPreviewSpace, setExcelPreviewSpace] = useState<ExcelSpacePreviewItem[]>([]);
  const [spaceExcelFileName, setSpaceExcelFileName] = useState<string>('');
  const [isImportingSpace, setIsImportingSpace] = useState<boolean>(false);

  // ==================== HOUSE HANDLERS ====================
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
      onRefresh();
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
      onRefresh();
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
      onRefresh();
    }
  };

  // ==================== ROOM HANDLERS ====================
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
      onRefresh();
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
      onRefresh();
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
      onRefresh();
    }
  };

  // ==================== DEVICE HANDLERS ====================
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
      onRefresh();
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
      onRefresh();
    } else {
      const err = await res.json().catch(() => ({}));
      alert(err.error || 'Không thể cập nhật thiết bị');
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
      onRefresh();
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

  // ==================== EXCEL EXPORT & IMPORT ====================
  const handleExportExcel = () => {
    const xlsxLib = getXlsxLib();
    const workbook = xlsxLib.utils.book_new();

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
              MqttTopic: 'smarthome/A4CF128B90E1/light',
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
      await onRefresh();

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

  // ==================== FILTERED LISTS ====================
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

  return (
    <div className="space-y-6">
      {/* Top Toolbar */}
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div>
          <h1 className="text-lg font-bold">Quản lý Không gian Nhà, Phòng & Thiết bị IoT</h1>
          <p className="text-xs text-slate-400">
            Hỗ trợ nhập/xuất hàng loạt qua Excel (Sheet 1: TenNha, DiaChi, TenPhong, Tang • Sheet 2:
            TenThietBi, LoaiThietBi, MqttTopic, Phong)
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
              {discoveringDevices ? 'Đang quét...' : 'Quét thiết bị'}
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
              Nhập Excel
            </button>
            <button
              type="button"
              onClick={handleExportExcel}
              className="px-3.5 py-2 rounded-xl bg-cyan-500/15 border border-cyan-500/30 text-cyan-400 hover:bg-cyan-500/25 text-xs font-semibold transition"
            >
              Xuất Excel
            </button>
          </div>
        )}
      </div>

      {/* Excel / Discovery Preview Table */}
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
                      <strong className="text-slate-200">{excelPreviewSpace.length}</strong> dòng
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
                        className={item.isValid ? 'bg-emerald-500/5' : 'bg-rose-500/5 opacity-80'}
                      >
                        <td className="p-2.5 font-mono text-slate-400">
                          {item.sheetName} #{item.rowNumber}
                        </td>
                        <td className="p-2.5">
                          {item.kind === 'house' && (
                            <span className="px-2 py-0.5 rounded bg-cyan-500/15 text-cyan-400 font-semibold">
                              Ngôi nhà
                            </span>
                          )}
                          {item.kind === 'room' && (
                            <span className="px-2 py-0.5 rounded bg-amber-500/15 text-amber-400 font-semibold">
                              Phòng
                            </span>
                          )}
                          {item.kind === 'device' && (
                            <span className="px-2 py-0.5 rounded bg-emerald-500/15 text-emerald-400 font-semibold">
                              🔌 Thiết bị
                            </span>
                          )}
                        </td>
                        <td className="p-2.5 font-bold">
                          {item.name || <span className="text-rose-400 italic">(Trống)</span>}
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
                            <span className="text-rose-400 font-medium">✕ {item.errorReason}</span>
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

      {/* Forms Create House / Room / Device */}
      {isOwnerOrAdmin && (
        <div className="grid grid-cols-1 lg:grid-cols-3 gap-4">
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

          <form
            onSubmit={handleCreateDevice}
            className={`p-4 rounded-2xl border space-y-3 ${cardBg}`}
          >
            <h3 className="font-bold text-xs text-emerald-400 uppercase">+ Thêm Thiết bị IoT</h3>
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
                placeholder="MQTT Topic (smarthome/{chip_id}/light)"
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

      {/* Inline Edit Forms */}
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
            onChange={(e) => setEditingRoom({ ...editingRoom, floor: Number(e.target.value) })}
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
                {h.name}
              </button>
              {isOwnerOrAdmin && (
                <>
                  <button
                    onClick={() => setEditingHouse(h)}
                    className="text-sky-400 hover:text-sky-300 text-[11px]"
                    title="Sửa nhà"
                  >
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
                {r.name} (T{r.floor})
              </button>
              {isOwnerOrAdmin && (
                <>
                  <button
                    onClick={() => setEditingRoom(r)}
                    className="text-sky-400 hover:text-sky-300 text-[11px]"
                    title="Sửa phòng"
                  >
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

      {/* Devices Grid */}
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
                    <span className="text-xs font-bold text-cyan-400">✏️ Chỉnh sửa thiết bị</span>
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
                      <label className="block text-[11px] text-slate-400 mb-1">Tên thiết bị</label>
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
                            setEditingDevice({ ...editingDevice, device_type: e.target.value })
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
                        <label className="block text-[11px] text-slate-400 mb-1">Phòng</label>
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
                      <label className="block text-[11px] text-slate-400 mb-1">MQTT Topic</label>
                      <input
                        type="text"
                        required
                        value={editingDevice.mqtt_topic}
                        onChange={(e) =>
                          setEditingDevice({ ...editingDevice, mqtt_topic: e.target.value })
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
                    <div className="text-xs text-slate-400 mt-0.5 flex flex-wrap items-center gap-2">
                      <span>
                        {dev.room_name || 'Chưa phân phòng'} •{' '}
                        <span className="uppercase text-cyan-400">{dev.device_type}</span>
                      </span>
                      <span
                        className={`px-1.5 py-0.5 rounded text-[10px] font-semibold ${
                          dev.is_online === false
                            ? 'bg-rose-500/20 text-rose-300'
                            : 'bg-emerald-500/15 text-emerald-300'
                        }`}
                      >
                        {dev.is_online === false ? '● OFFLINE' : '● ONLINE'}
                      </span>
                    </div>
                    <div className="text-[11px] font-mono text-slate-500 mt-1 truncate">
                      {dev.mqtt_topic}
                    </div>

                    {dev.device_type === 'sensor' && (
                      <div className="mt-2 flex flex-wrap items-center gap-1.5 text-[11px] font-mono">
                        {hasLiveSensor && sensorData ? (
                          <>
                            <span className="px-2 py-0.5 rounded bg-amber-500/15 text-amber-300">
                              {sensorData.temperature.toFixed(1)}°C
                            </span>
                            <span className="px-2 py-0.5 rounded bg-cyan-500/15 text-cyan-300">
                              {sensorData.humidity.toFixed(0)}%
                            </span>
                            <span className="px-2 py-0.5 rounded bg-emerald-500/15 text-emerald-300">
                              {sensorData.lux} Lux
                            </span>
                            <span
                              className={`px-2 py-0.5 rounded ${
                                sensorData.motion
                                  ? 'bg-rose-500/20 text-rose-300'
                                  : 'bg-slate-800 text-slate-400'
                              }`}
                            >
                              {sensorData.motion ? 'Có người' : 'Yên tĩnh'}
                            </span>
                          </>
                        ) : (
                          <span className="px-2 py-0.5 rounded bg-slate-800 text-slate-400">
                            Đang chờ gói tin MQTT...
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
                  disabled={dev.is_online === false}
                  onClick={() => onToggleDevice(dev)}
                  className={`w-full py-2 rounded-xl font-bold text-xs transition ${
                    dev.is_online === false
                      ? 'bg-slate-800/60 text-slate-500 cursor-not-allowed'
                      : dev.is_on
                      ? 'bg-emerald-500 text-slate-950'
                      : 'bg-slate-800 text-slate-300 hover:bg-slate-700'
                  }`}
                >
                  {dev.is_online === false
                    ? '⚠ THIẾT BỊ MẤT KẾT NỐI'
                    : dev.is_on
                    ? '● ĐANG BẬT (Nhấn để TẮT)'
                    : '○ ĐANG TẮT (Nhấn để BẬT)'}
                </button>
              </div>
            );
          })
        )}
      </div>
    </div>
  );
}