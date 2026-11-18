import React, { useState, useRef } from 'react';
import type { House, Room, UserAccount } from '../types/smarthome';
import { SmartHomeApi } from '../services/api';
import {
  downloadAccountTemplate,
  downloadDeviceTemplate,
  downloadHouseRoomTemplate,
  parseAccountsExcel,
  parseDevicesExcel,
  parseHousesAndRoomsExcel,
  type ExportableDevice,
  type ParsedAccountRow,
  type ParsedDeviceRow,
  type ParsedHouseRoomImport,
} from '../utils/excelService';

export type ExcelImportMode = 'houses_rooms' | 'accounts' | 'devices';

export const ExcelImportModal: React.FC<{
  isOpen: boolean;
  isDark: boolean;
  mode: ExcelImportMode;
  houses: House[];
  rooms: Room[];
  devices?: ExportableDevice[];
  users: UserAccount[];
  ownerId: string;
  onClose: () => void;
  onSuccess: (summaryMsg: string) => Promise<void>;
}> = ({
  isOpen,
  isDark,
  mode,
  houses,
  rooms,
  devices = [],
  users,
  ownerId,
  onClose,
  onSuccess,
}) => {
  const fileInputRef = useRef<HTMLInputElement | null>(null);
  const [fileName, setFileName] = useState('');
  const [houseRoomPreview, setHouseRoomPreview] = useState<ParsedHouseRoomImport | null>(null);
  const [accountPreview, setAccountPreview] = useState<ParsedAccountRow[] | null>(null);
  const [devicePreview, setDevicePreview] = useState<ParsedDeviceRow[] | null>(null);
  const [isImporting, setIsImporting] = useState(false);
  const [importError, setImportError] = useState('');

  if (!isOpen) return null;

  const resetState = () => {
    setFileName('');
    setHouseRoomPreview(null);
    setAccountPreview(null);
    setDevicePreview(null);
    setImportError('');
    if (fileInputRef.current) fileInputRef.current.value = '';
  };

  const handleClose = () => {
    if (isImporting) return;
    resetState();
    onClose();
  };

  const handleFileChange = async (e: React.ChangeEvent<HTMLInputElement>) => {
    const file = e.target.files?.[0];
    if (!file) return;

    setFileName(file.name);
    setImportError('');

    try {
      if (mode === 'houses_rooms') {
        const parsed = await parseHousesAndRoomsExcel(file, houses, rooms);
        setHouseRoomPreview(parsed);
      } else if (mode === 'devices') {
        const parsed = await parseDevicesExcel(file, devices, rooms);
        setDevicePreview(parsed);
      } else {
        const parsed = await parseAccountsExcel(file, users);
        setAccountPreview(parsed);
      }
    } catch (err) {
      setImportError(
        err instanceof Error
          ? `Không thể đọc file Excel: ${err.message}`
          : 'Định dạng file Excel không hợp lệ.'
      );
    }
  };

  const handleConfirmImport = async () => {
    setIsImporting(true);
    setImportError('');

    try {
      if (mode === 'houses_rooms' && houseRoomPreview) {
        let createdHouses = 0;
        let createdRooms = 0;
        const errors: string[] = [];

        for (const h of houseRoomPreview.houses.filter((item) => item.status === 'valid')) {
          const res = await SmartHomeApi.createHouse({
            name: h.name,
            address: h.address,
            owner_id: ownerId,
          });
          if (res.ok) {
            createdHouses++;
          } else {
            errors.push(`Nhà "${h.name}": ${res.error || 'Lỗi tạo nhà'}`);
          }
        }

        const latestHouses = await SmartHomeApi.getHouses();
        const houseMap = new Map<string, string>();
        latestHouses.forEach((h) => houseMap.set(h.name.trim().toLowerCase(), h.id));

        for (const r of houseRoomPreview.rooms.filter((item) => item.status === 'valid')) {
          const targetHouseId = houseMap.get(r.house_name.trim().toLowerCase());
          if (!targetHouseId) {
            errors.push(`Phòng "${r.name}": Không tìm thấy ID của nhà "${r.house_name}"`);
            continue;
          }

          const res = await SmartHomeApi.createRoom({
            house_id: targetHouseId,
            name: r.name,
            floor: r.floor,
          });
          if (res.ok) {
            createdRooms++;
          } else {
            errors.push(`Phòng "${r.name}": ${res.error || 'Lỗi tạo phòng'}`);
          }
        }

        if (errors.length > 0 && createdHouses === 0 && createdRooms === 0) {
          setImportError(errors.join(' | '));
          setIsImporting(false);
          return;
        }

        const msg = `EXCEL IMPORT: Đã thêm ${createdHouses} nhà và ${createdRooms} phòng vào Database.`;
        resetState();
        await onSuccess(msg);
        onClose();
      } else if (mode === 'devices' && devicePreview) {
        let createdDevices = 0;
        const errors: string[] = [];
        const token = localStorage.getItem('token');

        for (const d of devicePreview.filter((item) => item.status === 'valid')) {
          const res = await fetch('http://localhost:3000/api/v1/devices', {
            method: 'POST',
            headers: {
              'Content-Type': 'application/json',
              ...(token && token !== 'authenticated'
                ? { Authorization: `Bearer ${token}` }
                : {}),
            },
            body: JSON.stringify({
              name: d.name,
              device_type: d.device_type,
              mqtt_topic: d.mqtt_topic,
              room_id: d.room_id,
            }),
          });
          if (res.ok) {
            createdDevices++;
          } else {
            errors.push(`Thiết bị "${d.name}": Lỗi (${res.status})`);
          }
        }

        if (errors.length > 0 && createdDevices === 0) {
          setImportError(errors.join(' | '));
          setIsImporting(false);
          return;
        }

        const msg = `EXCEL IMPORT: Đã thêm ${createdDevices} thiết bị IoT vào Database.`;
        resetState();
        await onSuccess(msg);
        onClose();
      } else if (mode === 'accounts' && accountPreview) {
        let createdUsers = 0;
        const errors: string[] = [];

        for (const acc of accountPreview.filter((item) => item.status === 'valid')) {
          const res = await SmartHomeApi.createUserAccount({
            name: acc.name,
            email: acc.email,
            password: acc.password,
            role: acc.role,
          });
          if (res.ok) {
            createdUsers++;
          } else {
            errors.push(`${acc.email}: ${res.error || 'Lỗi tạo tài khoản'}`);
          }
        }

        if (errors.length > 0 && createdUsers === 0) {
          setImportError(errors.join(' | '));
          setIsImporting(false);
          return;
        }

        const msg = `EXCEL IMPORT: Đã tạo thành công ${createdUsers} tài khoản mới.`;
        resetState();
        await onSuccess(msg);
        onClose();
      }
    } catch (err) {
      setImportError(
        err instanceof Error ? err.message : 'Đã xảy ra lỗi khi nhập dữ liệu Excel.'
      );
    } finally {
      setIsImporting(false);
    }
  };

  const validHouseCount =
    houseRoomPreview?.houses.filter((h) => h.status === 'valid').length ?? 0;
  const validRoomCount =
    houseRoomPreview?.rooms.filter((r) => r.status === 'valid').length ?? 0;
  const validDeviceCount =
    devicePreview?.filter((d) => d.status === 'valid').length ?? 0;
  const validAccountCount =
    accountPreview?.filter((a) => a.status === 'valid').length ?? 0;

  const totalValidToImport =
    mode === 'houses_rooms'
      ? validHouseCount + validRoomCount
      : mode === 'devices'
      ? validDeviceCount
      : validAccountCount;

  const badgeClass = (status: 'valid' | 'exists' | 'invalid') => {
    if (status === 'valid')
      return 'bg-emerald-500/15 text-emerald-400 border border-emerald-500/30';
    if (status === 'exists')
      return 'bg-amber-500/15 text-amber-400 border border-amber-500/30';
    return 'bg-red-500/15 text-red-400 border border-red-500/30';
  };

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/65 p-4">
      <div
        className={`w-full max-w-3xl rounded-2xl border p-6 shadow-2xl max-h-[90vh] flex flex-col ${
          isDark
            ? 'bg-[#0d131f] border-slate-800 text-slate-100'
            : 'bg-white border-slate-200 text-slate-800'
        }`}
      >
        <div className="flex justify-between items-center pb-3 border-b border-slate-800/60">
          <div>
            <h3 className="text-sm font-bold flex items-center gap-2">
              <span>📥</span>
              <span>
                {mode === 'houses_rooms'
                  ? 'Nhập dữ liệu Nhà & Phòng từ Excel (.xlsx)'
                  : mode === 'devices'
                  ? 'Nhập danh sách Thiết bị IoT từ Excel (.xlsx)'
                  : 'Nhập dữ liệu Tài khoản từ Excel (.xlsx)'}
              </span>
            </h3>
            <p className="text-[11px] text-slate-400 mt-0.5">
              {mode === 'houses_rooms'
                ? 'Hỗ trợ file Excel gồm 2 sheet "Nha" (Tên nhà, Địa chỉ) và "Phong" (Tên nhà, Tên phòng, Tầng).'
                : mode === 'devices'
                ? 'Hỗ trợ file Excel gồm các cột: Tên thiết bị, Loại thiết bị (light/fan/switch/sensor), MQTT Topic, Tên phòng.'
                : 'Hỗ trợ file Excel gồm các cột: Họ và tên, Email, Mật khẩu, Vai trò (Admin / Member / Guest).'}
            </p>
          </div>
          <button
            onClick={handleClose}
            className="text-xs text-slate-400 hover:text-slate-200 px-2 py-1"
          >
            ✕
          </button>
        </div>

        <div className="py-4 space-y-4 overflow-y-auto flex-1">
          <div
            className={`p-4 rounded-xl border border-dashed flex flex-wrap items-center justify-between gap-3 ${
              isDark
                ? 'bg-slate-900/60 border-slate-700'
                : 'bg-slate-50 border-slate-300'
            }`}
          >
            <div className="flex items-center gap-3">
              <input
                ref={fileInputRef}
                type="file"
                accept=".xlsx,.xls,.csv"
                onChange={handleFileChange}
                className="hidden"
              />
              <button
                type="button"
                onClick={() => fileInputRef.current?.click()}
                className="px-3.5 py-2 rounded-lg bg-cyan-500 hover:bg-cyan-400 text-slate-950 font-bold text-xs transition"
              >
                📂 Chọn file Excel
              </button>
              <span className="text-xs font-mono text-slate-400">
                {fileName || 'Chưa chọn file (.xlsx, .xls, .csv)'}
              </span>
            </div>

            <button
              type="button"
              onClick={() => {
                if (mode === 'houses_rooms') downloadHouseRoomTemplate();
                else if (mode === 'devices') downloadDeviceTemplate(rooms);
                else downloadAccountTemplate();
              }}
              className={`px-3 py-1.5 rounded-lg border text-xs font-semibold transition ${
                isDark
                  ? 'bg-slate-800 border-slate-700 text-cyan-400 hover:bg-slate-700'
                  : 'bg-white border-slate-300 text-sky-700 hover:bg-slate-100'
              }`}
            >
              📄 Tải file Excel mẫu
            </button>
          </div>

          {importError && (
            <div className="p-3 rounded-lg bg-red-500/15 border border-red-500/40 text-red-400 text-xs">
              {importError}
            </div>
          )}

          {/* BẢNG XEM TRƯỚC NHÀ & PHÒNG */}
          {mode === 'houses_rooms' && houseRoomPreview && (
            <div className="space-y-4">
              <div>
                <div className="text-xs font-bold mb-2">
                  1. Danh sách Nhà đọc được ({houseRoomPreview.houses.length} dòng •{' '}
                  <span className="text-emerald-400">{validHouseCount} hợp lệ</span>)
                </div>
                <div className="overflow-x-auto rounded-lg border border-slate-800">
                  <table className="w-full text-left text-xs">
                    <thead
                      className={
                        isDark ? 'bg-slate-900 text-slate-300' : 'bg-slate-100 text-slate-700'
                      }
                    >
                      <tr>
                        <th className="p-2.5">Dòng</th>
                        <th className="p-2.5">Tên nhà</th>
                        <th className="p-2.5">Địa chỉ</th>
                        <th className="p-2.5">Trạng thái</th>
                      </tr>
                    </thead>
                    <tbody className="divide-y divide-slate-800/60">
                      {houseRoomPreview.houses.map((h, i) => (
                        <tr key={i}>
                          <td className="p-2.5 font-mono text-slate-400">{h.rowIndex}</td>
                          <td className="p-2.5 font-bold">{h.name || '--'}</td>
                          <td className="p-2.5 text-slate-400">{h.address || '--'}</td>
                          <td className="p-2.5">
                            <span
                              className={`px-2 py-0.5 rounded text-[10px] font-semibold ${badgeClass(
                                h.status
                              )}`}
                            >
                              {h.note}
                            </span>
                          </td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>
              </div>

              <div>
                <div className="text-xs font-bold mb-2">
                  2. Danh sách Phòng đọc được ({houseRoomPreview.rooms.length} dòng •{' '}
                  <span className="text-emerald-400">{validRoomCount} hợp lệ</span>)
                </div>
                <div className="overflow-x-auto rounded-lg border border-slate-800">
                  <table className="w-full text-left text-xs">
                    <thead
                      className={
                        isDark ? 'bg-slate-900 text-slate-300' : 'bg-slate-100 text-slate-700'
                      }
                    >
                      <tr>
                        <th className="p-2.5">Dòng</th>
                        <th className="p-2.5">Thuộc nhà</th>
                        <th className="p-2.5">Tên phòng</th>
                        <th className="p-2.5">Tầng</th>
                        <th className="p-2.5">Trạng thái</th>
                      </tr>
                    </thead>
                    <tbody className="divide-y divide-slate-800/60">
                      {houseRoomPreview.rooms.map((r, i) => (
                        <tr key={i}>
                          <td className="p-2.5 font-mono text-slate-400">{r.rowIndex}</td>
                          <td className="p-2.5">{r.house_name || '--'}</td>
                          <td className="p-2.5 font-bold">{r.name}</td>
                          <td className="p-2.5 font-mono">Tầng {r.floor}</td>
                          <td className="p-2.5">
                            <span
                              className={`px-2 py-0.5 rounded text-[10px] font-semibold ${badgeClass(
                                r.status
                              )}`}
                            >
                              {r.note}
                            </span>
                          </td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>
              </div>
            </div>
          )}

          {/* BẢNG XEM TRƯỚC THIẾT BỊ IOT */}
          {mode === 'devices' && devicePreview && (
            <div>
              <div className="text-xs font-bold mb-2">
                Danh sách Thiết bị đọc được ({devicePreview.length} dòng •{' '}
                <span className="text-emerald-400">{validDeviceCount} hợp lệ</span>)
              </div>
              <div className="overflow-x-auto rounded-lg border border-slate-800">
                <table className="w-full text-left text-xs">
                  <thead
                    className={
                      isDark ? 'bg-slate-900 text-slate-300' : 'bg-slate-100 text-slate-700'
                    }
                  >
                    <tr>
                      <th className="p-2.5">Dòng</th>
                      <th className="p-2.5">Tên thiết bị</th>
                      <th className="p-2.5">Loại</th>
                      <th className="p-2.5">MQTT Topic</th>
                      <th className="p-2.5">Phòng</th>
                      <th className="p-2.5">Trạng thái</th>
                    </tr>
                  </thead>
                  <tbody className="divide-y divide-slate-800/60">
                    {devicePreview.map((d, i) => (
                      <tr key={i}>
                        <td className="p-2.5 font-mono text-slate-400">{d.rowIndex}</td>
                        <td className="p-2.5 font-bold">{d.name || '--'}</td>
                        <td className="p-2.5">{d.device_type}</td>
                        <td className="p-2.5 font-mono">{d.mqtt_topic || '--'}</td>
                        <td className="p-2.5">{d.room_name}</td>
                        <td className="p-2.5">
                          <span
                            className={`px-2 py-0.5 rounded text-[10px] font-semibold ${badgeClass(
                              d.status
                            )}`}
                          >
                            {d.note}
                          </span>
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            </div>
          )}

          {/* BẢNG XEM TRƯỚC TÀI KHOẢN */}
          {mode === 'accounts' && accountPreview && (
            <div>
              <div className="text-xs font-bold mb-2">
                Danh sách Tài khoản đọc được ({accountPreview.length} dòng •{' '}
                <span className="text-emerald-400">{validAccountCount} hợp lệ</span>)
              </div>
              <div className="overflow-x-auto rounded-lg border border-slate-800">
                <table className="w-full text-left text-xs">
                  <thead
                    className={
                      isDark ? 'bg-slate-900 text-slate-300' : 'bg-slate-100 text-slate-700'
                    }
                  >
                    <tr>
                      <th className="p-2.5">Dòng</th>
                      <th className="p-2.5">Họ và tên</th>
                      <th className="p-2.5">Email</th>
                      <th className="p-2.5">Vai trò</th>
                      <th className="p-2.5">Trạng thái</th>
                    </tr>
                  </thead>
                  <tbody className="divide-y divide-slate-800/60">
                    {accountPreview.map((acc, i) => (
                      <tr key={i}>
                        <td className="p-2.5 font-mono text-slate-400">{acc.rowIndex}</td>
                        <td className="p-2.5 font-bold">{acc.name || '--'}</td>
                        <td className="p-2.5 font-mono">{acc.email || '--'}</td>
                        <td className="p-2.5">{acc.role}</td>
                        <td className="p-2.5">
                          <span
                            className={`px-2 py-0.5 rounded text-[10px] font-semibold ${badgeClass(
                              acc.status
                            )}`}
                          >
                            {acc.note}
                          </span>
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            </div>
          )}
        </div>

        <div className="flex justify-end gap-2 pt-3 border-t border-slate-800/60">
          <button
            type="button"
            onClick={handleClose}
            disabled={isImporting}
            className="px-4 py-2 rounded-lg border border-slate-700 text-xs font-semibold disabled:opacity-50"
          >
            Đóng
          </button>
          <button
            type="button"
            disabled={isImporting || totalValidToImport === 0}
            onClick={handleConfirmImport}
            className="px-4 py-2 rounded-lg bg-emerald-600 hover:bg-emerald-700 text-white text-xs font-bold disabled:opacity-50 transition"
          >
            {isImporting
              ? '⏳ Đang nhập vào Database...'
              : `✓ Xác nhận Nhập (${totalValidToImport} mục)`}
          </button>
        </div>
      </div>
    </div>
  );
};