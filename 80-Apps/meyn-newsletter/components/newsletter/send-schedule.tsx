"use client";

import { useState, useEffect, useCallback, useMemo } from "react";
import { useTranslation } from "@/lib/i18n";
import type { OneDriveFile, ScheduleConfig } from "@/lib/types";
import type { Client } from "@microsoft/microsoft-graph-client";
import {
  listOneDriveFiles,
  getFileContent,
  getScheduleConfig,
  getDocumentIndex,
  saveScheduleConfig,
  renameFile,
} from "@/lib/onedrive";
import { Button } from "@/components/ui/button";
import { Badge } from "@/components/ui/badge";
import { ScrollArea } from "@/components/ui/scroll-area";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";
import {
  RefreshCw,
  Eye,
  Loader2,
  LogIn,
  AlertCircle,
  Calendar,
  Mail,
  CalendarOff,
  ChevronRight,
  GripVertical,
  ChevronUp,
  ChevronDown,
  Save,
  List,
} from "lucide-react";
import {
  format,
  addDays,
  isAfter,
  parseISO,
  isWeekend,
  isSameDay,
  startOfDay,
} from "date-fns";
import { pl as plLocale, enUS } from "date-fns/locale";

interface SendScheduleProps {
  graphClient: Client | null;
  isAuthenticated: boolean;
  onPreviewHtml: (title: string, html: string) => void;
}

interface ScheduledItem {
  date: Date;
  file: OneDriveFile | null;
  isSkipped: boolean;
  skipNote?: string;
  isToday: boolean;
  isPast: boolean;
}

/**
 * Given a stored (index, setDate) calibration, advance the index by the number
 * of non-skipped workdays that have elapsed since setDate.
 * todayEmailSent controls whether today itself counts as elapsed.
 */
function computeEffectiveIndex(
  storedIndex: number,
  setDate: string,
  n: number,
  skipSet: Set<string>,
  todayEmailSent: boolean
): number {
  const base = startOfDay(parseISO(setDate));
  const today = startOfDay(new Date());
  if (!isAfter(today, base)) return storedIndex;

  let count = 0;
  let cur = addDays(base, 1);
  while (!isAfter(cur, today)) {
    const isToday = isSameDay(cur, today);
    if (isToday && !todayEmailSent) break;
    if (!isWeekend(cur) && !skipSet.has(format(cur, "yyyy-MM-dd"))) count++;
    cur = addDays(cur, 1);
  }
  return (storedIndex + count) % n;
}

function getUpcomingDays(count: number, startFrom: Date = new Date()): Date[] {
  const days: Date[] = [];
  let current = startOfDay(startFrom);

  while (days.length < count) {
    if (!isWeekend(current)) {
      days.push(current);
    }
    current = addDays(current, 1);
  }
  return days;
}

