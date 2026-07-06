"use client";

import { useState, useEffect, useCallback } from "react";
import { useTranslation } from "@/lib/i18n";
import type { ScheduleConfig } from "@/lib/types";
import type { Client } from "@microsoft/microsoft-graph-client";
import { getScheduleConfig, saveScheduleConfig } from "@/lib/onedrive";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Badge } from "@/components/ui/badge";
import {
  CalendarOff,
  Save,
  Loader2,
  Trash2,
  AlertCircle,
  CheckCircle,
  LogIn,
} from "lucide-react";
import { DayPicker } from "react-day-picker";
import { format, parseISO, isBefore, startOfDay } from "date-fns";
import { pl, enUS } from "date-fns/locale";
import "react-day-picker/style.css";

interface ScheduleManagerProps {
  graphClient: Client | null;
  isAuthenticated: boolean;
  userName?: string;
  onScheduleSaved?: () => void;
}

export function ScheduleManager({
  graphClient,
  isAuthenticated,
  userName,
  onScheduleSaved,
}: ScheduleManagerProps) {
  const { t, locale } = useTranslation();
  const [config, setConfig] = useState<ScheduleConfig>({
    skipDates: [],
    notes: {},
    lastUpdated: new Date().toISOString(),
    updatedBy: "",
  });
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const [status, setStatus] = useState<{
    type: "success" | "error";
    message: string;
  } | null>(null);
  const [noteInput, setNoteInput] = useState("");
  const [selectedDate, setSelectedDate] = useState<string | null>(null);

  const loadConfig = useCallback(async () => {
    if (!graphClient) return;
    setLoading(true);
    try {
      const cfg = await getScheduleConfig(graphClient);
      setConfig(cfg);
    } catch {
      setStatus({ type: "error", message: t("schedule.loadError") });
    } finally {
      setLoading(false);
    }
  }, [graphClient, t]);

  useEffect(() => {
    if (isAuthenticated && graphClient) {
      loadConfig();
    } else {
      setLoading(false);
    }
  }, [isAuthenticated, graphClient, loadConfig]);

  const handleDayClick = (day: Date) => {
    const dateStr = format(day, "yyyy-MM-dd");
    const today = startOfDay(new Date());
    if (isBefore(day, today)) return;

    setConfig((prev) => {
      const exists = prev.skipDates.includes(dateStr);
      if (exists) {
        const newNotes = { ...prev.notes };
        delete newNotes[dateStr];
        return {
          ...prev,
          skipDates: prev.skipDates.filter((d) => d !== dateStr),
          notes: newNotes,
        };
      } else {
        return {
          ...prev,
          skipDates: [...prev.skipDates, dateStr].sort(),
        };
      }
    });
    setSelectedDate(dateStr);
    setNoteInput("");
  };

  const handleAddNote = () => {
    if (!selectedDate || !noteInput.trim()) return;
    setConfig((prev) => ({
      ...prev,
      notes: { ...prev.notes, [selectedDate]: noteInput.trim() },
    }));
    setNoteInput("");
  };

  const handleRemoveDate = (dateStr: string) => {
    setConfig((prev) => {
      const newNotes = { ...prev.notes };
      delete newNotes[dateStr];
      return {
        ...prev,
        skipDates: prev.skipDates.filter((d) => d !== dateStr),
        notes: newNotes,
      };
    });
    if (selectedDate === dateStr) setSelectedDate(null);
  };

  const handleSave = async () => {
    if (!graphClient) return;
    setSaving(true);
    setStatus(null);
    try {
      const updatedConfig: ScheduleConfig = {
        ...config,
        lastUpdated: new Date().toISOString(),
        updatedBy: userName || "unknown",
      };
      await saveScheduleConfig(graphClient, updatedConfig);
      setConfig(updatedConfig);
      setStatus({ type: "success", message: t("schedule.saved") });
      onScheduleSaved?.();
    } catch {
      setStatus({ type: "error", message: t("schedule.error") });
    } finally {
      setSaving(false);
      setTimeout(() => setStatus(null), 4000);
    }
  };

  if (!isAuthenticated) {
    return (
      <div className="flex flex-col items-center justify-center gap-3 py-16 text-muted-foreground">
        <LogIn className="h-10 w-10" />
        <p className="text-sm">{t("schedule.signInRequired")}</p>
      </div>
    );
  }

  if (loading) {
    return (
      <div className="flex flex-col items-center justify-center gap-3 py-16 text-muted-foreground">
        <Loader2 className="h-8 w-8 animate-spin" />
        <p className="text-sm">{t("schedule.loading")}</p>
      </div>
    );
  }

  const skipDateObjects = config.skipDates.map((d) => parseISO(d));
  const sortedSkipDates = [...config.skipDates].sort();

  return (
    <div className="flex flex-col gap-6">
      <div>
        <h3 className="text-lg font-semibold text-foreground">
          {t("schedule.title")}
        </h3>
        <p className="mt-1 text-sm text-muted-foreground">
          {t("schedule.subtitle")}
        </p>
      </div>

      <div className="flex flex-col gap-6 xl:flex-row">
        {/* Calendar */}
        <div className="shrink-0 overflow-x-auto rounded-lg border border-border bg-card p-4">
          <DayPicker
            mode="multiple"
            selected={skipDateObjects}
            onDayClick={handleDayClick}
            disabled={{ before: new Date() }}
            locale={locale === "pl" ? pl : enUS}
            modifiersClassNames={{
              selected: "bg-destructive text-destructive-foreground",
            }}
            showOutsideDays
            fixedWeeks
          />
        </div>

        {/* Skip list */}
        <div className="flex flex-1 flex-col gap-3">
          <h4 className="flex items-center gap-2 text-sm font-medium text-foreground">
            <CalendarOff className="h-4 w-4" />
            {t("schedule.skipDays")}
            <Badge variant="secondary">{config.skipDates.length}</Badge>
          </h4>

          {sortedSkipDates.length === 0 ? (
            <p className="text-sm text-muted-foreground">
              {t("schedule.noSkips")}
            </p>
          ) : (
            <div className="flex max-h-64 flex-col gap-2 overflow-y-auto">
              {sortedSkipDates.map((dateStr) => (
                <div
                  key={dateStr}
                  className="flex items-center gap-2 rounded-md border border-border bg-muted/50 px-3 py-2"
                >
                  <CalendarOff className="h-4 w-4 shrink-0 text-destructive" />
                  <div className="flex-1">
                    <span className="text-sm font-medium text-foreground">
                      {format(parseISO(dateStr), "EEEE, d MMMM yyyy", {
                        locale: locale === "pl" ? pl : enUS,
                      })}
                    </span>
                    {config.notes[dateStr] && (
                      <span className="ml-2 text-xs text-muted-foreground">
                        -- {config.notes[dateStr]}
                      </span>
                    )}
                  </div>
                  <Button
                    variant="ghost"
                    size="icon"
                    className="h-7 w-7 text-muted-foreground hover:text-destructive"
                    onClick={() => handleRemoveDate(dateStr)}
                    aria-label={t("schedule.remove")}
                  >
                    <Trash2 className="h-3.5 w-3.5" />
                  </Button>
                </div>
              ))}
            </div>
          )}

          {/* Add note for selected date */}
          {selectedDate && config.skipDates.includes(selectedDate) && (
            <div className="flex gap-2">
              <Input
                value={noteInput}
                onChange={(e) => setNoteInput(e.target.value)}
                placeholder={t("schedule.addNote")}
                className="text-sm"
                onKeyDown={(e) => e.key === "Enter" && handleAddNote()}
              />
              <Button size="sm" variant="outline" onClick={handleAddNote}>
                +
              </Button>
            </div>
          )}

          {/* Save & Status */}
          <div className="mt-2 flex items-center gap-3">
            <Button
              onClick={handleSave}
              disabled={saving || !graphClient}
              className="gap-2"
            >
              {saving ? (
                <Loader2 className="h-4 w-4 animate-spin" />
              ) : (
                <Save className="h-4 w-4" />
              )}
              {saving ? t("schedule.saving") : t("schedule.save")}
            </Button>

            {status && (
              <span
                className={`flex items-center gap-1.5 text-sm ${
                  status.type === "success"
                    ? "text-green-600 dark:text-green-400"
                    : "text-destructive"
                }`}
              >
                {status.type === "success" ? (
                  <CheckCircle className="h-4 w-4" />
                ) : (
                  <AlertCircle className="h-4 w-4" />
                )}
                {status.message}
              </span>
            )}
          </div>
        </div>
      </div>
    </div>
  );
}
