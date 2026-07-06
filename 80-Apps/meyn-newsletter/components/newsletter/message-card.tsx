"use client";

import { useSortable } from "@dnd-kit/sortable";
import { CSS } from "@dnd-kit/utilities";
import {
  GripVertical,
  Eye,
  Pencil,
  Trash2,
  CloudOff,
  Cloud,
  FileEdit,
  ChevronUp,
  ChevronDown,
} from "lucide-react";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { useTranslation } from "@/lib/i18n";
import type { NewsletterMessage } from "@/lib/types";
import { cn } from "@/lib/utils";

interface MessageCardProps {
  message: NewsletterMessage;
  isSelected: boolean;
  isFirst: boolean;
  isLast: boolean;
  onSelect: () => void;
  onDelete: () => void;
  onPreview: () => void;
  onEdit: () => void;
  onMoveUp: () => void;
  onMoveDown: () => void;
}

export default function MessageCard({
  message,
  isSelected,
  isFirst,
  isLast,
  onSelect,
  onDelete,
  onPreview,
  onEdit,
  onMoveUp,
  onMoveDown,
}: MessageCardProps) {
  const { t } = useTranslation();
  const {
    attributes,
    listeners,
    setNodeRef,
    transform,
    transition,
    isDragging,
  } = useSortable({ id: message.id });

  const style = {
    transform: CSS.Transform.toString(transform),
    transition,
  };

  const statusConfig = {
    draft: {
      label: t("card.draft"),
      icon: FileEdit,
      className: "bg-accent/15 text-accent-foreground border-accent/30",
    },
    queued: {
      label: "Queued",
      icon: CloudOff,
      className: "bg-primary/10 text-primary border-primary/30",
    },
    synced: {
      label: t("card.synced"),
      icon: Cloud,
      className: "bg-success/15 text-success border-success/30",
    },
  } as const;

  const statusInfo = statusConfig[message.status];
  const StatusIcon = statusInfo.icon;

  return (
    <div
      ref={setNodeRef}
      style={style}
      className={cn(
        "group flex items-center gap-3 rounded-lg border bg-card p-3 transition-all",
        isSelected
          ? "border-primary ring-1 ring-primary/20"
          : "border-border hover:border-primary/30",
        isDragging && "z-50 shadow-lg opacity-90"
      )}
    >
      {/* Drag handle */}
      <button
        {...attributes}
        {...listeners}
        className="flex shrink-0 cursor-grab items-center rounded p-1 text-muted-foreground hover:bg-muted hover:text-foreground active:cursor-grabbing"
        aria-label="Drag to reorder"
      >
        <GripVertical className="h-4 w-4" />
      </button>

      {/* Order number */}
      <div className="flex h-7 w-7 shrink-0 items-center justify-center rounded-md bg-primary/10 text-xs font-bold text-primary">
        {message.order}
      </div>

      {/* Content */}
      <button
        onClick={onSelect}
        className="flex min-w-0 flex-1 flex-col items-start gap-1 text-left"
      >
        <span className="w-full truncate text-sm font-medium text-card-foreground">
          {message.title}
        </span>
        <div className="flex items-center gap-2">
          <Badge
            variant="outline"
            className={cn(
              "gap-1 text-[10px] px-1.5 py-0",
              statusInfo.className
            )}
          >
            <StatusIcon className="h-3 w-3" />
            {statusInfo.label}
          </Badge>
          <span className="text-[10px] text-muted-foreground">
            {message.lastModified.toLocaleDateString()}
          </span>
        </div>
      </button>

      {/* Move up/down */}
      <div className="flex shrink-0 flex-col gap-0.5">
        <Button
          variant="ghost"
          size="icon"
          className="h-6 w-6 text-muted-foreground"
          onClick={onMoveUp}
          disabled={isFirst}
          aria-label={t("card.moveUp")}
        >
          <ChevronUp className="h-3.5 w-3.5" />
        </Button>
        <Button
          variant="ghost"
          size="icon"
          className="h-6 w-6 text-muted-foreground"
          onClick={onMoveDown}
          disabled={isLast}
          aria-label={t("card.moveDown")}
        >
          <ChevronDown className="h-3.5 w-3.5" />
        </Button>
      </div>

      {/* Actions */}
      <div className="flex shrink-0 items-center gap-0.5 opacity-0 transition-opacity group-hover:opacity-100">
        <Button
          variant="ghost"
          size="icon"
          className="h-7 w-7"
          onClick={onPreview}
          aria-label={t("preview.title")}
        >
          <Eye className="h-3.5 w-3.5" />
        </Button>
        <Button
          variant="ghost"
          size="icon"
          className="h-7 w-7"
          onClick={onEdit}
          aria-label={t("preview.edit")}
        >
          <Pencil className="h-3.5 w-3.5" />
        </Button>
        <Button
          variant="ghost"
          size="icon"
          className="h-7 w-7 text-destructive hover:text-destructive"
          onClick={onDelete}
          aria-label={t("card.delete")}
        >
          <Trash2 className="h-3.5 w-3.5" />
        </Button>
      </div>
    </div>
  );
}
