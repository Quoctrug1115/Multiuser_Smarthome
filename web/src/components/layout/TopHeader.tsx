import { useEffect, useState } from 'react';

interface TopHeaderProps {
  housesCount: number;
  roomsCount: number;
  devicesCount: number;
  wsConnected: boolean;
  userRole: string;
  isDark: boolean;
  onToggleTheme: () => void;
  sidebarBg: string;
}

export function TopHeader({
  housesCount,
  roomsCount,
  devicesCount,
  wsConnected,
  userRole,
  isDark,
  onToggleTheme,
  sidebarBg,
}: TopHeaderProps) {
  const [clockText, setClockText] = useState('');

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

  return (
    <header
      className={`px-6 py-3 border-b flex flex-wrap items-center justify-between gap-3 ${sidebarBg}`}
    >
      <div className="px-3 py-1.5 rounded-xl bg-slate-900/70 border border-slate-800 text-xs text-slate-300">
        🗄️ : <strong className="text-white">{housesCount}</strong> nhà •{' '}
        <strong className="text-white">{roomsCount}</strong> phòng •{' '}
        <strong className="text-white">{devicesCount}</strong> thiết bị
      </div>

      <div className="flex flex-wrap items-center gap-2 text-xs">
        {/* <span
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
        </span> */}

        <span className="px-3 py-1 rounded-full bg-amber-500/10 border border-amber-500/30 text-slate-300">
          Vai trò: <strong className="text-amber-400">{userRole}</strong>
        </span>

        <button
          onClick={onToggleTheme}
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
  );
}