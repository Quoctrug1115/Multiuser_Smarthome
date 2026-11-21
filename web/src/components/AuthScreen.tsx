import React, { useState } from 'react';
import { useAuth } from '../context/AuthContext';
import { HubLogoIcon } from './HubLogoIcon';
interface AuthScreenProps {
  onSuccessLog: (msg: string) => void;
}

export function AuthScreen({ onSuccessLog }: AuthScreenProps) {
  const { login, register } = useAuth();
  const [authMode, setAuthMode] = useState<'login' | 'register'>('login');
  const [authName, setAuthName] = useState('');
  const [authEmail, setAuthEmail] = useState('');
  const [authPassword, setAuthPassword] = useState('');
  const [authError, setAuthError] = useState('');
  const [authLoading, setAuthLoading] = useState(false);

  const handleAuthSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    setAuthError('');
    setAuthLoading(true);

    try {
      const user =
        authMode === 'login'
          ? await login(authEmail, authPassword)
          : await register(authName, authEmail, authPassword);

      setAuthName('');
      setAuthEmail('');
      setAuthPassword('');
      onSuccessLog(`Đăng nhập thành công với vai trò ${user.role}.`);
    } catch (err) {
      setAuthError((err as Error)?.message || 'Không thể kết nối tới máy chủ Backend.');
    } finally {
      setAuthLoading(false);
    }
  };

  return (
    <div className="min-h-screen bg-[#080d1a] text-slate-100 flex items-center justify-center p-4">
      <div className="w-full max-w-md rounded-2xl bg-[#0e1629] border border-slate-800 p-7 shadow-2xl">
        <div className="flex items-center gap-3 mb-6">
          <HubLogoIcon size={46} />
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
              <strong className="text-cyan-400">Chủ nhà (Owner)</strong> với không gian quản lý nhà,
              phòng, thiết bị và thành viên độc lập.
            </p>
          )}
        </form>
      </div>
    </div>
  );
}