export function SendSchedule({
  graphClient,
  isAuthenticated,
  onPreviewHtml,
}: SendScheduleProps) {
  const { t, locale } = useTranslation();
  const [files, setFiles] = useState<OneDriveFile[]>([]);
  const [orderedFiles, setOrderedFiles] = useState<OneDriveFile[]>([]);
  const [scheduleConfig, setScheduleConfig] = useState<ScheduleConfig>({
    skipDates: [],
    notes: {},
    lastUpdated: "",
    updatedBy: "",
  });
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [previewingId, setPreviewingId] = useState<string | null>(null);
  const [liveDocumentIndex, setLiveDocumentIndex] = useState<number | null>(null);
  const [savingOrder, setSavingOrder] = useState(false);
  const [hasOrderChanges, setHasOrderChanges] = useState(false);
  const [draggedIndex, setDraggedIndex] = useState<number | null>(null);
  const [activeView, setActiveView] = useState<"schedule" | "order">("schedule");

  const fetchData = useCallback(async () => {
    if (!graphClient) return;
    setLoading(true);
    setError(null);
    try {
      const [filesResult, configResult, excelIndex] = await Promise.all([
        listOneDriveFiles(graphClient),
        getScheduleConfig(graphClient),
        getDocumentIndex(graphClient),
      ]);
      setFiles(filesResult);
      // Sort by the sequence number embedded in the filename.
      // For double-numbered files like "01-02..Title.html" the number before ".."
      // is the original correct sequence; fall back to the outer prefix otherwise.
      const fileOrder = (name: string) => {
        const inner = name.match(/(\d+)\.\./);
        if (inner) return parseInt(inner[1], 10);
        return parseInt(name.match(/^(\d+)[-\.]/)?.[1] || "999", 10);
      };
      const sorted = [...filesResult].sort((a, b) => fileOrder(a.name) - fileOrder(b.name));
      setOrderedFiles(sorted);
      setScheduleConfig(configResult);
      setLiveDocumentIndex(excelIndex); // null = Excel unreachable, use manual calibration
      setHasOrderChanges(false);
    } catch {
      setError(t("catalog.error"));
    } finally {
      setLoading(false);
    }
  }, [graphClient, t]);

  useEffect(() => {
    if (isAuthenticated && graphClient) {
      fetchData();
    } else {
      setLoading(false);
    }
  }, [isAuthenticated, graphClient, fetchData]);

  // Build the schedule: map files to upcoming workdays with cycling,
  // anchored to the real Excel counter Power Automate uses.
  const schedule = useMemo((): ScheduledItem[] => {
    if (orderedFiles.length === 0) return [];

    const n = orderedFiles.length;
    const today = startOfDay(new Date());
    const numDays = Math.max(n * 2, 30);
    const upcomingDays = getUpcomingDays(numDays, today);
    const skipSet = new Set(scheduleConfig.skipDates);

    // Determine whether today's email has already been dispatched (past 7 AM CET).
    // CET = UTC+1, CEST (summer) = UTC+2.
    const now = new Date();
    const month = now.getUTCMonth(); // 0-indexed
    const cetOffset = month >= 3 && month <= 9 ? 2 : 1;
    const cetHour = (now.getUTCHours() + cetOffset) % 24;
    const todayIsWorkday =
      !isWeekend(today) && !skipSet.has(format(today, "yyyy-MM-dd"));
    const todayEmailSent = todayIsWorkday && cetHour >= 7;

    // Use the live Excel value if we got it.
    // Fall back to stored value + date arithmetic only if indexSetDate was recorded.
    // If neither is available, positionKnown=false and we show order only (no "Sent" marking).
    let documentIndex: number;
    let positionKnown: boolean;

    if (liveDocumentIndex !== null) {
      documentIndex = liveDocumentIndex;
      positionKnown = true;
    } else if (scheduleConfig.indexSetDate) {
      documentIndex = computeEffectiveIndex(
        scheduleConfig.currentDocumentIndex ?? 0,
        scheduleConfig.indexSetDate,
        n,
        skipSet,
        todayEmailSent
      );
      positionKnown = true;
    } else {
      documentIndex = 0;
      positionKnown = false;
    }

    let fileIndex = documentIndex;

    return upcomingDays.map((date) => {
      const dateStr = format(date, "yyyy-MM-dd");
      const isSkipped = skipSet.has(dateStr);
      const isToday = isSameDay(date, today);

      if (isSkipped) {
        return {
          date,
          file: null,
          isSkipped: true,
          skipNote: scheduleConfig.notes[dateStr],
          isToday,
          isPast: false,
        };
      }

      if (isToday && todayEmailSent && positionKnown) {
        // Show the file that was already sent today (one step back in cycle).
        const sentFile = orderedFiles[((documentIndex - 1) % n + n) % n];
        return {
          date,
          file: sentFile,
          isSkipped: false,
          isToday,
          isPast: true, // marks this slot as "already sent"
        };
      }

      const file = orderedFiles[fileIndex % n];
      fileIndex = (fileIndex + 1) % n;

      return { date, file, isSkipped: false, isToday, isPast: false };
    });
  }, [orderedFiles, scheduleConfig, liveDocumentIndex]);

  const handlePreview = async (file: OneDriveFile) => {
    if (!graphClient) return;
    setPreviewingId(file.id);
    try {
      const content = await getFileContent(graphClient, file.id);
      const title = file.name
        .replace(/^\d+-/, "")
        .replace(/\.html$/i, "")
        .trim();
      onPreviewHtml(title || file.name, content);
    } catch (err) {
      console.error("[hse] Preview failed:", err);
    } finally {
      setPreviewingId(null);
    }
  };

  // Move file up/down in order
  const moveFile = (index: number, direction: "up" | "down") => {
    const newOrder = [...orderedFiles];
    const targetIndex = direction === "up" ? index - 1 : index + 1;
    if (targetIndex < 0 || targetIndex >= newOrder.length) return;
    
    [newOrder[index], newOrder[targetIndex]] = [newOrder[targetIndex], newOrder[index]];
    setOrderedFiles(newOrder);
    setHasOrderChanges(true);
  };

  // Drag and drop handlers
  const handleDragStart = (index: number) => {
    setDraggedIndex(index);
  };

  const handleDragOver = (e: React.DragEvent, index: number) => {
    e.preventDefault();
    if (draggedIndex === null || draggedIndex === index) return;
    
    const newOrder = [...orderedFiles];
    const draggedItem = newOrder[draggedIndex];
    newOrder.splice(draggedIndex, 1);
    newOrder.splice(index, 0, draggedItem);
    
    setOrderedFiles(newOrder);
    setDraggedIndex(index);
    setHasOrderChanges(true);
  };

  const handleDragEnd = () => {
    setDraggedIndex(null);
  };

  // Save new order to OneDrive by renaming files
  const saveOrder = async () => {
    if (!graphClient || !hasOrderChanges) return;
    setSavingOrder(true);
    
    try {
      // Rename files with new order prefixes
      for (let i = 0; i < orderedFiles.length; i++) {
        const file = orderedFiles[i];
        const newOrder = String(i + 1).padStart(2, "0");
        // Strip all leading numeric prefixes (handles double-numbered files like 01-02..Title)
      let baseName = file.name;
      while (/^\d+[-\.]/.test(baseName)) {
        baseName = baseName.replace(/^\d+[-\.]\.?/, "");
      }
        const newName = `${newOrder}-${baseName}`;
        
        if (newName !== file.name) {
          await renameFile(graphClient, file.id, newName);
        }
      }
      
      // Refresh data
      await fetchData();
    } catch (err) {
      console.error("[hse] Save order failed:", err);
      setError(locale === "pl" ? "Nie udało się zapisać kolejności" : "Failed to save order");
    } finally {
      setSavingOrder(false);
    }
  };

  // Find next newsletter
  const nextNewsletter = schedule.find(
    (s) => s.file && !s.isPast && !s.isSkipped
  );

  if (!isAuthenticated) {
    return (
      <div className="flex flex-col items-center justify-center gap-3 py-16 text-muted-foreground">
        <LogIn className="h-10 w-10" />
        <p className="text-sm">{t("catalog.signInRequired")}</p>
      </div>
    );
  }

  if (loading) {
    return (
      <div className="flex flex-col items-center justify-center gap-3 py-16 text-muted-foreground">
        <Loader2 className="h-8 w-8 animate-spin" />
        <p className="text-sm">{t("catalog.loading")}</p>
      </div>
    );
  }

  if (error) {
    return (
      <div className="flex flex-col items-center justify-center gap-3 py-16 text-destructive">
        <AlertCircle className="h-10 w-10" />
        <p className="text-sm">{error}</p>
        <Button variant="outline" size="sm" onClick={fetchData}>
          {t("catalog.refresh")}
        </Button>
      </div>
    );
  }

  return (
    <div className="flex flex-col gap-4">
      {/* Header */}
      <div className="flex items-center justify-between">
        <div>
          <h3 className="text-base font-semibold text-foreground">
            {locale === "pl" ? "Harmonogram wysyłki" : "Send Schedule"}
          </h3>
          <p className="text-xs text-muted-foreground">
            {locale === "pl"
              ? `${orderedFiles.length} biuletynów w kolejce`
              : `${orderedFiles.length} newsletters queued`}
            {liveDocumentIndex !== null && (
              <span className="ml-2 text-green-500">
                ✓ {locale === "pl" ? "synchronizacja auto" : "auto-synced"}
              </span>
            )}
          </p>
        </div>
        <div className="flex gap-2">
          {hasOrderChanges && (
            <Button
              variant="default"
              size="sm"
              onClick={saveOrder}
              disabled={savingOrder}
              className="gap-1.5"
            >
              {savingOrder ? (
                <Loader2 className="h-3.5 w-3.5 animate-spin" />
              ) : (
                <Save className="h-3.5 w-3.5" />
              )}
              {locale === "pl" ? "Zapisz kolejność" : "Save Order"}
            </Button>
          )}
          <Button
            variant="outline"
            size="sm"
            onClick={fetchData}
            className="gap-1.5"
          >
            <RefreshCw className="h-3.5 w-3.5" />
            {t("catalog.refresh")}
          </Button>
        </div>
      </div>


      {/* View toggle */}
      <Tabs value={activeView} onValueChange={(v) => setActiveView(v as "schedule" | "order")}>
        <TabsList className="grid w-full grid-cols-2">
          <TabsTrigger value="schedule" className="gap-1.5">
            <Calendar className="h-3.5 w-3.5" />
            {locale === "pl" ? "Kalendarz" : "Calendar"}
          </TabsTrigger>
          <TabsTrigger value="order" className="gap-1.5">
            <List className="h-3.5 w-3.5" />
            {locale === "pl" ? "Kolejność" : "Order"}
            {hasOrderChanges && (
              <Badge variant="destructive" className="ml-1 h-4 px-1 text-[10px]">
                *
              </Badge>
            )}
          </TabsTrigger>
        </TabsList>

        {/* Calendar view */}
        <TabsContent value="schedule" className="mt-4">
          {/* Next up highlight */}
          {nextNewsletter && nextNewsletter.file && (
            <div className="mb-4 rounded-lg border-2 border-primary/50 bg-primary/5 p-3">
              <div className="flex items-center gap-2 text-xs font-medium text-primary">
                <ChevronRight className="h-4 w-4" />
                {locale === "pl" ? "Następny do wysłania" : "Next to send"}
              </div>
              <div className="mt-2 flex items-center justify-between">
                <div>
                  <p className="font-semibold text-foreground">
                    {nextNewsletter.file.name
                      .replace(/^\d+[-\.]\.?/, "")
                      .replace(/\.html$/i, "")}
                  </p>
                  <p className="text-sm text-muted-foreground">
                    {format(nextNewsletter.date, "EEEE, d MMMM", {
                      locale: locale === "pl" ? plLocale : enUS,
                    })}
                    {nextNewsletter.isToday && (
                      <Badge variant="default" className="ml-2 text-[10px]">
                        {locale === "pl" ? "Dzisiaj" : "Today"}
                      </Badge>
                    )}
                  </p>
                </div>
                <Button
                  variant="outline"
                  size="sm"
                  onClick={() => handlePreview(nextNewsletter.file!)}
                  disabled={previewingId === nextNewsletter.file.id}
                >
                  {previewingId === nextNewsletter.file.id ? (
                    <Loader2 className="h-4 w-4 animate-spin" />
                  ) : (
                    <Eye className="h-4 w-4" />
                  )}
                </Button>
              </div>
            </div>
          )}

          {/* Schedule list */}
          <ScrollArea className="h-[350px]">
            <div className="flex flex-col gap-1.5">
              {schedule.map((item, idx) => {
                const dateStr = format(item.date, "yyyy-MM-dd");
                return (
                  <div
                    key={dateStr}
                    className={`flex items-center gap-3 rounded-md border px-3 py-2 transition-colors ${
                      item.isToday
                        ? "border-primary bg-primary/10"
                        : item.isSkipped
                          ? "border-destructive/30 bg-destructive/5"
                          : item.file
                            ? "border-border bg-card hover:bg-muted/50"
                            : "border-dashed border-border bg-transparent"
                    }`}
                  >
                    {/* Date */}
                    <div className="w-20 shrink-0">
                      <div className="flex items-center gap-1.5">
                        {item.isSkipped ? (
                          <CalendarOff className="h-3.5 w-3.5 text-destructive" />
                        ) : (
                          <Calendar className="h-3.5 w-3.5 text-muted-foreground" />
                        )}
                        <span
                          className={`text-xs font-medium ${
                            item.isToday
                              ? "text-primary"
                              : item.isSkipped
                                ? "text-destructive"
                                : "text-foreground"
                          }`}
                        >
                          {format(item.date, "EEE d/M", {
                            locale: locale === "pl" ? plLocale : enUS,
                          })}
                        </span>
                      </div>
                    </div>

                    {/* Content */}
                    <div className="min-w-0 flex-1">
                      {item.isSkipped ? (
                        <div className="flex items-center gap-2">
                          <span className="text-xs text-destructive">
                            {locale === "pl" ? "Pominięty" : "Skipped"}
                          </span>
                          {item.skipNote && (
                            <span className="truncate text-xs text-muted-foreground">
                              - {item.skipNote}
                            </span>
                          )}
                        </div>
                      ) : item.file ? (
                        <div className="flex items-center gap-2">
                          <Mail className="h-3.5 w-3.5 shrink-0 text-primary" />
                          <span className="truncate text-sm font-medium text-foreground">
                            {item.file.name
                              .replace(/^\d+[-\.]\.?/, "")
                              .replace(/\.html$/i, "")}
                          </span>
                          {item.isPast && item.isToday && (
                            <Badge variant="secondary" className="shrink-0 text-[10px]">
                              {locale === "pl" ? "Wysłany" : "Sent"}
                            </Badge>
                          )}
                        </div>
                      ) : (
                        <span className="text-xs italic text-muted-foreground">
                          {locale === "pl"
                            ? "Brak newslettera"
                            : "No newsletter scheduled"}
                        </span>
                      )}
                    </div>

                    {/* Actions */}
                    {item.file && (
                      <Button
                        variant="ghost"
                        size="icon"
                        className="h-7 w-7 shrink-0"
                        onClick={() => handlePreview(item.file!)}
                        disabled={previewingId === item.file.id}
                      >
                        {previewingId === item.file.id ? (
                          <Loader2 className="h-3.5 w-3.5 animate-spin" />
                        ) : (
                          <Eye className="h-3.5 w-3.5" />
                        )}
                      </Button>
                    )}
                  </div>
                );
              })}
            </div>
          </ScrollArea>

          {/* Legend */}
          <div className="mt-3 flex flex-wrap gap-4 border-t pt-3 text-[10px] text-muted-foreground">
            <div className="flex items-center gap-1.5">
              <div className="h-2.5 w-2.5 rounded-sm bg-primary" />
              {locale === "pl" ? "Dzisiaj" : "Today"}
            </div>
            <div className="flex items-center gap-1.5">
              <div className="h-2.5 w-2.5 rounded-sm bg-destructive/50" />
              {locale === "pl" ? "Pominięty" : "Skipped"}
            </div>
            <div className="flex items-center gap-1.5">
              <div className="h-2.5 w-2.5 rounded-sm border border-dashed border-muted-foreground" />
              {locale === "pl" ? "Brak" : "Empty"}
            </div>
          </div>
        </TabsContent>

        {/* Order view (drag and drop) */}
        <TabsContent value="order" className="mt-4">
          <p className="mb-3 text-xs text-muted-foreground">
            {locale === "pl"
              ? "Przeciągnij i upuść lub użyj strzałek aby zmienić kolejność. Kliknij 'Zapisz kolejność' aby zastosować zmiany."
              : "Drag and drop or use arrows to reorder. Click 'Save Order' to apply changes to OneDrive."}
          </p>

          <ScrollArea className="h-[380px]">
            <div className="flex flex-col gap-1">
              {orderedFiles.map((file, idx) => (
                <div
                  key={file.id}
                  draggable
                  onDragStart={() => handleDragStart(idx)}
                  onDragOver={(e) => handleDragOver(e, idx)}
                  onDragEnd={handleDragEnd}
                  className={`flex items-center gap-2 rounded-md border bg-card px-2 py-2 transition-all ${
                    draggedIndex === idx
                      ? "border-primary bg-primary/10 opacity-50"
                      : "border-border hover:bg-muted/50"
                  }`}
                >
                  {/* Drag handle */}
                  <GripVertical className="h-4 w-4 shrink-0 cursor-grab text-muted-foreground active:cursor-grabbing" />

                  {/* Order number */}
                  <Badge variant="outline" className="shrink-0 text-xs">
                    {String(idx + 1).padStart(2, "0")}
                  </Badge>

                  {/* File name */}
                  <span className="min-w-0 flex-1 truncate text-sm text-foreground">
                    {file.name.replace(/^\d+[-\.]\.?/, "").replace(/\.html$/i, "")}
                  </span>

                  {/* Move buttons */}
                  <div className="flex shrink-0 gap-1">
                    <Button
                      variant="ghost"
                      size="icon"
                      className="h-6 w-6"
                      onClick={() => moveFile(idx, "up")}
                      disabled={idx === 0}
                    >
                      <ChevronUp className="h-3.5 w-3.5" />
                    </Button>
                    <Button
                      variant="ghost"
                      size="icon"
                      className="h-6 w-6"
                      onClick={() => moveFile(idx, "down")}
                      disabled={idx === orderedFiles.length - 1}
                    >
                      <ChevronDown className="h-3.5 w-3.5" />
                    </Button>
                    <Button
                      variant="ghost"
                      size="icon"
                      className="h-6 w-6"
                      onClick={() => handlePreview(file)}
                      disabled={previewingId === file.id}
                    >
                      {previewingId === file.id ? (
                        <Loader2 className="h-3.5 w-3.5 animate-spin" />
                      ) : (
                        <Eye className="h-3.5 w-3.5" />
                      )}
                    </Button>
                  </div>
                </div>
              ))}
            </div>
          </ScrollArea>
        </TabsContent>
      </Tabs>
    </div>
  );
}
