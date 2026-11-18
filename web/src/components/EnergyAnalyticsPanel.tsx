import React, { useState } from 'react';
import type { Room } from '../types/smarthome';

export interface EnergyDailyPoint {
  label: string;
  kwh: number;
}

export interface EnergyDeviceItem {
  id: string;
  name: string;
  room_id?: string | null;
  room_name?: string | null;
  device_type: string;
  is_on: boolean;
}

interface EnergyAnalyticsPanelProps {
  isDark: boolean;
  energyData: {
    total_kwh: number;
    estimated_cost: number;
    daily: EnergyDailyPoint[];
  };
  devices: EnergyDeviceItem[];
  rooms: Room[];
}

const DAY_FULL_NAMES: Record<string, string> = {
  T2: 'Thứ Hai',
  T3: 'Thứ Ba',
  T4: 'Thứ Tư',
  T5: 'Thứ Năm',
  T6: 'Thứ Sáu',
  T7: 'Thứ Bảy',
  CN: 'Chủ Nhật',
};

function getDeviceWatt(deviceType: string): number {
  switch (deviceType) {
    case 'fan':
      return 45;
    case 'light':
      return 15;
    case 'sensor':
      return 2;
    default:
      return 25;
  }
}

export const EnergyAnalyticsPanel: React.FC<EnergyAnalyticsPanelProps> = ({
  isDark,
  energyData,
  devices,
  rooms,
}) => {
  const [chartType, setChartType] = useState<'bar' | 'area'>('bar');
  const [hoveredIdx, setHoveredIdx] = useState<number | null>(null);

  const daily =
    energyData.daily.length > 0
      ? energyData.daily
      : [
          { label: 'T2', kwh: 1.8 },
          { label: 'T3', kwh: 2.1 },
          { label: 'T4', kwh: 1.6 },
          { label: 'T5', kwh: 2.4 },
          { label: 'T6', kwh: 1.9 },
          { label: 'T7', kwh: 2.6 },
          { label: 'CN', kwh: 2.2 },
        ];

  const rawMax = Math.max(...daily.map((d) => d.kwh), 0.5);
  // Làm tròn trần trục Y để lưới chia đẹp (bội số của 0.5)
  const yMax = Math.ceil((rawMax * 1.18) * 2) / 2;
  const yTicks = [0, 0.25, 0.5, 0.75, 1].map((ratio) => Number((yMax * ratio).toFixed(2)));

  const avgDailyKwh =
    daily.length > 0 ? daily.reduce((sum, d) => sum + d.kwh, 0) / daily.length : 0;

  const peakDay = daily.reduce(
    (best, cur) => (cur.kwh > best.kwh ? cur : best),
    daily[0]
  );

  // Đơn giá điện trung bình ước tính (VNĐ / kWh)
  const unitPrice =
    energyData.total_kwh > 0
      ? Math.round(energyData.estimated_cost / energyData.total_kwh)
      : 2500;

  // ==================== TỌA ĐỘ SVG BIỂU ĐỒ CHÍNH ====================
  const svgW = 760;
  const svgH = 265;
  const padLeft = 48;
  const padRight = 24;
  const padTop = 28;
  const padBottom = 38;
  const plotW = svgW - padLeft - padRight;
  const plotH = svgH - padTop - padBottom;

  const points = daily.map((d, i) => {
    const step = plotW / daily.length;
    const x = padLeft + step * i + step / 2;
    const y = padTop + plotH - (d.kwh / yMax) * plotH;
    return { ...d, x, y, index: i };
  });

  const avgY = padTop + plotH - (avgDailyKwh / yMax) * plotH;

  // Tạo đường cong Bezier mượt cho chế độ Area/Line
  const smoothLinePath = points.reduce((acc, pt, idx) => {
    if (idx === 0) return `M ${pt.x},${pt.y}`;
    const prev = points[idx - 1];
    const cx1 = prev.x + (pt.x - prev.x) * 0.42;
    const cx2 = prev.x + (pt.x - prev.x) * 0.58;
    return `${acc} C ${cx1},${prev.y} ${cx2},${pt.y} ${pt.x},${pt.y}`;
  }, '');

  const smoothAreaPath =
    points.length > 0
      ? `${smoothLinePath} L ${points[points.length - 1].x},${padTop + plotH} L ${
          points[0].x
        },${padTop + plotH} Z`
      : '';

  // ==================== TÍNH PHÂN BỔ CÔNG SUẤT DONUT CHART ====================
  const categoryTotals = [
    {
      key: 'fan',
      label: 'Quạt & Điều hòa',
      color: '#06b6d4',
      watt: devices
        .filter((d) => d.device_type === 'fan' && d.is_on)
        .reduce((s, d) => s + getDeviceWatt(d.device_type), 0),
    },
    {
      key: 'light',
      label: 'Đèn chiếu sáng',
      color: '#f59e0b',
      watt: devices
        .filter((d) => d.device_type === 'light' && d.is_on)
        .reduce((s, d) => s + getDeviceWatt(d.device_type), 0),
    },
    {
      key: 'switch',
      label: 'Công tắc & Ổ cắm',
      color: '#10b981',
      watt: devices
        .filter((d) => d.device_type !== 'fan' && d.device_type !== 'light' && d.device_type !== 'sensor' && d.is_on)
        .reduce((s, d) => s + getDeviceWatt(d.device_type), 0),
    },
    {
      key: 'sensor',
      label: 'Cảm biến IoT',
      color: '#8b5cf6',
      watt: devices
        .filter((d) => d.device_type === 'sensor')
        .reduce((s, d) => s + getDeviceWatt(d.device_type), 0),
    },
  ];

  const totalLiveWatt = categoryTotals.reduce((s, c) => s + c.watt, 0);
  const donutRadius = 44;
  const donutCircumference = 2 * Math.PI * donutRadius;

  let cumulativeDash = 0;
  const donutSegments = categoryTotals.map((cat) => {
    const ratio = totalLiveWatt > 0 ? cat.watt / totalLiveWatt : 0;
    const dash = ratio * donutCircumference;
    const offset = -cumulativeDash;
    cumulativeDash += dash;
    return { ...cat, ratio, dash, offset };
  });

  const cardBg = isDark
    ? 'bg-[#0d131f] border-slate-800/90'
    : 'bg-white border-slate-200 shadow-sm';

  const hoveredPoint = hoveredIdx !== null ? points[hoveredIdx] : null;

  return (
    <div className="space-y-6">
      {/* ==================== 1. 4 THẺ KPI NĂNG LƯỢNG ==================== */}
      <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-4">
        <div className={`p-5 rounded-2xl border relative overflow-hidden ${cardBg}`}>
          <div className="flex items-center justify-between text-xs text-slate-400">
            <span>⚡ Tổng điện năng tiêu thụ</span>
            <span className="px-2 py-0.5 rounded bg-cyan-500/15 text-cyan-400 text-[10px] font-semibold">
              7 ngày
            </span>
          </div>
          <div className="text-2xl font-bold text-cyan-400 mt-1.5">
            {energyData.total_kwh.toFixed(2)} kWh
          </div>
          <div className="text-[11px] text-slate-500 mt-1">
            Công suất tức thời: <strong className="text-slate-300">{totalLiveWatt} W</strong>
          </div>
        </div>

        <div className={`p-5 rounded-2xl border ${cardBg}`}>
          <div className="flex items-center justify-between text-xs text-slate-400">
            <span>💰 Chi phí ước tính</span>
            <span className="px-2 py-0.5 rounded bg-emerald-500/15 text-emerald-400 text-[10px] font-semibold">
              ~{unitPrice.toLocaleString('vi-VN')}đ/kWh
            </span>
          </div>
          <div className="text-2xl font-bold text-emerald-400 mt-1.5">
            {energyData.estimated_cost.toLocaleString('vi-VN')} đ
          </div>
          <div className="text-[11px] text-slate-500 mt-1">
            Trung bình ~{Math.round(avgDailyKwh * unitPrice).toLocaleString('vi-VN')} đ/ngày
          </div>
        </div>

        <div className={`p-5 rounded-2xl border ${cardBg}`}>
          <div className="flex items-center justify-between text-xs text-slate-400">
            <span>📊 Trung bình mỗi ngày</span>
            <span className="px-2 py-0.5 rounded bg-sky-500/15 text-sky-400 text-[10px] font-semibold">
              Định mức
            </span>
          </div>
          <div className="text-2xl font-bold text-sky-400 mt-1.5">
            {avgDailyKwh.toFixed(2)} kWh
          </div>
          <div className="text-[11px] text-slate-500 mt-1">
            Đường tham chiếu màu xanh trên biểu đồ
          </div>
        </div>

        <div className={`p-5 rounded-2xl border ${cardBg}`}>
          <div className="flex items-center justify-between text-xs text-slate-400">
            <span>🔥 Ngày tiêu thụ cao nhất</span>
            <span className="px-2 py-0.5 rounded bg-amber-500/15 text-amber-400 text-[10px] font-bold">
              PEAK
            </span>
          </div>
          <div className="text-2xl font-bold text-amber-400 mt-1.5">
            {peakDay.label} ({peakDay.kwh.toFixed(1)} kWh)
          </div>
          <div className="text-[11px] text-slate-500 mt-1">
            Cao hơn TB{' '}
            <strong className="text-amber-400">
              {avgDailyKwh > 0
                ? `+${Math.round(((peakDay.kwh - avgDailyKwh) / avgDailyKwh) * 100)}%`
                : '0%'}
            </strong>
          </div>
        </div>
      </div>

      {/* ==================== 2. KHỐI BIỂU ĐỒ CHÍNH & DONUT ==================== */}
      <div className="grid grid-cols-1 xl:grid-cols-3 gap-6">
        {/* BIỂU ĐỒ TIÊU THỤ THEO NGÀY (CHIẾM 2/3 CHIỀU RỘNG) */}
        <div className={`xl:col-span-2 p-6 rounded-2xl border flex flex-col justify-between ${cardBg}`}>
          <div className="flex flex-wrap items-center justify-between gap-3 mb-4">
            <div>
              <h3 className="text-sm font-bold flex items-center gap-2">
                <span>📈</span>
                <span>Biểu đồ tiêu thụ điện năng theo ngày (kWh)</span>
              </h3>
              <p className="text-xs text-slate-400 mt-0.5">
                Rê chuột vào từng ngày để xem chi tiết sản lượng và chi phí tiền điện
              </p>
            </div>

            <div className="flex items-center gap-2">
              {/* Chú thích nhỏ */}
              <div className="hidden sm:flex items-center gap-3 mr-2 text-[11px] text-slate-400">
                <span className="flex items-center gap-1.5">
                  <span className="w-2.5 h-2.5 rounded-sm bg-cyan-400 inline-block" />
                  Bình thường
                </span>
                <span className="flex items-center gap-1.5">
                  <span className="w-2.5 h-2.5 rounded-sm bg-amber-400 inline-block" />
                  Đỉnh ({peakDay.kwh.toFixed(1)} kWh)
                </span>
              </div>

              {/* Nút chuyển đổi Bar / Area */}
              <div
                className={`p-1 rounded-xl border flex items-center gap-1 ${
                  isDark ? 'bg-slate-950/80 border-slate-800' : 'bg-slate-100 border-slate-200'
                }`}
              >
                <button
                  type="button"
                  onClick={() => setChartType('bar')}
                  className={`px-2.5 py-1 rounded-lg text-xs font-semibold transition ${
                    chartType === 'bar'
                      ? 'bg-cyan-500 text-slate-950 shadow'
                      : 'text-slate-400 hover:text-slate-200'
                  }`}
                >
                  Cột
                </button>
                <button
                  type="button"
                  onClick={() => setChartType('area')}
                  className={`px-2.5 py-1 rounded-lg text-xs font-semibold transition ${
                    chartType === 'area'
                      ? 'bg-cyan-500 text-slate-950 shadow'
                      : 'text-slate-400 hover:text-slate-200'
                  }`}
                >
                  Đường mượt
                </button>
              </div>
            </div>
          </div>

          {/* Vùng vẽ SVG tương tác */}
          <div
            className={`relative rounded-xl border p-3 ${
              isDark
                ? 'bg-gradient-to-b from-[#080d17] to-[#0b1220] border-slate-800/80'
                : 'bg-slate-50 border-slate-200'
            }`}
          >
            {/* Floating Tooltip khi hover */}
            {hoveredPoint && (
              <div
                style={{
                  left: `${Math.min(78, Math.max(12, (hoveredPoint.x / svgW) * 100))}%`,
                }}
                className={`absolute top-3 -translate-x-1/2 z-20 pointer-events-none px-3.5 py-2.5 rounded-xl border shadow-xl text-xs min-w-[165px] backdrop-blur-md ${
                  isDark
                    ? 'bg-slate-900/95 border-cyan-500/40 text-slate-100'
                    : 'bg-white/95 border-slate-300 text-slate-800'
                }`}
              >
                <div className="font-bold text-cyan-400 flex items-center justify-between gap-2">
                  <span>{DAY_FULL_NAMES[hoveredPoint.label] || hoveredPoint.label}</span>
                  {hoveredPoint.kwh === peakDay.kwh && (
                    <span className="px-1.5 py-0.2 rounded bg-amber-500/20 text-amber-400 text-[9px]">
                      CAO NHẤT
                    </span>
                  )}
                </div>
                <div className="mt-1 flex items-center justify-between">
                  <span className="text-slate-400">Sản lượng:</span>
                  <span className="font-mono font-bold">{hoveredPoint.kwh.toFixed(2)} kWh</span>
                </div>
                <div className="flex items-center justify-between">
                  <span className="text-slate-400">Ước tính:</span>
                  <span className="font-mono text-emerald-400 font-semibold">
                    {Math.round(hoveredPoint.kwh * unitPrice).toLocaleString('vi-VN')} đ
                  </span>
                </div>
                <div className="mt-1 pt-1 border-t border-slate-800/80 text-[10px] text-slate-400 flex justify-between">
                  <span>So với TB:</span>
                  <span
                    className={
                      hoveredPoint.kwh >= avgDailyKwh ? 'text-amber-400' : 'text-emerald-400'
                    }
                  >
                    {avgDailyKwh > 0
                      ? `${hoveredPoint.kwh >= avgDailyKwh ? '+' : ''}${(
                          ((hoveredPoint.kwh - avgDailyKwh) / avgDailyKwh) *
                          100
                        ).toFixed(1)}%`
                      : '0%'}
                  </span>
                </div>
              </div>
            )}

            <svg
              viewBox={`0 0 ${svgW} ${svgH}`}
              className="w-full h-64 overflow-visible select-none"
              onMouseLeave={() => setHoveredIdx(null)}
            >
              <defs>
                {/* Gradient cột bình thường */}
                <linearGradient id="barCyanGrad" x1="0" y1="0" x2="0" y2="1">
                  <stop offset="0%" stopColor="#22d3ee" stopOpacity="1" />
                  <stop offset="100%" stopColor="#0284c7" stopOpacity="0.65" />
                </linearGradient>

                {/* Gradient cột đỉnh */}
                <linearGradient id="barPeakGrad" x1="0" y1="0" x2="0" y2="1">
                  <stop offset="0%" stopColor="#fde047" stopOpacity="1" />
                  <stop offset="50%" stopColor="#f59e0b" stopOpacity="0.95" />
                  <stop offset="100%" stopColor="#d97706" stopOpacity="0.7" />
                </linearGradient>

                {/* Gradient vùng biểu đồ đường mượt */}
                <linearGradient id="areaFillGrad" x1="0" y1="0" x2="0" y2="1">
                  <stop offset="0%" stopColor="#06b6d4" stopOpacity="0.38" />
                  <stop offset="100%" stopColor="#06b6d4" stopOpacity="0.01" />
                </linearGradient>

                {/* Glow filter */}
                <filter id="softGlow" x="-20%" y="-20%" width="140%" height="140%">
                  <feGaussianBlur stdDeviation="3" result="blur" />
                  <feComposite in="SourceGraphic" in2="blur" operator="over" />
                </filter>
              </defs>

              {/* 1. Lưới ngang trục Y & Nhãn số */}
              {yTicks.map((val, idx) => {
                const y = padTop + plotH - (val / yMax) * plotH;
                return (
                  <g key={idx}>
                    <line
                      x1={padLeft}
                      y1={y}
                      x2={svgW - padRight}
                      y2={y}
                      stroke={isDark ? '#1e293b' : '#e2e8f0'}
                      strokeDasharray={idx === 0 ? undefined : '4 4'}
                      strokeWidth="1"
                    />
                    <text
                      x={padLeft - 8}
                      y={y + 4}
                      textAnchor="end"
                      fill={isDark ? '#64748b' : '#64748b'}
                      fontSize="11"
                      fontFamily="monospace"
                    >
                      {val.toFixed(1)}
                    </text>
                  </g>
                );
              })}

              {/* 2. Đường trung bình (Average Reference Line) */}
              {avgDailyKwh > 0 && (
                <g>
                  <line
                    x1={padLeft}
                    y1={avgY}
                    x2={svgW - padRight}
                    y2={avgY}
                    stroke="#10b981"
                    strokeWidth="1.5"
                    strokeDasharray="6 4"
                    opacity="0.85"
                  />
                  <rect
                    x={svgW - padRight - 78}
                    y={avgY - 17}
                    width="76"
                    height="15"
                    rx="4"
                    fill="#064e3b"
                    stroke="#10b981"
                    strokeWidth="0.8"
                  />
                  <text
                    x={svgW - padRight - 40}
                    y={avgY - 6}
                    textAnchor="middle"
                    fill="#34d399"
                    fontSize="9.5"
                    fontWeight="bold"
                    fontFamily="monospace"
                  >
                    TB: {avgDailyKwh.toFixed(2)}
                  </text>
                </g>
              )}

              {/* 3. Chế độ BIỂU ĐỒ ĐƯỜNG MƯỢT (AREA/SPLINE) */}
              {chartType === 'area' && points.length > 0 && (
                <g>
                  <path d={smoothAreaPath} fill="url(#areaFillGrad)" />
                  <path
                    d={smoothLinePath}
                    fill="none"
                    stroke="#22d3ee"
                    strokeWidth="3"
                    strokeLinecap="round"
                    filter="url(#softGlow)"
                  />
                </g>
              )}

              {/* 4. Các cột dữ liệu hoặc điểm nút + vùng bắt hover */}
              {points.map((pt) => {
                const isPeak = pt.kwh === peakDay.kwh;
                const isHovered = hoveredIdx === pt.index;
                const barWidth = 38;
                const barHeight = Math.max(6, padTop + plotH - pt.y);
                const slotWidth = plotW / points.length;

                return (
                  <g
                    key={pt.index}
                    className="cursor-pointer"
                    onMouseEnter={() => setHoveredIdx(pt.index)}
                  >
                    {/* Cột nền highlight khi rê chuột */}
                    {isHovered && (
                      <rect
                        x={pt.x - slotWidth / 2 + 4}
                        y={padTop}
                        width={slotWidth - 8}
                        height={plotH}
                        rx="10"
                        fill={isDark ? 'rgba(34, 211, 238, 0.06)' : 'rgba(14, 165, 233, 0.08)'}
                      />
                    )}

                    {chartType === 'bar' ? (
                      <>
                        {/* Cột chính */}
                        <rect
                          x={pt.x - barWidth / 2}
                          y={pt.y}
                          width={barWidth}
                          height={barHeight}
                          rx="8"
                          fill={isPeak ? 'url(#barPeakGrad)' : 'url(#barCyanGrad)'}
                          opacity={hoveredIdx !== null && !isHovered ? 0.55 : 1}
                          filter={isHovered || isPeak ? 'url(#softGlow)' : undefined}
                          className="transition-all duration-200"
                        />
                        {/* Thanh sáng đỉnh cột */}
                        <rect
                          x={pt.x - barWidth / 2 + 6}
                          y={pt.y + 3}
                          width={barWidth - 12}
                          height="3"
                          rx="1.5"
                          fill="#ffffff"
                          opacity="0.45"
                        />
                      </>
                    ) : (
                      <>
                        {/* Đường gióng dọc khi hover ở chế độ Area */}
                        {isHovered && (
                          <line
                            x1={pt.x}
                            y1={padTop}
                            x2={pt.x}
                            y2={padTop + plotH}
                            stroke="#22d3ee"
                            strokeDasharray="3 3"
                            strokeWidth="1.2"
                          />
                        )}
                        {/* Điểm tròn trên đường */}
                        <circle
                          cx={pt.x}
                          cy={pt.y}
                          r={isHovered ? 7 : isPeak ? 6 : 4.5}
                          fill={isPeak ? '#f59e0b' : '#06b6d4'}
                          stroke={isDark ? '#080d17' : '#ffffff'}
                          strokeWidth="2.5"
                        />
                      </>
                    )}

                    {/* Giá trị kWh trên đầu cột/điểm */}
                    <text
                      x={pt.x}
                      y={pt.y - 9}
                      textAnchor="middle"
                      fill={isPeak ? '#fbbf24' : isHovered ? '#67e8f9' : '#22d3ee'}
                      fontSize="11.5"
                      fontWeight="bold"
                      fontFamily="monospace"
                    >
                      {pt.kwh.toFixed(1)}
                    </text>

                    {/* Nhãn ngày trục X */}
                    <text
                      x={pt.x}
                      y={padTop + plotH + 22}
                      textAnchor="middle"
                      fill={
                        isHovered
                          ? '#22d3ee'
                          : isPeak
                          ? '#fbbf24'
                          : isDark
                          ? '#94a3b8'
                          : '#475569'
                      }
                      fontSize="12"
                      fontWeight={isHovered || isPeak ? 'bold' : 'normal'}
                    >
                      {pt.label}
                    </text>

                    {/* Vùng tàng hình rộng để rê chuột nhạy */}
                    <rect
                      x={pt.x - slotWidth / 2}
                      y={padTop}
                      width={slotWidth}
                      height={plotH + padBottom}
                      fill="transparent"
                    />
                  </g>
                );
              })}
            </svg>
          </div>
        </div>

        {/* BIỂU ĐỒ TRÒN DONUT PHÂN BỔ CÔNG SUẤT (CHIẾM 1/3 CHIỀU RỘNG) */}
        <div className={`p-6 rounded-2xl border flex flex-col justify-between ${cardBg}`}>
          <div>
            <h3 className="text-sm font-bold flex items-center gap-2">
              <span>🍩</span>
              <span>Tỷ trọng Công suất Tức thời</span>
            </h3>
            <p className="text-xs text-slate-400 mt-0.5">
              Phân bổ phụ tải theo nhóm thiết bị đang bật
            </p>
          </div>

          <div className="my-4 flex items-center justify-center relative">
            <svg viewBox="0 0 120 120" className="w-44 h-44 -rotate-90">
              <circle
                cx="60"
                cy="60"
                r={donutRadius}
                fill="transparent"
                stroke={isDark ? '#1e293b' : '#e2e8f0'}
                strokeWidth="14"
              />
              {totalLiveWatt > 0 &&
                donutSegments.map(
                  (seg) =>
                    seg.dash > 0 && (
                      <circle
                        key={seg.key}
                        cx="60"
                        cy="60"
                        r={donutRadius}
                        fill="transparent"
                        stroke={seg.color}
                        strokeWidth="14"
                        strokeDasharray={`${seg.dash} ${donutCircumference - seg.dash}`}
                        strokeDashoffset={seg.offset}
                        strokeLinecap="butt"
                      />
                    )
                )}
            </svg>

            <div className="absolute inset-0 flex flex-col items-center justify-center text-center pointer-events-none">
              <span className="text-[10px] uppercase tracking-wider text-slate-400">
                Tổng tải
              </span>
              <span className="text-xl font-bold text-cyan-400 font-mono">
                {totalLiveWatt}W
              </span>
              <span className="text-[10px] text-slate-500">
                {devices.filter((d) => d.is_on).length} thiết bị bật
              </span>
            </div>
          </div>

          <div className="space-y-2.5">
            {donutSegments.map((seg) => (
              <div
                key={seg.key}
                className="flex items-center justify-between text-xs py-1 border-b border-slate-800/50 last:border-none"
              >
                <div className="flex items-center gap-2">
                  <span
                    style={{ backgroundColor: seg.color }}
                    className="w-2.5 h-2.5 rounded-full shrink-0"
                  />
                  <span className="text-slate-300">{seg.label}</span>
                </div>
                <div className="font-mono text-right">
                  <span className="font-bold text-slate-200">{seg.watt}W</span>{' '}
                  <span className="text-slate-500 text-[11px]">
                    ({totalLiveWatt > 0 ? Math.round(seg.ratio * 100) : 0}%)
                  </span>
                </div>
              </div>
            ))}
          </div>
        </div>
      </div>

      {/* ==================== 3. BẢNG CHI TIẾT THIẾT BỊ TIÊU THỤ ==================== */}
      <div className={`p-5 rounded-2xl border space-y-3 ${cardBg}`}>
        <div className="flex items-center justify-between">
          <h3 className="text-sm font-bold">🔌 Chi tiết công suất từng thiết bị IoT</h3>
          <span className="text-xs text-slate-400 font-mono">
            Tổng: {devices.length} thiết bị
          </span>
        </div>

        <div className="overflow-x-auto rounded-xl border border-slate-800">
          <table className="w-full text-left text-xs">
            <thead className="bg-slate-900/90 text-slate-300">
              <tr>
                <th className="p-3">Thiết bị</th>
                <th className="p-3">Phòng</th>
                <th className="p-3">Trạng thái</th>
                <th className="p-3">Mức tải</th>
                <th className="p-3 text-right">Công suất</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-slate-800/70">
              {devices.map((dev) => {
                const isActive = dev.is_on || dev.device_type === 'sensor';
                const watt = isActive ? getDeviceWatt(dev.device_type) : 0;
                const sharePct =
                  totalLiveWatt > 0 ? Math.round((watt / totalLiveWatt) * 100) : 0;
                const roomName =
                  dev.room_name ||
                  rooms.find((r) => r.id === dev.room_id)?.name ||
                  'Chưa phân phòng';

                return (
                  <tr key={dev.id}>
                    <td className="p-3 font-bold">{dev.name}</td>
                    <td className="p-3 text-slate-400">{roomName}</td>
                    <td className="p-3">
                      <span
                        className={`px-2 py-0.5 rounded text-[10px] font-bold ${
                          isActive
                            ? 'bg-emerald-500/15 text-emerald-400'
                            : 'bg-slate-800 text-slate-400'
                        }`}
                      >
                        {dev.device_type === 'sensor'
                          ? 'ONLINE'
                          : dev.is_on
                          ? 'ĐANG BẬT'
                          : 'TẮT'}
                      </span>
                    </td>
                    <td className="p-3 w-40">
                      <div className="w-full h-1.5 rounded-full bg-slate-800 overflow-hidden">
                        <div
                          style={{ width: `${sharePct}%` }}
                          className="h-full rounded-full bg-cyan-400 transition-all duration-300"
                        />
                      </div>
                    </td>
                    <td className="p-3 text-right font-mono text-cyan-400 font-bold">
                      {watt} W
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      </div>
    </div>
  );
};