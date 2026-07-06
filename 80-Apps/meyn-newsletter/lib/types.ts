export interface NewsletterMessage {
  id: string;
  title: string;
  htmlContent: string;
  order: number;
  fileName: string;
  lastModified: Date;
  status: "draft" | "queued" | "synced";
  oneDriveItemId?: string;
}

export interface OneDriveFile {
  id: string;
  name: string;
  lastModifiedDateTime: string;
  size: number;
  webUrl: string;
}

export interface SyncResult {
  uploaded: number;
  deleted: number;
  errors: string[];
}

export interface UserInfo {
  displayName: string;
  mail: string;
  id: string;
}

export interface ScheduleConfig {
  skipDates: string[]; // ISO date strings yyyy-MM-dd
  notes: Record<string, string>; // date -> note
  lastUpdated: string;
  updatedBy: string;
  currentDocumentIndex?: number; // mirrors Power Automate's Excel counter
  indexSetDate?: string;         // ISO date when currentDocumentIndex was last calibrated
}
