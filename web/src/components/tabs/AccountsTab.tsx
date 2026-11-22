import React, { useRef, useState } from 'react';
import type { ExcelUserPreviewItem, UserProfile } from '../../types/smarthome';
import { API_BASE, getAuthHeaders } from '../../utils/api';
import { getXlsxLib, normalizeExcelKey, readExcelRows } from '../../utils/excelHelpers';

interface AccountsTabProps {
  currentUser: UserProfile;
  usersList: UserProfile[];
  cardBg: string;
  inputBg: string;
  appendLog: (msg: string) => void;
  onRefresh: () => Promise<void>;
}

export function AccountsTab({
  currentUser,
  usersList,
  cardBg,
  inputBg,
  appendLog,
  onRefresh,
}: AccountsTabProps) {
  const [newUserName, setNewUserName] = useState('');
  const [newUserEmail, setNewUserEmail] = useState('');
  const [newUserPassword, setNewUserPassword] = useState('');
  const [newUserRole, setNewUserRole] = useState('Member');
  const [editingUser, setEditingUser] = useState<UserProfile | null>(null);

  const userExcelInputRef = useRef<HTMLInputElement | null>(null);
  const [excelPreviewUsers, setExcelPreviewUsers] = useState<ExcelUserPreviewItem[]>([]);
  const [excelFileName, setExcelFileName] = useState<string>('');
  const [isImportingUsers, setIsImportingUsers] = useState<boolean>(false);

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
      onRefresh();
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
      onRefresh();
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
      onRefresh();
    } else {
      const err = await res.json().catch(() => ({}));
      alert(err.error || 'Không thể xóa tài khoản này');
    }
  };

  const handleExportUsersExcel = () => {
    const xlsxLib = getXlsxLib();
    const sourceList = usersList.length > 0 ? usersList : [currentUser];
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
      [...usersList, currentUser].map((u) => u.email.trim().toLowerCase())
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

      const email = (normalizedRow['email'] || normalizedRow['emaildangnhap'] || '').toLowerCase();
      const rawPassword = normalizedRow['matkhau'] || normalizedRow['password'] || '';
      const rawRole = (normalizedRow['vaitro'] || normalizedRow['role'] || '').toLowerCase();

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

      if (email) seenInFile.add(email);

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
    appendLog(`Đã đọc file "${file.name}": ${validCount}/${previewItems.length} tài khoản hợp lệ.`);

    if (userExcelInputRef.current) userExcelInputRef.current.value = '';
  };

  const handleRemovePreviewUser = (rowNumber: number) => {
    setExcelPreviewUsers((prev) => {
      const next = prev.filter((item) => item.rowNumber !== rowNumber);
      if (next.length === 0) setExcelFileName('');
      return next;
    });
  };

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
      await onRefresh();

      if (failedMap.size === 0) {
        setExcelPreviewUsers([]);
        setExcelFileName('');
      } else {
        setExcelPreviewUsers((prev) =>
          prev
            .filter((item) => !item.isValid || failedMap.has(item.rowNumber))
            .map((item) =>
              failedMap.has(item.rowNumber)
                ? { ...item, isValid: false, errorReason: failedMap.get(item.rowNumber) }
                : item
            )
        );
      }
    } finally {
      setIsImportingUsers(false);
    }
  };

  return (
    <div className="space-y-6">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div>
          <h1 className="text-lg font-bold">Quản lý Tài khoản Thành viên trong Gia đình</h1>
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
            Nhập Excel
          </button>
          <button
            type="button"
            onClick={handleExportUsersExcel}
            className="px-3.5 py-2 rounded-xl bg-cyan-500/15 border border-cyan-500/30 text-cyan-400 hover:bg-cyan-500/25 text-xs font-semibold transition"
          >
            Xuất Excel
          </button>
        </div>
      </div>

      {/* Excel Preview Table */}
      {excelPreviewUsers.length > 0 &&
        (() => {
          const validRows = excelPreviewUsers.filter((u) => u.isValid);
          const invalidRows = excelPreviewUsers.filter((u) => !u.isValid);

          return (
            <div className={`p-5 rounded-2xl border border-cyan-500/40 space-y-4 ${cardBg}`}>
              <div className="flex flex-wrap items-center justify-between gap-3">
                <div>
                  <h2 className="text-sm font-bold text-cyan-400">
                    webDanh sách kiểm tra dữ liệu từ file: {excelFileName}
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
                        className={item.isValid ? 'bg-emerald-500/5' : 'bg-rose-500/5 opacity-80'}
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
                            <span className="text-rose-400 font-medium">✕ {item.errorReason}</span>
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
  );
}