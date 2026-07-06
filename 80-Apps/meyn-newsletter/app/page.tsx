"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import { arrayMove } from "@dnd-kit/sortable";
import {
  useMsal,
  useIsAuthenticated,
} from "@azure/msal-react";
import {
  FileText,
  Mail,
  CloudOff,
  RefreshCw,
} from "lucide-react";
import { Badge } from "@/components/ui/badge";
import { Separator } from "@/components/ui/separator";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";
import {
  TooltipProvider,
} from "@/components/ui/tooltip";
import UploadDropzone from "@/components/newsletter/upload-dropzone";
import MessageList from "@/components/newsletter/message-list";
import MessagePreview from "@/components/newsletter/message-preview";
import MessageEditor from "@/components/newsletter/message-editor";
import SyncButton from "@/components/newsletter/sync-button";
import { MeynLogo } from "@/components/meyn-logo";

import { ScheduleManager } from "@/components/newsletter/schedule-manager";
import { SendSchedule } from "@/components/newsletter/send-schedule";
import { OneDriveCatalog } from "@/components/newsletter/onedrive-catalog";
import { AuthGate } from "@/components/auth/auth-gate";
import LoginButton from "@/components/auth/login-button";
import { ThemeToggle } from "@/components/theme-toggle";
import { LanguageToggle } from "@/components/i18n/language-toggle";
import { ResizablePanelGroup, ResizablePanel, ResizableHandle } from "@/components/ui/resizable";
import { useTranslation } from "@/lib/i18n";
import { createGraphClient } from "@/lib/graph-client";
import { syncToOneDrive, getNextNewsletterNumber, uploadFile } from "@/lib/onedrive";
import type { NewsletterMessage, SyncResult } from "@/lib/types";
import type { Client } from "@microsoft/microsoft-graph-client";

const STORAGE_KEY = "hse-newsletter-messages";

function loadMessages(): NewsletterMessage[] {
  if (typeof window === "undefined") return [];
  try {
    const stored = localStorage.getItem(STORAGE_KEY);
    if (!stored) return [];
    const parsed = JSON.parse(stored);
    return parsed.map((m: NewsletterMessage) => ({
      ...m,
      lastModified: new Date(m.lastModified),
    }));
  } catch {
    return [];
  }
}

function saveMessages(messages: NewsletterMessage[]) {
  if (typeof window === "undefined") return;
  localStorage.setItem(STORAGE_KEY, JSON.stringify(messages));
}

