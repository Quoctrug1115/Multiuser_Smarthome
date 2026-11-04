import React from 'react';
import { Device, UserRole } from '../types/smarthome';

interface DeviceCardProps {
  device: Device;
  userRole: UserRole;
  onToggle: (id: string, currentStatus: boolean) => void;
}

export const DeviceCard: React.FC<DeviceCardProps> = ({ device, userRole, onToggle }) => {
  const isGuest = userRole === 'Guest';

  return (
    <div className="bg-zinc-900 dark:bg-zinc-900/90 light:bg-white border border-zinc-800 dark:border-zinc-800 light:border-zinc-200 rounded-xl p-5 transition-all hover:border-cyan-500/50 shadow-lg">
      <div className="flex justify-between items-start mb-4">
        <div>
          <h3 className="font-semibold text-zinc-100 dark:text-zinc-100 light:text-zinc-800">{device.name}</h3>
          <p className="text-xs text-zinc-400 mt-0.5">{device.room_name}</p>
        </div>
        <span className={`h-2.5 w-2.5 rounded-full ${device.status ? 'bg-emerald-400 shadow-[0_0_8px_#34d399]' : 'bg-zinc-600'}`} />
      </div>

      <div className="flex justify-between items-center mt-6">
        <span className="text-xs text-zinc-500 font-mono">
          {device.power_watt > 0 ? `${device.power_watt} W` : 'Sensors'}
        </span>

        <button
          disabled={isGuest}
          onClick={() => onToggle(device.id, device.status)}
          className={`px-4 py-1.5 rounded-lg text-xs font-medium transition-all ${
            isGuest
              ? 'bg-zinc-800 text-zinc-500 cursor-not-allowed'
              : device.status
              ? 'bg-cyan-500/20 text-cyan-400 border border-cyan-500/30 hover:bg-cyan-500/30'
              : 'bg-zinc-800 text-zinc-400 hover:bg-zinc-700'
          }`}
        >
          {device.status ? 'ĐANG BẬT' : 'ĐANG TẮT'}
        </button>
      </div>
    </div>
  );
};