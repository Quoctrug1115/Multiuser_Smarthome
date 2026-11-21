interface HubLogoIconProps {
  size?: number;
  className?: string;
}

export function HubLogoIcon({ size = 40, className = '' }: HubLogoIconProps) {
  return (
    <div
      style={{ width: size, height: size }}
      className={`rounded-full bg-[#00F0FF]/15 border-2 border-[#00F0FF] flex items-center justify-center shrink-0 text-[#00F0FF] ${className}`}
    >
      <svg
        viewBox="0 0 24 24"
        fill="currentColor"
        style={{ width: size * 0.62, height: size * 0.62 }}
        aria-hidden="true"
      >
        {/* 5 nhánh nối từ tâm ra 5 nút */}
        <g stroke="currentColor" strokeWidth="1.9" strokeLinecap="round">
          <line x1="12" y1="12.5" x2="12" y2="5.2" />
          <line x1="12" y1="12.5" x2="18.9" y2="10.2" />
          <line x1="12" y1="12.5" x2="16.3" y2="18.4" />
          <line x1="12" y1="12.5" x2="7.7" y2="18.4" />
          <line x1="12" y1="12.5" x2="5.1" y2="10.2" />
        </g>
        {/* Tâm ở giữa */}
        <circle cx="12" cy="12.5" r="3.2" />
        {/* 5 nút tròn xung quanh */}
        <circle cx="12" cy="5.2" r="2.2" />
        <circle cx="18.9" cy="10.2" r="2.2" />
        <circle cx="16.3" cy="18.4" r="2.2" />
        <circle cx="7.7" cy="18.4" r="2.2" />
        <circle cx="5.1" cy="10.2" r="2.2" />
      </svg>
    </div>
  );
}