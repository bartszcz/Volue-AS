"use client";

import { useState, useEffect, useCallback } from "react";
import { useTranslation } from "@/lib/i18n";
import type { OneDriveFile, NewsletterMessage } from "@/lib/types";
import type { Client } from "@microsoft/microsoft-graph-client";
import { listOneDriveFiles, getFileContent } from "@/lib/onedrive";
import { Button } from "@/components/ui/button";
import { Badge } from "@/components/ui/badge";
import {
  RefreshCw,
  Download,
  Eye,
  Loader2,
  FolderOpen,
  LogIn,
  AlertCircle,
  FileText,
} from "lucide-react";
import { format } from "date-fns";
import { pl as plLocale, enUS } from "date-fns/locale";

interface OneDriveCatalogProps {
  graphClient: Client | null;
  isAuthenticated: boolean;
  onImportMessage: (message: NewsletterMessage) => void;
  onPreviewHtml: (title: string, html: string) => void;
}

function formatFileSize(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
}

export function OneDriveCatalog({
  graphClient,
  isAuthenticated,
  onImportMessage,
  onPreviewHtml,
}: OneDriveCatalogProps) {
  const { t, locale } = useTranslation();
  const [files, setFiles] = useState<OneDriveFile[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [importingId, setImportingId] = useState<string | null>(null);
  const [previewingId, setPreviewingId] = useState<string | null>(null);

  const fetchFiles = useCallback(async () => {
    if (!graphClient) return;
    setLoading(true);
    setError(null);
    try {
      const result = await listOneDriveFiles(graphClient);
      setFiles(result);
    } catch {
      setError(t("catalog.error"));
    } finally {
      setLoading(false);
    }
  }, [graphClient, t]);

  useEffect(() => {
    if (isAuthenticated && graphClient) {
      fetchFiles();
    } else {
      setLoading(false);
    }
  }, [isAuthenticated, graphClient, fetchFiles]);

  const handleImport = async (file: OneDriveFile) => {
    if (!graphClient) return;
    setImportingId(file.id);
    try {
      const content = await getFileContent(graphClient, file.id);
      const orderMatch = file.name.match(/^(\d+)-/);
      const order = orderMatch ? parseInt(orderMatch[1], 10) : 1;
      const title = file.name
        .replace(/^\d+-/, "")
        .replace(/\.html$/i, "")
        .trim();

      const message: NewsletterMessage = {
        id: `imported-${file.id}-${Date.now()}`,
        title: title || file.name,
        htmlContent: content,
        order,
        fileName: file.name,
        lastModified: new Date(file.lastModifiedDateTime),
        status: "draft",
        oneDriveItemId: file.id,
      };
      onImportMessage(message);
    } catch (err) {
      console.error("Import failed:", err);
    } finally {
      setImportingId(null);
    }
  };

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
      console.error("Preview failed:", err);
    } finally {
      setPreviewingId(null);
    }
  };

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
        <Button variant="outline" size="sm" onClick={fetchFiles}>
          {t("catalog.refresh")}
        </Button>
      </div>
    );
  }

  return (
    <div className="flex flex-col gap-4">
      <div className="flex items-center justify-between">
        <div>
          <h3 className="text-lg font-semibold text-foreground">
            {t("catalog.title")}
          </h3>
        </div>
        <Button
          variant="outline"
          size="sm"
          onClick={fetchFiles}
          className="gap-1.5"
        >
          <RefreshCw className="h-3.5 w-3.5" />
          {t("catalog.refresh")}
        </Button>
      </div>

      {files.length === 0 ? (
        <div className="flex flex-col items-center justify-center gap-3 py-12 text-muted-foreground">
          <FolderOpen className="h-10 w-10" />
          <p className="text-sm font-medium">{t("catalog.empty")}</p>
          <p className="text-xs">{t("catalog.emptyHint")}</p>
        </div>
      ) : (
        <div className="overflow-hidden rounded-lg border border-border">
          <table className="w-full text-sm">
            <thead>
              <tr className="border-b border-border bg-muted/50">
                <th className="px-4 py-3 text-left font-medium text-muted-foreground">
                  {t("catalog.name")}
                </th>
                <th className="hidden px-4 py-3 text-left font-medium text-muted-foreground md:table-cell">
                  {t("catalog.modified")}
                </th>
                <th className="hidden px-4 py-3 text-left font-medium text-muted-foreground sm:table-cell">
                  {t("catalog.size")}
                </th>
                <th className="px-4 py-3 text-right font-medium text-muted-foreground">
                  {t("catalog.actions")}
                </th>
              </tr>
            </thead>
            <tbody>
              {files.map((file) => (
                <tr
                  key={file.id}
                  className="border-b border-border last:border-0 hover:bg-muted/30"
                >
                  <td className="px-4 py-3">
                    <div className="flex items-center gap-2">
                      <FileText className="h-4 w-4 shrink-0 text-primary" />
                      <span className="font-medium text-foreground">
                        {file.name}
                      </span>
                    </div>
                  </td>
                  <td className="hidden px-4 py-3 text-muted-foreground md:table-cell">
                    {format(
                      new Date(file.lastModifiedDateTime),
                      "d MMM yyyy, HH:mm",
                      { locale: locale === "pl" ? plLocale : enUS }
                    )}
                  </td>
                  <td className="hidden px-4 py-3 text-muted-foreground sm:table-cell">
                    <Badge variant="secondary">{formatFileSize(file.size)}</Badge>
                  </td>
                  <td className="px-4 py-3">
                    <div className="flex items-center justify-end gap-1">
                      <Button
                        variant="ghost"
                        size="sm"
                        className="gap-1 text-xs"
                        onClick={() => handlePreview(file)}
                        disabled={previewingId === file.id}
                      >
                        {previewingId === file.id ? (
                          <Loader2 className="h-3.5 w-3.5 animate-spin" />
                        ) : (
                          <Eye className="h-3.5 w-3.5" />
                        )}
                        {t("catalog.preview")}
                      </Button>
                      <Button
                        variant="outline"
                        size="sm"
                        className="gap-1 text-xs"
                        onClick={() => handleImport(file)}
                        disabled={importingId === file.id}
                      >
                        {importingId === file.id ? (
                          <Loader2 className="h-3.5 w-3.5 animate-spin" />
                        ) : (
                          <Download className="h-3.5 w-3.5" />
                        )}
                        {t("catalog.import")}
                      </Button>
                    </div>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </div>
  );
}
