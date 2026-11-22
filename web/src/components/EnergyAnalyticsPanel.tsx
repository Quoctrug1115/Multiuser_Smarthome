import React, { useState, useMemo } from 'react';

export type EnergyPeriod = 'day' | 'week' | 'month';

export interface EnergyPoint {
  label: string;
  kwh: number;
  power_watt?: number;
}

export interface EnergyState {
  total_kwh: number;
  estimated_cost: number;
  peak_watt?: number;
  daily: EnergyPoint[];
}

interface DeviceItem {
  id: string;
  name: string;
  device_type: string;
  mqtt_topic: string;
  room_id?: string | null;
  room_name?: string | null;
  is_on: boolean;
  rated_power_watt?: number | string | null;
  power_watt?: number | string | null;
  wattage?: number | string | null;
  watt?: number | string | null;
}

interface RoomItem {
  id: string;
  name: string;
}

interface EnergyAnalyticsPanelProps {
  energyData: EnergyState;
  devices: DeviceItem[];
  rooms: RoomItem[];
  isDark: boolean;
  period: EnergyPeriod;
  onPeriodChange: (period: EnergyPeriod) => void;
}

const UNIT_PRICE_VND = 2500;

function getDeviceWatt(dev: DeviceItem): number {
  // 1. Ưu tiên lấy công suất định mức thật từ Database
  const rawDbWatt =
    dev.rated_power_watt ?? dev.power_watt ?? dev.wattage ?? dev.watt;
  const parsedDbWatt = Number(rawDbWatt);
  if (!Number.isNaN(parsedDbWatt) && parsedDbWatt > 0) {
    return parsedDbWatt;
  }

  // 2. Dự phòng khi thiết bị trong DB chưa cấu hình công suất (0 hoặc NULL)
  const t = (dev.device_type || '').toLowerCase();
  const n = (dev.name || '').toLowerCase();
  if (
    t.includes('ac') ||
    t.includes('air') ||
    t.includes('heater') ||
    n.includes('điều hòa') ||
    n.includes('máy lạnh')
  ) {
    return 1200;
  }
  if (t.includes('fan') || n.includes('quạt')) return 45;
  if (t.includes('light') || n.includes('đèn')) return 15;
  if (t.includes('sensor') || n.includes('cảm biến') || n.includes('dht')) {
    return 0;
  }
  return 25;
}

function formatKwh(val: number): string {
  if (val > 0 && val < 0.01) return val.toFixed(4);
  if (val > 0 && val < 1) return val.toFixed(3);
  return val.toFixed(2);
}