export default function DashboardPage() {
  const { t } = useTranslation();
  const { instance, accounts } = useMsal();
  const isAuthenticated = useIsAuthenticated();

  const [messages, setMessages] = useState<NewsletterMessage[]>([]);
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [editingId, setEditingId] = useState<string | null>(null);
  const [isLoaded, setIsLoaded] = useState(false);
  const [activeTab, setActiveTab] = useState("sendschedule");
  const [catalogPreview, setCatalogPreview] = useState<{
    title: string;
    html: string;
  } | null>(null);
  const [scheduleRefreshKey, setScheduleRefreshKey] = useState(0);
  const [nextAutoNumber, setNextAutoNumber] = useState<number | undefined>();

  // Graph client memoised on the MSAL instance
  const graphClient: Client | null = useMemo(() => {
    if (isAuthenticated && instance) {
      try {
        return createGraphClient(instance);
      } catch {
        return null;
      }
    }
    return null;
  }, [isAuthenticated, instance]);

  const userName = accounts[0]?.name || accounts[0]?.username || "";

  // Load / persist messages
  useEffect(() => {
    setMessages(loadMessages());
    setIsLoaded(true);
  }, []);

  // Fetch next auto number when authenticated
  useEffect(() => {
    if (isAuthenticated && graphClient) {
      getNextNewsletterNumber(graphClient)
        .then((num) => setNextAutoNumber(num))
        .catch(() => setNextAutoNumber(1));
    }
  }, [graphClient, isAuthenticated]);

  useEffect(() => {
    if (isLoaded) saveMessages(messages);
  }, [messages, isLoaded]);

  // Derived
  const selectedMessage = useMemo(
    () => messages.find((m) => m.id === selectedId) || null,
    [messages, selectedId]
  );
  const editingMessage = useMemo(
    () => messages.find((m) => m.id === editingId) || null,
    [messages, editingId]
  );
  const stats = useMemo(
    () => ({
      total: messages.length,
      draft: messages.filter((m) => m.status === "draft").length,
      synced: messages.filter((m) => m.status === "synced").length,
    }),
    [messages]
  );

  // Handlers
  const handleFilesConverted = useCallback(
    (newMessages: NewsletterMessage[]) => {
      setMessages((prev) => {
        const updated = [...prev, ...newMessages];
        return updated.map((m, i) => ({ ...m, order: i + 1 }));
      });
    },
    []
  );

  const handleReorder = useCallback(
    (activeId: string, overId: string) => {
      setMessages((prev) => {
        const oldIndex = prev.findIndex((m) => m.id === activeId);
        const newIndex = prev.findIndex((m) => m.id === overId);
        const reordered = arrayMove(prev, oldIndex, newIndex);
        return reordered.map((m, i) => ({
          ...m,
          order: i + 1,
          status: m.status === "synced" ? ("draft" as const) : m.status,
        }));
      });
    },
    []
  );

  const handleMoveUp = useCallback((id: string) => {
    setMessages((prev) => {
      const idx = prev.findIndex((m) => m.id === id);
      if (idx <= 0) return prev;
      const reordered = arrayMove(prev, idx, idx - 1);
      return reordered.map((m, i) => ({
        ...m,
        order: i + 1,
        status: m.status === "synced" ? ("draft" as const) : m.status,
      }));
    });
  }, []);

  const handleMoveDown = useCallback((id: string) => {
    setMessages((prev) => {
      const idx = prev.findIndex((m) => m.id === id);
      if (idx < 0 || idx >= prev.length - 1) return prev;
      const reordered = arrayMove(prev, idx, idx + 1);
      return reordered.map((m, i) => ({
        ...m,
        order: i + 1,
        status: m.status === "synced" ? ("draft" as const) : m.status,
      }));
    });
  }, []);

  const handleDelete = useCallback(
    (id: string) => {
      setMessages((prev) => {
        const filtered = prev.filter((m) => m.id !== id);
        return filtered.map((m, i) => ({ ...m, order: i + 1 }));
      });
      if (selectedId === id) setSelectedId(null);
      if (editingId === id) setEditingId(null);
    },
    [selectedId, editingId]
  );

  const handleSave = useCallback(
    (id: string, updates: Partial<NewsletterMessage>) => {
      setMessages((prev) =>
        prev.map((m) => (m.id === id ? { ...m, ...updates } : m))
      );
    },
    []
  );

  const handleSync = useCallback(
    async (msgs: NewsletterMessage[]): Promise<SyncResult> => {
      if (!graphClient) {
        // Demo mode
        await new Promise((r) => setTimeout(r, 2000));
        return { uploaded: msgs.length, deleted: 0, errors: [] };
      }
      return syncToOneDrive(graphClient, msgs);
    },
    [graphClient]
  );

  const handleSyncComplete = useCallback(
    async (result: SyncResult) => {
      if (result.errors.length === 0) {
        setMessages((prev) =>
          prev.map((m) => ({ ...m, status: "synced" as const }))
        );
        // After successful sync, fetch the next auto number for new uploads
        if (graphClient) {
          const nextNum = await getNextNewsletterNumber(graphClient);
          setNextAutoNumber(nextNum);
        }
      }
    },
    [graphClient]
  );

  const handleAutoSync = useCallback(
    async (newMessages: NewsletterMessage[]) => {
      if (!graphClient) return;
      for (const msg of newMessages) {
        const padded = String(msg.order).padStart(2, "0");
        const safe = msg.title.replace(/[<>:"/\\|?*]/g, "-").trim();
        const fileName = `${padded}-${safe}.html`;
        await uploadFile(graphClient, undefined, fileName, msg.htmlContent);
      }
      // Mark these messages as synced
      setMessages((prev) =>
        prev.map((m) =>
          newMessages.some((nm) => nm.id === m.id)
            ? { ...m, status: "synced" as const }
            : m
        )
      );
      // Refresh the next auto number and Send Schedule
      const nextNum = await getNextNewsletterNumber(graphClient);
      setNextAutoNumber(nextNum);
      setScheduleRefreshKey((k) => k + 1);
    },
    [graphClient]
  );

  const handleImportMessage = useCallback((msg: NewsletterMessage) => {
    setMessages((prev) => {
      const updated = [...prev, { ...msg, order: prev.length + 1, status: "draft" as const }];
      return updated.map((m, i) => ({ ...m, order: i + 1 }));
    });
  }, []);

  const handleCatalogPreview = useCallback(
    (title: string, html: string) => {
      setCatalogPreview({ title, html });
      setSelectedId(null);
      setEditingId(null);
    },
    []
  );

  const handleScheduleSaved = useCallback(() => {
    // Increment key to force SendSchedule to refresh
    setScheduleRefreshKey((k) => k + 1);
  }, []);

  if (!isLoaded) {
    return (
      <div className="flex min-h-screen items-center justify-center bg-background">
        <div className="h-8 w-8 animate-spin rounded-full border-4 border-primary border-t-transparent" />
      </div>
    );
  }

  return (
    <AuthGate>
      <TooltipProvider>
        <div className="flex h-screen flex-col bg-background">
          {/* Top navigation bar */}
          <header className="sticky top-0 z-40 border-b bg-card">
            <div className="flex h-14 items-center justify-between px-4 lg:px-6">
              {/* Left: Brand */}
              <div className="flex items-center gap-3">
                <MeynLogo size="lg" />
                <div>
                  <h1 className="text-sm font-bold leading-none text-card-foreground">
                    {t("app.title")}
                  </h1>
                  <p className="mt-0.5 text-[10px] text-muted-foreground">
                    {t("app.subtitle")}
                  </p>
                </div>
              </div>

              {/* Center: Stats */}
              <div className="hidden items-center gap-3 md:flex">
                <div className="flex items-center gap-1.5">
                  <FileText className="h-3.5 w-3.5 text-muted-foreground" />
                  <span className="text-xs text-muted-foreground">
                    {stats.total} {t("header.messages")}
                  </span>
                </div>
                <Separator orientation="vertical" className="h-4" />
                <div className="flex items-center gap-1.5">
                  <Mail className="h-3.5 w-3.5 text-primary" />
                  <span className="text-xs text-muted-foreground">
                    {stats.draft} {t("header.drafts")}
                  </span>
                </div>
                <Separator orientation="vertical" className="h-4" />
                <Badge
                  variant="outline"
                  className="gap-1 bg-green-500/10 text-[10px] text-green-700 border-green-500/20 px-1.5 py-0 dark:text-green-400"
                >
                  {stats.synced} {t("header.synced")}
                </Badge>
              </div>

              {/* Right: Actions */}
              <div className="flex items-center gap-2">
                {!graphClient && (
                  <Badge
                    variant="outline"
                    className="gap-1 text-[10px] bg-accent/10 text-accent-foreground border-accent/30"
                  >
                    <CloudOff className="h-3 w-3" />
                    {t("header.demoMode")}
                  </Badge>
                )}

                <LanguageToggle />
                <ThemeToggle />

                <SyncButton
                  messages={messages}
                  onSync={handleSync}
                  onSyncComplete={handleSyncComplete}
                  disabled={messages.length === 0}
                />

                <LoginButton />
              </div>
            </div>
          </header>

          {/* Main content */}
          <main className="min-h-0 flex-1 overflow-hidden">
            <ResizablePanelGroup
              direction="horizontal"
              autoSaveId="hse-panel-layout"
              className="h-full"
            >
            {/* Left panel: Upload + Tabbed content */}
            <ResizablePanel
              defaultSize={42}
              minSize={28}
              maxSize={60}
              className="flex flex-col border-r bg-card/50"
            >
              {/* Upload section */}
              <div className="border-b p-4">
                <UploadDropzone
                  onFilesConverted={handleFilesConverted}
                  existingCount={messages.length}
                  nextAutoNumber={nextAutoNumber}
                  onAutoSync={isAuthenticated && graphClient ? handleAutoSync : undefined}
                />
              </div>

              {/* Tabs: Send Schedule / Upload Queue / Skip Days */}
              <Tabs
                value={activeTab}
                onValueChange={setActiveTab}
                className="flex min-h-0 flex-1 flex-col"
              >
                <div className="border-b px-2 overflow-x-auto">
                  <TabsList className="h-9 w-full justify-start bg-transparent p-0">
                    <TabsTrigger
                      value="sendschedule"
                      className="shrink-0 rounded-none border-b-2 border-transparent px-3 py-1.5 text-xs data-[state=active]:border-primary data-[state=active]:bg-transparent data-[state=active]:shadow-none"
                    >
                      {t("tabs.sendSchedule")}
                    </TabsTrigger>
                    <TabsTrigger
                      value="queue"
                      className="shrink-0 rounded-none border-b-2 border-transparent px-3 py-1.5 text-xs data-[state=active]:border-primary data-[state=active]:bg-transparent data-[state=active]:shadow-none"
                    >
                      {t("tabs.queue")}
                      {messages.length > 0 && (
                        <Badge
                          variant="secondary"
                          className="ml-1.5 h-4 px-1 text-[10px]"
                        >
                          {messages.length}
                        </Badge>
                      )}
                    </TabsTrigger>
                    <TabsTrigger
                      value="catalog"
                      className="shrink-0 rounded-none border-b-2 border-transparent px-3 py-1.5 text-xs data-[state=active]:border-primary data-[state=active]:bg-transparent data-[state=active]:shadow-none"
                    >
                      {t("tabs.catalog")}
                    </TabsTrigger>
                    <TabsTrigger
                      value="schedule"
                      className="shrink-0 rounded-none border-b-2 border-transparent px-3 py-1.5 text-xs data-[state=active]:border-primary data-[state=active]:bg-transparent data-[state=active]:shadow-none"
                    >
                      {t("tabs.skipDays")}
                    </TabsTrigger>
                  </TabsList>
                </div>

                {/* Send Schedule tab - shows what gets sent on which day */}
                <TabsContent
                  value="sendschedule"
                  className="m-0 min-h-0 flex-1 overflow-y-auto"
                >
                  <div className="p-4">
                    <SendSchedule
                      key={scheduleRefreshKey}
                      graphClient={graphClient}
                      isAuthenticated={isAuthenticated}
                      onPreviewHtml={handleCatalogPreview}
                    />
                  </div>
                </TabsContent>

                {/* Upload Queue tab - for preparing new newsletters */}
                <TabsContent
                  value="queue"
                  className="m-0 flex min-h-0 flex-1 flex-col overflow-hidden"
                >
                  <div className="shrink-0 border-b px-4 py-2">
                    <h2 className="text-xs font-semibold text-foreground">
                      {t("list.title")}
                    </h2>
                    <p className="mt-0.5 text-[10px] text-muted-foreground">
                      Upload .docx files, convert to HTML, then sync to OneDrive
                    </p>
                  </div>
                  <div className="min-h-0 flex-1 overflow-y-auto p-3">
                    <MessageList
                        messages={messages}
                        selectedId={selectedId}
                        onSelect={(id) => {
                          setSelectedId(id);
                          setCatalogPreview(null);
                          setEditingId(null);
                        }}
                        onDelete={handleDelete}
                        onPreview={(id) => {
                          setSelectedId(id);
                          setCatalogPreview(null);
                          setEditingId(null);
                        }}
                        onEdit={(id) => {
                          setEditingId(id);
                          setSelectedId(null);
                          setCatalogPreview(null);
                        }}
                        onReorder={handleReorder}
                        onMoveUp={handleMoveUp}
                        onMoveDown={handleMoveDown}
                      />
                  </div>
                </TabsContent>

                {/* OneDrive Catalog tab - browse files in OneDrive */}
                <TabsContent
                  value="catalog"
                  className="m-0 min-h-0 flex-1 overflow-y-auto"
                >
                  <div className="p-4">
                    <OneDriveCatalog
                      graphClient={graphClient}
                      isAuthenticated={isAuthenticated}
                      onImportMessage={handleImportMessage}
                      onPreviewHtml={handleCatalogPreview}
                    />
                  </div>
                </TabsContent>

                {/* Skip Days tab - mark holidays and days off */}
                <TabsContent
                  value="schedule"
                  className="m-0 min-h-0 flex-1 overflow-y-auto"
                >
                  <div className="p-4">
                    <ScheduleManager
                      graphClient={graphClient}
                      isAuthenticated={isAuthenticated}
                      userName={userName}
                      onScheduleSaved={handleScheduleSaved}
                    />
                  </div>
                </TabsContent>
              </Tabs>
            </ResizablePanel>

            <ResizableHandle withHandle className="hidden lg:flex" />

            {/* Right panel: Preview or Editor */}
            <ResizablePanel className="hidden lg:flex flex-col overflow-y-auto">
              <div className="flex-1 p-4">
                {editingId ? (
                  <MessageEditor
                    message={editingMessage}
                    onSave={handleSave}
                    onClose={() => setEditingId(null)}
                  />
                ) : (
                  <MessagePreview
                    message={selectedMessage}
                    externalHtml={catalogPreview}
                  />
                )}
              </div>
            </ResizablePanel>
            </ResizablePanelGroup>
          </main>

          {/* Footer */}
          <footer className="border-t bg-card px-4 py-2">
            <div className="flex items-center justify-between">
              <p className="text-[10px] text-muted-foreground">
                Power Automate sends messages Mon-Fri at 7:00 AM CET
              </p>
              <div className="flex items-center gap-1.5">
                <RefreshCw className="h-3 w-3 text-muted-foreground" />
                <span className="text-[10px] text-muted-foreground">
                  Auto-saved locally
                </span>
              </div>
            </div>
          </footer>
        </div>
      </TooltipProvider>
    </AuthGate>
  );
}
