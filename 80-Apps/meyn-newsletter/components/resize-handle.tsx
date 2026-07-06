"use client";

import { useCallback, useEffect, useState, useRef } from "react";
import { cn } from "@/lib/utils";
import { GripVertical } from "lucide-react";

interface ResizeHandleProps {
  onResize: (width: number) => void;
  minWidth?: number;
  maxWidth?: number;
  className?: string;
}

export function ResizeHandle({
  onResize,
  minWidth = 320,
  maxWidth = 800,
  className,
}: ResizeHandleProps) {
  const [isDragging, setIsDragging] = useState(false);
  const handleRef = useRef<HTMLDivElement>(null);

  const handleMouseDown = useCallback((e: React.MouseEvent) => {
    e.preventDefault();
    setIsDragging(true);
  }, []);

  useEffect(() => {
    if (!isDragging) return;

    const handleMouseMove = (e: MouseEvent) => {
      const newWidth = Math.min(Math.max(e.clientX, minWidth), maxWidth);
      onResize(newWidth);
    };

    const handleMouseUp = () => {
      setIsDragging(false);
    };

    document.addEventListener("mousemove", handleMouseMove);
    document.addEventListener("mouseup", handleMouseUp);

    // Change cursor globally while dragging
    document.body.style.cursor = "col-resize";
    document.body.style.userSelect = "none";

    return () => {
      document.removeEventListener("mousemove", handleMouseMove);
      document.removeEventListener("mouseup", handleMouseUp);
      document.body.style.cursor = "";
      document.body.style.userSelect = "";
    };
  }, [isDragging, minWidth, maxWidth, onResize]);

  return (
    <div
      ref={handleRef}
      onMouseDown={handleMouseDown}
      className={cn(
        "group flex w-2 cursor-col-resize items-center justify-center border-x border-border bg-muted/30 transition-colors hover:bg-muted",
        isDragging && "bg-primary/20",
        className
      )}
    >
      <GripVertical
        className={cn(
          "h-4 w-4 text-muted-foreground/50 transition-colors group-hover:text-muted-foreground",
          isDragging && "text-primary"
        )}
      />
    </div>
  );
}
