import Image from "next/image";

interface LogoProps {
  className?: string;
  size?: "sm" | "md" | "lg" | "xl";
}

const sizeMap = {
  sm: { width: 32, height: 32 },
  md: { width: 48, height: 48 },
  lg: { width: 80, height: 80 },
  xl: { width: 120, height: 120 },
};

export function MeynLogo({ className = "", size = "md" }: LogoProps) {
  const dimensions = sizeMap[size];
  
  return (
    <div className={`relative overflow-hidden rounded-lg ${className}`} style={{ width: dimensions.width, height: dimensions.height }}>
      <Image
        src="/meyn-logo.jpg"
        alt="Meyn Logo"
        width={dimensions.width}
        height={dimensions.height}
        className="h-full w-full object-cover"
        priority
      />
    </div>
  );
}
