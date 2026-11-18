import React from 'react';
import type { Device, UserRole } from '../types/smarthome';

interface DeviceCardProps {
  device: Device;
  isDark: boolean;
  userRole: UserRole;
  isAdmin: boolean;
  showActions?: boolean;
  onToggle: (id: string, currentStatus: boolean) => void;
  onEdit?: (device: Device) => void;
  onDelete?: (device: Device) => void;
}

export const DeviceCard: React.FC<DeviceCardProps> = ({
  device,
  isDark,
  userRole,
  isAdmin,
  showActions = false,
  onToggle,
  onEdit,
  onDelete,
}) => {
  const isSensor = device.device_type === 'sensor';
  const cardBgClass = isDark
    ? 'bg-[#0d131f] border-slate-800/80 text-slate-100'
    : 'bg-white border-slate-200 text-slate-800 shadow-sm';
  const subTextClass = isDark ? 'text-slate-400' : 'text-slate-500';

  const getIcon = () => {
    if (isSensor) return '📡';
    if (device.device_type === 'fan' || device.name.toLowerCase().includes('quạt')) return '🌪️';
    if (device.device_type === 'ac' || device.name.toLowerCase().includes('điều hòa')) return '❄️';
    if (device.device_type === 'light' || device.name.toLowerCase().includes('đèn')) return '💡';
    return '🔌';
  };

  return (
    <div
      className={`${
        showActions ? 'p-5 space-y-4' : 'p-4'
      } rounded-xl border flex flex-col justify-between ${cardBgClass}`}
    >
      <div className="flex justify-between items-start">
        <div className="flex items-center gap-3">
          <div
            className={`${showActions ? 'p-3 rounded-xl text-xl' : 'p-2.5 rounded-lg text-lg'} ${
              isSensor
                ? 'bg-amber-500/20 text-amber-400'
                : device.status
                ? isDark
                  ? 'bg-cyan-500/20 text-cyan-400'
                  : 'bg-sky-500/20 text-sky-600'
                : isDark
                ? 'bg-slate-800 text-slate-400'
                : 'bg-slate-200 text-slate-500'
            }`}
          >
            {getIcon()}
          </div>
          <div>
            <div className={showActions ? 'text-sm font-bold' : 'text-xs font-bold'}>
              {device.name}
            </div>
            <div className={`${showActions ? 'text-xs' : 'text-[10px]'} ${subTextClass}`}>
              {device.room_name} •{' '}
              {isSensor ? (
                <span className="text-amber-400 font-bold">ONLINE</span>
              ) : (
                <span
                  className={
                    device.status
                      ? isDark
                        ? 'text-cyan-400 font-bold'
                        : 'text-sky-600 font-bold'
                      : 'text-slate-400'
                  }
                >
                  {device.status
                    ? device.power_watt > 0
                      ? `ON (${device.power_watt}W)`
                      : 'ON'
                    : 'OFF'}
                </span>
              )}
            </div>
          </div>
        </div>

        {isSensor ? (
          <span className="px-2 py-0.5 rounded text-[10px] font-mono bg-amber-500/15 text-amber-400 border border-amber-500/30">
            SENSOR
          </span>
        ) : (
          <button
            disabled={userRole === 'Guest'}
            onClick={() => onToggle(device.id, device.status)}
            className={`w-12 h-6 rounded-full p-0.5 transition-colors duration-200 ease-in-out ${
              device.status
                ? isDark
                  ? 'bg-cyan-400'
                  : 'bg-sky-500'
                : isDark
                ? 'bg-slate-800'
                : 'bg-slate-300'
            }`}
          >
            <div
              className={`w-5 h-5 rounded-full shadow transition-transform duration-200 ${
                isDark ? 'bg-slate-950' : 'bg-white'
              } ${device.status ? 'translate-x-6' : 'translate-x-0'}`}
            />
          </button>
        )}
      </div>

      <div
        className={`${
          showActions ? 'pt-3 text-xs' : 'mt-3 pt-2 text-[10px]'
        } border-t ${
          isDark ? 'border-slate-800/80' : 'border-slate-200'
        } flex justify-between items-center gap-2 ${subTextClass}`}
      >
        <span className="font-mono truncate">Topic: {device.topic}</span>
        {showActions && (
          <div className="flex items-center gap-2 shrink-0">
            {device.power_watt > 0 && <span className="font-bold">{device.power_watt}W</span>}
            {isAdmin && (
              <>
                {onEdit && (
                  <button
                    onClick={() => onEdit(device)}
                    title="Chỉnh sửa thiết bị"
                    className="px-1.5 py-0.5 rounded bg-slate-500/15 hover:bg-slate-500/25 text-xs"
                  >
                    ✏️
                  </button>
                )}
                {onDelete && (
                  <button
                    onClick={() => onDelete(device)}
                    title="Xóa thiết bị"
                    className="px-1.5 py-0.5 rounded bg-red-500/15 hover:bg-red-500/25 text-red-400 text-xs"
                  >
                    🗑️
                  </button>
                )}
              </>
            )}
          </div>
        )}
      </div>
    </div>
  );
};