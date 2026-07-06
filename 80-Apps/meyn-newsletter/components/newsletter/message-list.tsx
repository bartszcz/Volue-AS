"use client";

import {
  DndContext,
  closestCenter,
  KeyboardSensor,
  PointerSensor,
  useSensor,
  useSensors,
  type DragEndEvent,
} from "@dnd-kit/core";
import {
  SortableContext,
  sortableKeyboardCoordinates,
  verticalListSortingStrategy,
} from "@dnd-kit/sortable";
import { Inbox } from "lucide-react";
import { useTranslation } from "@/lib/i18n";
import MessageCard from "./message-card";
import type { NewsletterMessage } from "@/lib/types";

interface MessageListProps {
  messages: NewsletterMessage[];
  selectedId: string | null;
  onSelect: (id: string) => void;
  onDelete: (id: string) => void;
  onPreview: (id: string) => void;
  onEdit: (id: string) => void;
  onReorder: (activeId: string, overId: string) => void;
  onMoveUp: (id: string) => void;
  onMoveDown: (id: string) => void;
}

export default function MessageList({
  messages,
  selectedId,
  onSelect,
  onDelete,
  onPreview,
  onEdit,
  onReorder,
  onMoveUp,
  onMoveDown,
}: MessageListProps) {
  const { t } = useTranslation();
  const sensors = useSensors(
    useSensor(PointerSensor, {
      activationConstraint: { distance: 8 },
    }),
    useSensor(KeyboardSensor, {
      coordinateGetter: sortableKeyboardCoordinates,
    })
  );

  const handleDragEnd = (event: DragEndEvent) => {
    const { active, over } = event;
    if (over && active.id !== over.id) {
      onReorder(String(active.id), String(over.id));
    }
  };

  if (messages.length === 0) {
    return (
      <div className="flex flex-col items-center justify-center gap-3 py-12 text-center">
        <div className="rounded-full bg-muted p-4">
          <Inbox className="h-8 w-8 text-muted-foreground" />
        </div>
        <div>
          <p className="text-sm font-medium text-foreground">
            {t("list.empty")}
          </p>
          <p className="mt-1 text-xs text-muted-foreground">
            {t("list.emptyHint")}
          </p>
        </div>
      </div>
    );
  }

  return (
    <DndContext
      sensors={sensors}
      collisionDetection={closestCenter}
      onDragEnd={handleDragEnd}
    >
      <SortableContext
        items={messages.map((m) => m.id)}
        strategy={verticalListSortingStrategy}
      >
        <div className="flex flex-col gap-2">
          {messages.map((message, index) => (
            <MessageCard
              key={message.id}
              message={message}
              isSelected={selectedId === message.id}
              isFirst={index === 0}
              isLast={index === messages.length - 1}
              onSelect={() => onSelect(message.id)}
              onDelete={() => onDelete(message.id)}
              onPreview={() => onPreview(message.id)}
              onEdit={() => onEdit(message.id)}
              onMoveUp={() => onMoveUp(message.id)}
              onMoveDown={() => onMoveDown(message.id)}
            />
          ))}
        </div>
      </SortableContext>
    </DndContext>
  );
}
