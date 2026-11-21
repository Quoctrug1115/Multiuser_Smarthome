import type { ActiveTab, UserProfile } from '../../types/smarthome';
import { HubLogoIcon } from '../HubLogoIcon';
interface SidebarProps {
  currentUser: UserProfile;
  isOwnerOrAdmin: boolean;
  activeTab: ActiveTab;
  onSelectTab: (tab: ActiveTab) => void;
  onLogout: () => void;
  roomsCount: number;
  devicesCount: number;
  automationsCount: number;
  aiAlertsCount: number;
  usersCount: number;
  sidebarBg: string;
}

export function Sidebar({
  currentUser,
  isOwnerOrAdmin,
  activeTab,
  onSelectTab,
  onLogout,
  roomsCount,
  devicesCount,
  automationsCount,
  aiAlertsCount,
  usersCount,
  sidebarBg,
}: SidebarProps) {
  const navBtnClass = (tab: ActiveTab) =>
    `w-full flex items-center justify-between px-3 py-2.5 rounded-xl transition ${
      activeTab === tab
        ? 'bg-cyan-500/15 text-cyan-400 border border-cyan-500/30 font-semibold'
        : 'text-slate-400 hover:bg-slate-800/50 hover:text-slate-200'
    }`;

  return (
    <aside className={`w-64 shrink-0 border-r flex flex-col justify-between p-4 ${sidebarBg}`}>
      <div>
        <div className="flex items-center gap-3 px-2 py-2 mb-6">
         <HubLogoIcon size={38} />
          <div className="min-w-0">
            <div className="font-bold text-sm text-cyan-400 truncate">SmartHome IoT</div>
            <div className="text-xs text-slate-400 truncate">{currentUser.name}</div>
          </div>
        </div>

        <div className="text-[10px] font-bold uppercase tracking-wider text-slate-500 px-3 mb-2">
          ĐIỀU KHIỂN NHÀ THÔNG MINH
        </div>

        <nav className="space-y-1 text-xs font-medium">
          <button onClick={() => onSelectTab('overview')} className={navBtnClass('overview')}>
            <span>📊 Tổng quan</span>
          </button>

          <button onClick={() => onSelectTab('devices')} className={navBtnClass('devices')}>
            <span>📱 Phòng & Thiết bị</span>
            <span className="px-1.5 py-0.5 rounded bg-cyan-500/20 text-cyan-300 text-[10px] font-mono">
              {roomsCount}P • {devicesCount}
            </span>
          </button>

          <button onClick={() => onSelectTab('automations')} className={navBtnClass('automations')}>
            <span>⚡ Tự động hóa (IF-THEN)</span>
            <span className="px-1.5 py-0.5 rounded bg-amber-500/20 text-amber-300 text-[10px] font-mono">
              {automationsCount}
            </span>
          </button>

          <button onClick={() => onSelectTab('energy')} className={navBtnClass('energy')}>
            <span>📈 Thống kê Năng lượng</span>
          </button>

          <button onClick={() => onSelectTab('ai')} className={navBtnClass('ai')}>
            <span>🤖 Trí tuệ Nhân tạo (AI)</span>
            <span className="px-1.5 py-0.5 rounded bg-rose-500/20 text-rose-300 text-[10px] font-mono">
              {aiAlertsCount}
            </span>
          </button>

          {isOwnerOrAdmin && (
            <button onClick={() => onSelectTab('accounts')} className={navBtnClass('accounts')}>
              <span>👥 Quản lý Tài khoản</span>
              <span className="px-1.5 py-0.5 rounded bg-emerald-500/20 text-emerald-300 text-[10px] font-mono">
                {usersCount}
              </span>
            </button>
          )}
        </nav>
      </div>

      {/* User Footer */}
      <div className="p-3 rounded-xl bg-slate-900/70 border border-slate-800 flex items-center justify-between gap-2">
        <div className="min-w-0">
          <div className="text-xs font-semibold text-slate-200 truncate">{currentUser.email}</div>
          <div className="text-[11px] text-emerald-400 truncate">
            {currentUser.name} ({currentUser.role})
          </div>
        </div>
        <button
          onClick={onLogout}
          title="Đăng xuất"
          className="p-2 rounded-lg bg-red-500/15 text-red-400 hover:bg-red-500/25 text-xs shrink-0"
        >
          🚪
        </button>
      </div>
    </aside>
  );
}