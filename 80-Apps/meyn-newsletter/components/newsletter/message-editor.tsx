"use client";

import { useState, useEffect } from "react";
import { Save, X } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Textarea } from "@/components/ui/textarea";
import { useTranslation } from "@/lib/i18n";
import type { NewsletterMessage } from "@/lib/types";

interface MessageEditorProps {
  message: NewsletterMessage | null;
  onSave: (id: string, updates: Partial<NewsletterMessage>) => void;
  onClose: () => void;
}

export default function MessageEditor({
  message,
  onSave,
  onClose,
}: MessageEditorProps) {
  const { t } = useTranslation();
  const [title, setTitle] = useState("");
  const [htmlContent, setHtmlContent] = useState("");

  useEffect(() => {
    if (message) {
      setTitle(message.title);
      setHtmlContent(message.htmlContent);
    }
  }, [message]);

  if (!message) return null;

  const handleSave = () => {
    onSave(message.id, {
      title,
      htmlContent,
      lastModified: new Date(),
      status: "draft",
    });
    onClose();
  };

  const hasChanges =
    title !== message.title || htmlContent !== message.htmlContent;

  return (
    <div className="flex h-full flex-col rounded-lg border bg-card">
      <div className="flex items-center justify-between border-b px-4 py-2.5">
        <h3 className="text-sm font-semibold text-card-foreground">
          {t("editor.title")}
        </h3>
        <div className="flex items-center gap-1.5">
          <Button
            variant="ghost"
            size="sm"
            onClick={onClose}
            className="h-7 gap-1 px-2 text-xs"
          >
            <X className="h-3.5 w-3.5" />
            {t("editor.cancel")}
          </Button>
          <Button
            size="sm"
            onClick={handleSave}
            disabled={!hasChanges}
            className="h-7 gap-1 px-2 text-xs"
          >
            <Save className="h-3.5 w-3.5" />
            {t("editor.save")}
          </Button>
        </div>
      </div>

      <div className="flex flex-1 flex-col gap-4 overflow-auto p-4">
        <div className="flex flex-col gap-1.5">
          <Label htmlFor="message-title" className="text-xs font-medium">
            Title
          </Label>
          <Input
            id="message-title"
            value={title}
            onChange={(e) => setTitle(e.target.value)}
            placeholder="Enter message title"
            className="h-9"
          />
        </div>

        <div className="flex flex-1 flex-col gap-1.5">
          <Label htmlFor="message-html" className="text-xs font-medium">
            HTML Content
          </Label>
          <Textarea
            id="message-html"
            value={htmlContent}
            onChange={(e) => setHtmlContent(e.target.value)}
            placeholder={t("editor.placeholder")}
            className="flex-1 resize-none font-mono text-xs leading-relaxed"
          />
        </div>
      </div>
    </div>
  );
}