export const EnergyAnalyticsPanel: React.FC<EnergyAnalyticsPanelProps> = ({
  energyData,
  devices,
  isDark,
  period,
  onPeriodChange,
}) => {
  const [chartType, setChartType] = useState<'bar' | 'line'>('bar');
  const [hoveredIdx, setHoveredIdx] = useState<number | null>(null);

  const cardBg = isDark
    ? 'bg-[#0e1629] border-slate-800/80 text-slate-100'
    : 'bg-white border-slate-200 text-slate-900 shadow-sm';

  // ==================== 1. TÍNH CÔNG SUẤT TỨC THỜI & PHÂN BỔ PHỤ TẢI ====================
  const deviceLoadBreakdown = useMemo(() => {
    const items = devices.map((dev) => {
      const ratedWatt = getDeviceWatt(dev);
      const currentWatt = dev.is_on ? ratedWatt : 0;
      return {
        ...dev,
        ratedWatt,
        currentWatt,
      };
    });

    const totalLiveWatt = items.reduce((sum, d) => sum + d.currentWatt, 0);
    const activeCount = items.filter((d) => d.is_on && d.ratedWatt > 0).length;

    let hvacWatt = 0; // Quạt & Điều hòa
    let lightWatt = 0; // Đèn chiếu sáng
    let switchWatt = 0; // Công tắc & Ổ cắm
    let sensorWatt = 0; // Cảm biến IoT

    items.forEach((d) => {
      if (!d.is_on || d.currentWatt <= 0) return;
      const t = (d.device_type || '').toLowerCase();
      if (t.includes('fan') || t.includes('ac') || t.includes('heater')) {
        hvacWatt += d.currentWatt;
      } else if (t.includes('light')) {
        lightWatt += d.currentWatt;
      } else if (t.includes('sensor')) {
        sensorWatt += d.currentWatt;
      } else {
        switchWatt += d.currentWatt;
      }
    });

    const groups = [
      {
        key: 'hvac',
        label: 'Quạt & Điều hòa',
        watt: hvacWatt,
        color: '#06b6d4',
        dotClass: 'bg-cyan-400',
        pct: totalLiveWatt > 0 ? Math.round((hvacWatt / totalLiveWatt) * 100) : 0,
      },
      {
        key: 'light',
        label: 'Đèn chiếu sáng',
        watt: lightWatt,
        color: '#f59e0b',
        dotClass: 'bg-amber-400',
        pct: totalLiveWatt > 0 ? Math.round((lightWatt / totalLiveWatt) * 100) : 0,
      },
      {
        key: 'switch',
        label: 'Công tắc & Ổ cắm',
        watt: switchWatt,
        color: '#10b981',
        dotClass: 'bg-emerald-400',
        pct: totalLiveWatt > 0 ? Math.round((switchWatt / totalLiveWatt) * 100) : 0,
      },
      {
        key: 'sensor',
        label: 'Cảm biến IoT',
        watt: sensorWatt,
        color: '#8b5cf6',
        dotClass: 'bg-violet-400',
        pct: totalLiveWatt > 0 ? Math.round((sensorWatt / totalLiveWatt) * 100) : 0,
      },
    ];

    return { items, totalLiveWatt, activeCount, groups };
  }, [devices]);

  // ==================== 2. CHUẨN HÓA DỮ LIỆU BIỂU ĐỒ THEO KỲ ====================
  const chartStats = useMemo(() => {
    let points: EnergyPoint[] = energyData.daily || [];

    if (points.length === 0) {
      if (period === 'day') {
        points = Array.from({ length: 24 }, (_, h) => ({
          label: `${String(h).padStart(2, '0')}:00`,
          kwh: 0,
        }));
      } else if (period === 'week') {
        points = ['T2', 'T3', 'T4', 'T5', 'T6', 'T7', 'CN'].map((d) => ({
          label: d,
          kwh: 0,
        }));
      } else {
        points = Array.from({ length: 30 }, (_, i) => ({
          label: `N${i + 1}`,
          kwh: 0,
        }));
      }
    }

    const totalKwh =
      energyData.total_kwh > 0
        ? energyData.total_kwh
        : points.reduce((s, p) => s + Number(p.kwh || 0), 0);

    const estimatedCost =
      energyData.estimated_cost > 0
        ? energyData.estimated_cost
        : Math.round(totalKwh * UNIT_PRICE_VND);

    const avgKwh = points.length > 0 ? totalKwh / points.length : 0;

    let peakPoint = points[0] || { label: '00:00', kwh: 0 };
    points.forEach((p) => {
      if (p.kwh > peakPoint.kwh) peakPoint = p;
    });

    const maxScale = Math.max(peakPoint.kwh * 1.2, 0.01);
    const peakAboveAvgPct =
      avgKwh > 0 ? Math.round(((peakPoint.kwh - avgKwh) / avgKwh) * 100) : 0;

    const avgCostPerUnit =
      points.length > 0 ? Math.round(estimatedCost / points.length) : 0;

    return {
      points,
      totalKwh,
      estimatedCost,
      avgKwh,
      peakPoint,
      maxScale,
      peakAboveAvgPct,
      avgCostPerUnit,
    };
  }, [energyData, period]);

  const periodBadge =
    period === 'day' ? '24 giờ' : period === 'week' ? '7 ngày' : '30 ngày';
  const unitLabel = period === 'day' ? 'giờ' : 'ngày';

  const radius = 42;
  const circumference = 2 * Math.PI * radius;
  let cumulativeOffset = 0;

  return (
    <div className="space-y-6">
      {/* ==================== ROW 1: 4 KPI CARDS ==================== */}
      <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-4">
        <div className={`p-5 rounded-2xl border ${cardBg}`}>
          <div className="flex items-center justify-between text-xs text-slate-400 mb-2">
            <span>Tổng điện năng tiêu thụ</span>
            <span className="px-2 py-0.5 rounded bg-cyan-500/15 text-cyan-400 text-[10px] font-semibold">
              {periodBadge}
            </span>
          </div>
          <div className="text-2xl font-bold text-cyan-400 font-mono">
            {formatKwh(chartStats.totalKwh)} kWh
          </div>
          <div className="text-[11px] text-slate-500 mt-1.5">
            Công suất tức thời:{' '}
            <strong className="text-slate-300">
              {deviceLoadBreakdown.totalLiveWatt} W
            </strong>
          </div>
        </div>

        <div className={`p-5 rounded-2xl border ${cardBg}`}>
          <div className="flex items-center justify-between text-xs text-slate-400 mb-2">
            <span>Chi phí ước tính</span>
            <span className="px-2 py-0.5 rounded bg-emerald-500/15 text-emerald-400 text-[10px] font-semibold">
              ~2.500đ/kWh
            </span>
          </div>
          <div className="text-2xl font-bold text-emerald-400 font-mono">
            {chartStats.estimatedCost.toLocaleString('vi-VN')} đ
          </div>
          <div className="text-[11px] text-slate-500 mt-1.5">
            Trung bình ~{chartStats.avgCostPerUnit.toLocaleString('vi-VN')} đ/
            {unitLabel}
          </div>
        </div>

        <div className={`p-5 rounded-2xl border ${cardBg}`}>
          <div className="flex items-center justify-between text-xs text-slate-400 mb-2">
            <span>Trung bình mỗi {unitLabel}</span>
            <span className="px-2 py-0.5 rounded bg-sky-500/15 text-sky-400 text-[10px] font-semibold">
              Định mức
            </span>
          </div>
          <div className="text-2xl font-bold text-sky-400 font-mono">
            {formatKwh(chartStats.avgKwh)} kWh
          </div>
          <div className="text-[11px] text-slate-500 mt-1.5">
            Đường tham chiếu màu xanh trên biểu đồ
          </div>
        </div>

        <div className={`p-5 rounded-2xl border ${cardBg}`}>
          <div className="flex items-center justify-between text-xs text-slate-400 mb-2">
            <span>{period === 'day' ? 'Giờ' : 'Ngày'} tiêu thụ cao nhất</span>
            <span className="px-2 py-0.5 rounded bg-amber-500/15 text-amber-400 text-[10px] font-bold">
              PEAK
            </span>
          </div>
          <div className="text-2xl font-bold text-amber-400 font-mono">
            {chartStats.peakPoint.label} ({formatKwh(chartStats.peakPoint.kwh)}{' '}
            kWh)
          </div>
          <div className="text-[11px] text-slate-500 mt-1.5">
            Cao hơn TB{' '}
            <strong className="text-amber-400">
              {Math.max(0, chartStats.peakAboveAvgPct)}%
            </strong>
          </div>
        </div>
      </div>

      {/* ==================== ROW 2: BIỂU ĐỒ TIÊU THỤ + TỶ TRỌNG PHỤ TẢI ==================== */}
      <div className="grid grid-cols-1 lg:grid-cols-3 gap-4">
        <div
          className={`lg:col-span-2 p-5 rounded-2xl border flex flex-col justify-between ${cardBg}`}
        >
          <div className="flex flex-wrap items-start justify-between gap-3 mb-4">
            <div>
              <h2 className="font-bold text-sm">
                Biểu đồ tiêu thụ điện năng theo {unitLabel} (kWh)
              </h2>
            </div>

            <div className="flex flex-wrap items-center gap-3 text-xs">
              <div className="flex items-center gap-3 mr-1">
                <span className="inline-flex items-center gap-1.5 text-slate-400">
                  <span className="w-2 h-2 rounded-full bg-cyan-400" />
                  Bình thường
                </span>
                <span className="inline-flex items-center gap-1.5 text-slate-400">
                  <span className="w-2 h-2 rounded-full bg-amber-400" />
                  Đỉnh ({formatKwh(chartStats.peakPoint.kwh)} kWh)
                </span>
              </div>

              <div className="inline-flex rounded-xl bg-slate-900/90 border border-slate-800 p-0.5">
                {(
                  [
                    { key: 'day', label: 'Ngày' },
                    { key: 'week', label: 'Tuần' },
                    { key: 'month', label: 'Tháng' },
                  ] as const
                ).map((tab) => (
                  <button
                    key={tab.key}
                    type="button"
                    onClick={() => onPeriodChange(tab.key)}
                    className={`px-3 py-1 rounded-lg text-xs font-semibold transition ${
                      period === tab.key
                        ? 'bg-emerald-500 text-slate-950'
                        : 'text-slate-400 hover:text-slate-200'
                    }`}
                  >
                    {tab.label}
                  </button>
                ))}
              </div>

              <div className="inline-flex rounded-xl bg-slate-900/90 border border-slate-800 p-0.5">
                <button
                  type="button"
                  onClick={() => setChartType('bar')}
                  className={`px-3 py-1 rounded-lg text-xs font-semibold transition ${
                    chartType === 'bar'
                      ? 'bg-cyan-500 text-slate-950'
                      : 'text-slate-400 hover:text-slate-200'
                  }`}
                >
                  Cột
                </button>
                <button
                  type="button"
                  onClick={() => setChartType('line')}
                  className={`px-3 py-1 rounded-lg text-xs font-semibold transition ${
                    chartType === 'line'
                      ? 'bg-cyan-500 text-slate-950'
                      : 'text-slate-400 hover:text-slate-200'
                  }`}
                >
                  Đường mượt
                </button>
              </div>
            </div>
          </div>

          <div className="relative rounded-xl border border-slate-800/80 bg-[#090f1e] p-4 pt-6">
            {hoveredIdx !== null && chartStats.points[hoveredIdx] && (
              <div className="absolute top-2 right-3 z-10 px-3 py-1.5 rounded-lg bg-slate-900/95 border border-cyan-500/40 text-xs shadow-lg pointer-events-none">
                <span className="font-bold text-cyan-400 mr-2">
                  {chartStats.points[hoveredIdx].label}
                </span>
                <span className="font-mono text-white mr-2">
                  {formatKwh(chartStats.points[hoveredIdx].kwh)} kWh
                </span>
                <span className="text-emerald-400 font-mono">
                  (~
                  {Math.round(
                    chartStats.points[hoveredIdx].kwh * UNIT_PRICE_VND
                  ).toLocaleString('vi-VN')}{' '}
                  đ)
                </span>
              </div>
            )}

            <div className="flex gap-3">
              <div className="flex flex-col justify-between text-[10px] font-mono text-slate-500 py-1 select-none">
                <span>{chartStats.maxScale.toFixed(2)}</span>
                <span>{(chartStats.maxScale * 0.75).toFixed(2)}</span>
                <span>{(chartStats.maxScale * 0.5).toFixed(2)}</span>
                <span>{(chartStats.maxScale * 0.25).toFixed(2)}</span>
                <span>0.00</span>
              </div>

              <div className="flex-1 relative h-52 flex flex-col justify-end">
                <div className="absolute inset-0 flex flex-col justify-between pointer-events-none">
                  {[0, 1, 2, 3, 4].map((line) => (
                    <div
                      key={line}
                      className="w-full border-b border-dashed border-slate-800/80"
                    />
                  ))}
                </div>

                {chartStats.avgKwh > 0 && (
                  <div
                    style={{
                      bottom: `${Math.min(
                        100,
                        (chartStats.avgKwh / chartStats.maxScale) * 100
                      )}%`,
                    }}
                    className="absolute left-0 right-0 border-t border-dashed border-emerald-400/70 pointer-events-none z-10"
                  />
                )}

                {chartType === 'bar' ? (
                  <div className="relative z-10 h-full flex items-end gap-1.5 px-1">
                    {chartStats.points.map((pt, idx) => {
                      const ratio = Math.min(1, pt.kwh / chartStats.maxScale);
                      const heightPct = pt.kwh > 0 ? Math.max(6, ratio * 100) : 2;
                      const isPeak =
                        pt.kwh > 0 && pt.kwh === chartStats.peakPoint.kwh;

                      return (
                        <div
                          key={`${pt.label}-${idx}`}
                          onMouseEnter={() => setHoveredIdx(idx)}
                          onMouseLeave={() => setHoveredIdx(null)}
                          className="flex-1 h-full flex flex-col justify-end items-center group cursor-pointer"
                        >
                          <div
                            style={{ height: `${heightPct}%` }}
                            className={`w-full max-w-[18px] rounded-t-md transition-all duration-200 ${
                              isPeak
                                ? 'bg-amber-400 group-hover:bg-amber-300'
                                : pt.kwh > 0
                                ? 'bg-cyan-400 group-hover:bg-cyan-300'
                                : 'bg-cyan-500/40 group-hover:bg-cyan-400'
                            }`}
                          />
                        </div>
                      );
                    })}
                  </div>
                ) : (
                  <svg
                    viewBox="0 0 600 180"
                    preserveAspectRatio="none"
                    className="relative z-10 w-full h-full overflow-visible"
                  >
                    {(() => {
                      const pts = chartStats.points;
                      const stepX = pts.length > 1 ? 600 / (pts.length - 1) : 300;
                      const coords = pts.map((p, i) => {
                        const x = i * stepX;
                        const y = 176 - (p.kwh / chartStats.maxScale) * 168;
                        return { x, y, pt: p, idx: i };
                      });
                      const pathD = coords
                        .map((c, i) => `${i === 0 ? 'M' : 'L'} ${c.x} ${c.y}`)
                        .join(' ');
                      const areaD = `${pathD} L 600 180 L 0 180 Z`;

                      return (
                        <>
                          <path d={areaD} fill="rgba(6, 182, 212, 0.12)" />
                          <path
                            d={pathD}
                            fill="none"
                            stroke="#22d3ee"
                            strokeWidth="2.5"
                            strokeLinecap="round"
                            strokeLinejoin="round"
                          />
                          {coords.map((c) => (
                            <circle
                              key={c.idx}
                              cx={c.x}
                              cy={c.y}
                              r={hoveredIdx === c.idx ? 5 : 3}
                              fill={
                                c.pt.kwh > 0 &&
                                c.pt.kwh === chartStats.peakPoint.kwh
                                  ? '#fbbf24'
                                  : '#22d3ee'
                              }
                              className="cursor-pointer"
                              onMouseEnter={() => setHoveredIdx(c.idx)}
                              onMouseLeave={() => setHoveredIdx(null)}
                            />
                          ))}
                        </>
                      );
                    })()}
                  </svg>
                )}
              </div>
            </div>

            <div className="flex justify-between pl-9 pr-1 mt-2 text-[10px] font-mono text-slate-500">
              {chartStats.points.map((pt, idx) => {
                const showLabel =
                  chartStats.points.length <= 12 ||
                  idx % Math.ceil(chartStats.points.length / 6) === 0 ||
                  idx === chartStats.points.length - 1;
                return (
                  <span key={`${pt.label}-x-${idx}`} className="truncate">
                    {showLabel ? pt.label : ''}
                  </span>
                );
              })}
            </div>
          </div>
        </div>

        {/* Tỷ trọng Công suất Tức thời */}
        <div
          className={`p-5 rounded-2xl border flex flex-col justify-between ${cardBg}`}
        >
          <div>
            <h2 className="font-bold text-sm">Tỷ trọng Công suất Tức thời</h2>
          </div>

          <div className="my-4 flex items-center justify-center">
            <div className="relative w-44 h-44 flex items-center justify-center">
              <svg viewBox="0 0 110 110" className="w-full h-full -rotate-90">
                <circle
                  cx="55"
                  cy="55"
                  r={radius}
                  fill="none"
                  stroke="#1e293b"
                  strokeWidth="12"
                />
                {deviceLoadBreakdown.totalLiveWatt > 0 &&
                  deviceLoadBreakdown.groups.map((grp) => {
                    if (grp.watt <= 0) return null;
                    const fraction = grp.watt / deviceLoadBreakdown.totalLiveWatt;
                    const dashLength = fraction * circumference;
                    const dashOffset = -cumulativeOffset;
                    cumulativeOffset += dashLength;

                    return (
                      <circle
                        key={grp.key}
                        cx="55"
                        cy="55"
                        r={radius}
                        fill="none"
                        stroke={grp.color}
                        strokeWidth="12"
                        strokeDasharray={`${dashLength} ${circumference}`}
                        strokeDashoffset={dashOffset}
                        strokeLinecap="butt"
                      />
                    );
                  })}
              </svg>
              <div className="absolute inset-0 flex flex-col items-center justify-center text-center">
                <span className="text-[10px] font-bold uppercase tracking-wider text-slate-400">
                  TỔNG TẢI
                </span>
                <span className="text-xl font-extrabold text-cyan-400 font-mono">
                  {deviceLoadBreakdown.totalLiveWatt}W
                </span>
                <span className="text-[11px] text-slate-400">
                  {deviceLoadBreakdown.activeCount} thiết bị bật
                </span>
              </div>
            </div>
          </div>

          <div className="space-y-2.5 text-xs">
            {deviceLoadBreakdown.groups.map((grp) => (
              <div key={grp.key} className="flex items-center justify-between">
                <div className="flex items-center gap-2 text-slate-300">
                  <span className={`w-2.5 h-2.5 rounded-full ${grp.dotClass}`} />
                  <span>{grp.label}</span>
                </div>
                <div className="font-mono">
                  <strong className="text-slate-100">{grp.watt}W</strong>{' '}
                  <span className="text-slate-500">({grp.pct}%)</span>
                </div>
              </div>
            ))}
          </div>
        </div>
      </div>

      {/* ==================== ROW 3: CHI TIẾT CÔNG SUẤT TỪNG THIẾT BỊ IOT ==================== */}
      <div className={`p-5 rounded-2xl border ${cardBg}`}>
        <div className="flex items-center justify-between mb-4">
          <h2 className="font-bold text-sm">
            Chi tiết công suất từng thiết bị IoT
          </h2>
          <span className="text-xs font-mono text-slate-400">
            Tổng: {deviceLoadBreakdown.items.length} thiết bị
          </span>
        </div>

        {deviceLoadBreakdown.items.length === 0 ? (
          <div className="p-8 text-center text-xs text-slate-500">
            Chưa có thiết bị IoT nào trong hệ thống.
          </div>
        ) : (
          <div className="overflow-x-auto">
            <table className="w-full text-left text-xs">
              <thead className="border-b border-slate-800 text-slate-400 uppercase text-[11px]">
                <tr>
                  <th className="py-2.5 px-3">Thiết bị</th>
                  <th className="py-2.5 px-3">Phòng</th>
                  <th className="py-2.5 px-3">Trạng thái</th>
                  <th className="py-2.5 px-3">Mức tải</th>
                  <th className="py-2.5 px-3 text-right">Công suất</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-slate-800/70">
                {deviceLoadBreakdown.items.map((dev) => {
                  const loadSharePct =
                    deviceLoadBreakdown.totalLiveWatt > 0
                      ? Math.round(
                          (dev.currentWatt /
                            deviceLoadBreakdown.totalLiveWatt) *
                            100
                        )
                      : 0;
                  const isSensor = dev.device_type
                    .toLowerCase()
                    .includes('sensor');

                  return (
                    <tr
                      key={dev.id}
                      className="hover:bg-slate-800/30 transition"
                    >
                      <td className="py-3 px-3 font-bold">{dev.name}</td>
                      <td className="py-3 px-3 text-slate-400">
                        {dev.room_name || 'Chưa phân phòng'}
                      </td>
                      <td className="py-3 px-3">
                        {dev.is_on ? (
                          <span className="px-2 py-0.5 rounded bg-emerald-500/15 text-emerald-400 text-[10px] font-bold">
                            {isSensor ? 'ONLINE' : 'ĐANG BẬT'}
                          </span>
                        ) : (
                          <span className="px-2 py-0.5 rounded bg-slate-800 text-slate-400 text-[10px] font-semibold">
                            ĐANG TẮT
                          </span>
                        )}
                      </td>
                      <td className="py-3 px-3 w-48">
                        <div className="flex items-center gap-2">
                          <div className="flex-1 h-1.5 rounded-full bg-slate-800 overflow-hidden">
                            <div
                              style={{
                                width: `${
                                  dev.is_on ? Math.max(4, loadSharePct) : 0
                                }%`,
                              }}
                              className="h-full rounded-full bg-cyan-400 transition-all duration-300"
                            />
                          </div>
                          <span className="text-[10px] font-mono text-slate-500 w-8 text-right">
                            {loadSharePct}%
                          </span>
                        </div>
                      </td>
                      <td className="py-3 px-3 text-right font-mono font-bold text-cyan-400">
                        {dev.currentWatt} W
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        )}
      </div>
    </div>
  );
};

export default EnergyAnalyticsPanel;