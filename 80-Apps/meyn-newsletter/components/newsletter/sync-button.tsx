"use client";

import { useState } from "react";
import { CloudUpload, Check, AlertTriangle, Loader2 } from "lucide-react";
import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
  DialogTrigger,
} from "@/components/ui/dialog";
import { Progress } from "@/components/ui/progress";
import { useTranslation } from "@/lib/i18n";
import type { NewsletterMessage, SyncResult } from "@/lib/types";

interface SyncButtonProps {
  messages: NewsletterMessage[];
  onSync: (messages: NewsletterMessage[]) => Promise<SyncResult>;
  onSyncComplete: (result: SyncResult) => void;
  disabled?: boolean;
}

export default function SyncButton({
  messages,
  onSync,
  onSyncComplete,
  disabled,
}: SyncButtonProps) {
  const { t } = useTranslation();
  const [isSyncing, setIsSyncing] = useState(false);
  const [syncResult, setSyncResult] = useState<SyncResult | null>(null);
  const [progress, setProgress] = useState(0);
  const [open, setOpen] = useState(false);

  const handleSync = async () => {
    setIsSyncing(true);
    setProgress(10);
    setSyncResult(null);

    try {
      const progressInterval = setInterval(() => {
        setProgress((prev) => Math.min(prev + 15, 85));
      }, 500);

      const result = await onSync(messages);

      clearInterval(progressInterval);
      setProgress(100);
      setSyncResult(result);
      onSyncComplete(result);
    } catch (err) {
      setSyncResult({
        uploaded: 0,
        deleted: 0,
        errors: [String(err)],
      });
    } finally {
      setIsSyncing(false);
    }
  };

  const handleClose = () => {
    setOpen(false);
    setSyncResult(null);
    setProgress(0);
  };

  const hasErrors = syncResult && syncResult.errors.length > 0;
  const isSuccess = syncResult && syncResult.errors.length === 0;

  return (
    <Dialog open={open} onOpenChange={setOpen}>
      <DialogTrigger asChild>
        <Button
          size="sm"
          disabled={disabled || messages.length === 0}
          className="gap-1.5"
        >
          <CloudUpload className="h-4 w-4" />
          {t("sync.button")}
        </Button>
      </DialogTrigger>
      <DialogContent className="sm:max-w-md">
        <DialogHeader>
          <DialogTitle>
            {syncResult ? t("sync.success") : t("sync.confirm.title")}
          </DialogTitle>
          <DialogDescription>
            {syncResult
              ? ""
              : `${messages.length} ${t("sync.confirm.messages")}. ${t("sync.confirm.description")}`}
          </DialogDescription>
        </DialogHeader>

        <div className="flex flex-col gap-4 py-4">
          {isSyncing && (
            <div className="flex flex-col gap-2">
              <div className="flex items-center gap-2 text-sm text-muted-foreground">
                <Loader2 className="h-4 w-4 animate-spin" />
                {t("sync.syncing")}
              </div>
              <Progress value={progress} className="h-2" />
            </div>
          )}

          {isSuccess && (
            <div className="flex items-start gap-3 rounded-lg bg-green-500/10 p-3 dark:bg-green-500/20">
              <Check className="mt-0.5 h-5 w-5 text-green-600 dark:text-green-400" />
              <div>
                <p className="text-sm font-medium text-foreground">
                  {t("sync.success")}
                </p>
                <p className="mt-0.5 text-xs text-muted-foreground">
                  {syncResult.uploaded} uploaded, {syncResult.deleted} removed.
                </p>
              </div>
            </div>
          )}

          {hasErrors && (
            <div className="flex flex-col gap-2">
              {syncResult.errors.map((error, i) => (
                <div
                  key={i}
                  className="flex items-start gap-2 rounded-lg bg-destructive/10 p-3"
                >
                  <AlertTriangle className="mt-0.5 h-4 w-4 shrink-0 text-destructive" />
                  <span className="text-xs text-destructive">{error}</span>
                </div>
              ))}
            </div>
          )}

          {!isSyncing && !syncResult && (
            <div className="rounded-lg bg-muted/50 p-3">
              <p className="text-xs text-muted-foreground leading-relaxed">
                {t("sync.confirm.warning")}
              </p>
            </div>
          )}
        </div>

        <DialogFooter>
          {syncResult ? (
            <Button onClick={handleClose} size="sm">
              OK
            </Button>
          ) : (
            <>
              <Button
                variant="ghost"
                size="sm"
                onClick={() => setOpen(false)}
                disabled={isSyncing}
              >
                {t("sync.confirm.cancel")}
              </Button>
              <Button
                onClick={handleSync}
                disabled={isSyncing}
                size="sm"
                className="gap-1.5"
              >
                {isSyncing ? (
                  <Loader2 className="h-4 w-4 animate-spin" />
                ) : (
                  <CloudUpload className="h-4 w-4" />
                )}
                {isSyncing ? t("sync.syncing") : t("sync.confirm.confirm")}
              </Button>
            </>
          )}
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
