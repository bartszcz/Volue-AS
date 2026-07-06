"use client";

import { useState, useRef, useEffect } from "react";
import { Eye, Code, Maximize2, Minimize2 } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";
import { useTranslation } from "@/lib/i18n";
import type { NewsletterMessage } from "@/lib/types";

interface MessagePreviewProps {
  message: NewsletterMessage | null;
  /** Allow showing arbitrary HTML content (for catalog preview) */
  externalHtml?: { title: string; html: string } | null;
}

export default function MessagePreview({
  message,
  externalHtml,
}: MessagePreviewProps) {
  const { t } = useTranslation();
  const [isExpanded, setIsExpanded] = useState(false);
  const iframeRef = useRef<HTMLIFrameElement>(null);

  const displayTitle = externalHtml?.title || message?.title || "";
  const displayHtml = externalHtml?.html || message?.htmlContent || "";

  useEffect(() => {
    if (iframeRef.current && displayHtml) {
      // Use srcdoc approach instead of document.write for better security
      iframeRef.current.srcdoc = displayHtml;
    }
  }, [displayHtml]);

  if (!message && !externalHtml) {
    return (
      <div className="flex h-full flex-col items-center justify-center gap-3 rounded-lg border border-dashed border-border bg-muted/20 p-8">
        <div className="rounded-full bg-muted p-3">
          <Eye className="h-6 w-6 text-muted-foreground" />
        </div>
        <div className="text-center">
          <p className="text-sm font-medium text-foreground">
            {t("preview.empty")}
          </p>
          <p className="mt-1 text-xs text-muted-foreground">
            {t("preview.emptyHint")}
          </p>
        </div>
      </div>
    );
  }

  return (
    <div
      className={
        isExpanded
          ? "fixed inset-4 z-50 flex flex-col rounded-xl border bg-card shadow-2xl"
          : "flex h-full flex-col rounded-lg border bg-card"
      }
    >
      {/* Header */}
      <div className="flex items-center justify-between border-b px-4 py-2.5">
        <h3 className="text-sm font-semibold text-card-foreground truncate">
          {displayTitle}
        </h3>
        <Button
          variant="ghost"
          size="icon"
          className="h-7 w-7 shrink-0"
          onClick={() => setIsExpanded(!isExpanded)}
          aria-label={isExpanded ? t("preview.collapse") : t("preview.expand")}
        >
          {isExpanded ? (
            <Minimize2 className="h-3.5 w-3.5" />
          ) : (
            <Maximize2 className="h-3.5 w-3.5" />
          )}
        </Button>
      </div>

      {/* Content */}
      <Tabs
        defaultValue="preview"
        className="flex flex-1 flex-col overflow-hidden"
      >
        <div className="border-b px-4">
          <TabsList className="h-9 bg-transparent p-0">
            <TabsTrigger
              value="preview"
              className="gap-1.5 rounded-none border-b-2 border-transparent px-3 py-1.5 text-xs data-[state=active]:border-primary data-[state=active]:bg-transparent data-[state=active]:shadow-none"
            >
              <Eye className="h-3.5 w-3.5" />
              {t("preview.title")}
            </TabsTrigger>
            <TabsTrigger
              value="source"
              className="gap-1.5 rounded-none border-b-2 border-transparent px-3 py-1.5 text-xs data-[state=active]:border-primary data-[state=active]:bg-transparent data-[state=active]:shadow-none"
            >
              <Code className="h-3.5 w-3.5" />
              {t("preview.source")}
            </TabsTrigger>
          </TabsList>
        </div>

        <TabsContent value="preview" className="flex-1 m-0 overflow-auto">
          <iframe
            ref={iframeRef}
            title="Email preview"
            className="h-full w-full border-0"
            sandbox="allow-same-origin"
          />
        </TabsContent>

        <TabsContent value="source" className="flex-1 m-0 overflow-auto p-4">
          <pre className="whitespace-pre-wrap break-words font-mono text-xs text-muted-foreground leading-relaxed">
            {displayHtml}
          </pre>
        </TabsContent>
      </Tabs>

      {isExpanded && (
        <div
          className="fixed inset-0 -z-10 bg-foreground/50"
          onClick={() => setIsExpanded(false)}
          aria-hidden
        />
      )}
    </div>
  );
}
