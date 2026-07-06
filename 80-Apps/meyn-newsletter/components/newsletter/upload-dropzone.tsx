"use client";

import { useCallback, useState } from "react";
import { Upload, FileText, AlertCircle } from "lucide-react";
import { convertDocxToHtml, extractTitleFromFileName } from "@/lib/docx-converter";
import { useTranslation } from "@/lib/i18n";
import type { NewsletterMessage } from "@/lib/types";
import { cn } from "@/lib/utils";

interface UploadDropzoneProps {
  onFilesConverted: (messages: NewsletterMessage[]) => void;
  existingCount: number;
  nextAutoNumber?: number;
  onAutoSync?: (messages: NewsletterMessage[]) => Promise<void>;
}

export default function UploadDropzone({
  onFilesConverted,
  existingCount,
  nextAutoNumber,
  onAutoSync,
}: UploadDropzoneProps) {
  const { t } = useTranslation();
  const [isDragOver, setIsDragOver] = useState(false);
  const [isConverting, setIsConverting] = useState(false);
  const [convertProgress, setConvertProgress] = useState({ current: 0, total: 0 });
  const [conversionErrors, setConversionErrors] = useState<string[]>([]);
  const [isSyncing, setIsSyncing] = useState(false);

  const processFiles = useCallback(
    async (files: FileList | File[]) => {
      const docxFiles = Array.from(files).filter(
        (f) =>
          f.name.endsWith(".docx") ||
          f.name.endsWith(".doc") ||
          f.type ===
            "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
      );

      if (docxFiles.length === 0) {
        setConversionErrors(["Please upload .docx files only."]);
        return;
      }

      setIsConverting(true);
      setConvertProgress({ current: 0, total: docxFiles.length });
      setConversionErrors([]);
      const newMessages: NewsletterMessage[] = [];
      const errors: string[] = [];

      for (let i = 0; i < docxFiles.length; i++) {
        const file = docxFiles[i];
        setConvertProgress({ current: i + 1, total: docxFiles.length });
        try {
          const result = await convertDocxToHtml(file);
          const title = extractTitleFromFileName(file.name);

          newMessages.push({
            id: crypto.randomUUID(),
            title,
            htmlContent: result.html,
            order: nextAutoNumber ? nextAutoNumber + i : existingCount + i + 1,
            fileName: file.name,
            lastModified: new Date(),
            status: "draft",
          });

          if (result.warnings.length > 0) {
            errors.push(
              `${file.name}: ${result.warnings.length} warning(s) during conversion`
            );
          }
        } catch (err) {
          errors.push(`${file.name}: Conversion failed - ${String(err)}`);
        }
      }

      if (errors.length > 0) setConversionErrors(errors);
      if (newMessages.length > 0) {
        onFilesConverted(newMessages);
        // Auto-sync: upload directly to OneDrive with auto-number
        if (onAutoSync) {
          setIsSyncing(true);
          try {
            await onAutoSync(newMessages);
          } catch {
            // Sync errors are handled in page.tsx
          } finally {
            setIsSyncing(false);
          }
        }
      }
      setIsConverting(false);
    },
    [existingCount, nextAutoNumber, onFilesConverted, onAutoSync]
  );

  const handleDrop = useCallback(
    (e: React.DragEvent) => {
      e.preventDefault();
      setIsDragOver(false);
      if (e.dataTransfer.files.length > 0) {
        processFiles(e.dataTransfer.files);
      }
    },
    [processFiles]
  );

  const handleDragOver = useCallback((e: React.DragEvent) => {
    e.preventDefault();
    setIsDragOver(true);
  }, []);

  const handleDragLeave = useCallback((e: React.DragEvent) => {
    e.preventDefault();
    setIsDragOver(false);
  }, []);

  const handleFileInput = useCallback(
    (e: React.ChangeEvent<HTMLInputElement>) => {
      if (e.target.files && e.target.files.length > 0) {
        processFiles(e.target.files);
        e.target.value = "";
      }
    },
    [processFiles]
  );

  return (
    <div className="flex flex-col gap-3">
      <div
        onDrop={handleDrop}
        onDragOver={handleDragOver}
        onDragLeave={handleDragLeave}
        className={cn(
          "relative flex flex-col items-center justify-center gap-3 rounded-lg border-2 border-dashed p-8 transition-all",
          isDragOver
            ? "border-primary bg-primary/5"
            : "border-border bg-muted/30 hover:border-primary/50 hover:bg-muted/50",
          (isConverting || isSyncing) && "pointer-events-none opacity-60"
        )}
      >
        {isConverting ? (
          <>
            <div className="h-8 w-8 animate-spin rounded-full border-4 border-primary border-t-transparent" />
            <p className="text-sm font-medium text-foreground">
              {t("upload.converting")} {convertProgress.current} {t("upload.of")}{" "}
              {convertProgress.total} {t("upload.files")}
            </p>
          </>
        ) : isSyncing ? (
          <>
            <div className="h-8 w-8 animate-spin rounded-full border-4 border-green-500 border-t-transparent" />
            <p className="text-sm font-medium text-foreground">
              Syncing to OneDrive...
            </p>
          </>
        ) : (
          <>
            <div className="rounded-full bg-primary/10 p-3">
              <Upload className="h-6 w-6 text-primary" />
            </div>
            <div className="text-center">
              <p className="text-sm font-medium text-foreground">
                {t("upload.title")}
              </p>
              <p className="mt-1 text-xs text-muted-foreground">
                {t("upload.subtitle")}
              </p>
            </div>
            <label className="cursor-pointer">
              <span className="inline-flex items-center gap-1.5 rounded-md bg-secondary px-3 py-1.5 text-xs font-medium text-secondary-foreground transition-colors hover:bg-secondary/80">
                <FileText className="h-3.5 w-3.5" />
                {t("upload.browse")}
              </span>
              <input
                type="file"
                accept=".docx,.doc"
                multiple
                onChange={handleFileInput}
                className="sr-only"
              />
            </label>
          </>
        )}
      </div>

      {conversionErrors.length > 0 && (
        <div className="flex flex-col gap-1 rounded-md bg-destructive/10 p-3">
          <p className="mb-1 text-xs font-medium text-destructive">
            {t("upload.error")}
          </p>
          {conversionErrors.map((error, i) => (
            <div key={i} className="flex items-start gap-2 text-xs">
              <AlertCircle className="mt-0.5 h-3.5 w-3.5 shrink-0 text-destructive" />
              <span className="text-destructive">{error}</span>
            </div>
          ))}
        </div>
      )}
    </div>
  );
}
