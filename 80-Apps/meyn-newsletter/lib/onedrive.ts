import type { Client } from "@microsoft/microsoft-graph-client";
import type {
  OneDriveFile,
  NewsletterMessage,
  SyncResult,
  ScheduleConfig,
} from "./types";

const SCHEDULE_FILE_NAME = "schedule-config.json";

const DEFAULT_FOLDER_PATH =
  process.env.NEXT_PUBLIC_ONEDRIVE_FOLDER_PATH || "/Safety Bulletin";

// OneDrive configuration -- use drive ID if available (more reliable)
const ONEDRIVE_DRIVE_ID = process.env.NEXT_PUBLIC_ONEDRIVE_DRIVE_ID;
const ONEDRIVE_FOLDER_ITEM_ID = process.env.NEXT_PUBLIC_ONEDRIVE_ITEM_ID;

// Fallback to user-based path if drive ID not set
const ONEDRIVE_USER =
  process.env.NEXT_PUBLIC_ONEDRIVE_USER_EMAIL || "powerbipl@meyn.nl";

// Graph API drive prefix -- prefer drive ID, fallback to user's drive
const DRIVE_BASE = ONEDRIVE_DRIVE_ID
  ? `/drives/${ONEDRIVE_DRIVE_ID}`
  : `/users/${ONEDRIVE_USER}/drive`;

function sanitizeFileName(name: string): string {
  return name.replace(/[<>:"/\\|?*]/g, "-").trim();
}

function buildNumberedFileName(order: number, title: string): string {
  const paddedOrder = String(order).padStart(2, "0");
  const sanitized = sanitizeFileName(title);
  return `${paddedOrder}-${sanitized}.html`;
}

export async function getNextNewsletterNumber(
  graphClient: Client,
  folderPath: string = DEFAULT_FOLDER_PATH
): Promise<number> {
  try {
    const files = await listOneDriveFiles(graphClient, folderPath);
    if (files.length === 0) return 1;
    
    // Extract numeric prefixes from file names (e.g., "01-filename.html" -> 1)
    const numbers = files
      .map((file) => {
        const match = file.name.match(/^(\d+)[-\.]/);
        return match ? parseInt(match[1], 10) : 0;
      })
      .filter((num) => num > 0);
    
    // Return max number + 1
    return Math.max(...numbers) + 1;
  } catch {
    // If we can't get files, assume we're starting fresh
    return 1;
  }
}

export async function listOneDriveFiles(
  graphClient: Client,
  folderPath: string = DEFAULT_FOLDER_PATH
): Promise<OneDriveFile[]> {
  try {
    // Use folder item ID if available (more reliable), otherwise use path
    let apiPath: string;
    if (ONEDRIVE_FOLDER_ITEM_ID) {
      apiPath = `${DRIVE_BASE}/items/${ONEDRIVE_FOLDER_ITEM_ID}/children`;
    } else {
      const encodedPath = encodeURIComponent(folderPath).replace(/%2F/g, "/");
      apiPath = `${DRIVE_BASE}/root:${encodedPath}:/children`;
    }

    const response = await graphClient
      .api(apiPath)
      .select("id,name,lastModifiedDateTime,size,webUrl")
      .get();

    return (response.value || []).filter((file: OneDriveFile) =>
      file.name && file.name.toLowerCase().endsWith(".html")
    );
  } catch (error: unknown) {
    if (error && typeof error === "object" && "statusCode" in error && (error as { statusCode: number }).statusCode === 404) {
      return [];
    }
    throw error;
  }
}

export async function getFileContent(
  graphClient: Client,
  itemId: string
): Promise<string> {
  // Use the @microsoft/microsoft-graph-client's responseType properly
  // The Graph SDK returns different types based on the responseType
  try {
    // First try to get as blob using fetch directly with the download URL
    const driveItem = await graphClient
      .api(`${DRIVE_BASE}/items/${itemId}`)
      .select("@microsoft.graph.downloadUrl")
      .get();
    
    const downloadUrl = driveItem["@microsoft.graph.downloadUrl"];
    if (downloadUrl) {
      const response = await fetch(downloadUrl);
      return await response.text();
    }
    
    // Fallback: get content directly
    const content = await graphClient
      .api(`${DRIVE_BASE}/items/${itemId}/content`)
      .get();
    
    if (typeof content === "string") {
      return content;
    }
    if (content instanceof Blob) {
      return await content.text();
    }
    if (content instanceof ArrayBuffer) {
      return new TextDecoder().decode(content);
    }
    return await new Response(content).text();
  } catch (err) {
    throw err;
  }
}

export async function uploadFile(
  graphClient: Client,
  folderPath: string | undefined = DEFAULT_FOLDER_PATH,
  fileName: string,
  content: string
): Promise<OneDriveFile> {
  if (!folderPath) folderPath = DEFAULT_FOLDER_PATH;
  // Use folder item ID if available (more reliable), otherwise use path
  let apiPath: string;
  if (ONEDRIVE_FOLDER_ITEM_ID) {
    apiPath = `${DRIVE_BASE}/items/${ONEDRIVE_FOLDER_ITEM_ID}:/${fileName}:/content`;
  } else {
    const encodedPath = encodeURIComponent(
      `${folderPath}/${fileName}`
    ).replace(/%2F/g, "/");
    apiPath = `${DRIVE_BASE}/root:${encodedPath}:/content`;
  }

  const response = await graphClient.api(apiPath).put(content);

  return response;
}

export async function deleteFile(
  graphClient: Client,
  itemId: string
): Promise<void> {
  await graphClient.api(`${DRIVE_BASE}/items/${itemId}`).delete();
}

export async function renameFile(
  graphClient: Client,
  itemId: string,
  newName: string
): Promise<OneDriveFile> {
  const response = await graphClient
    .api(`${DRIVE_BASE}/items/${itemId}`)
    .patch({ name: newName });
  return response;
}

export async function syncToOneDrive(
  graphClient: Client,
  messages: NewsletterMessage[],
  folderPath: string = DEFAULT_FOLDER_PATH
): Promise<SyncResult> {
  const result: SyncResult = { uploaded: 0, deleted: 0, errors: [] };

  try {
    // 1. Get current files in OneDrive
    const existingFiles = await listOneDriveFiles(graphClient, folderPath);

    // 2. Delete all existing HTML files (we rebuild the full set)
    for (const file of existingFiles) {
      try {
        await deleteFile(graphClient, file.id);
        result.deleted++;
      } catch (err) {
        result.errors.push(`Failed to delete ${file.name}: ${String(err)}`);
      }
    }

    // 3. Upload all messages with correct numbering
    const sortedMessages = [...messages].sort((a, b) => a.order - b.order);
    for (const message of sortedMessages) {
      const fileName = buildNumberedFileName(message.order, message.title);
      try {
        await uploadFile(graphClient, folderPath, fileName, message.htmlContent);
        result.uploaded++;
      } catch (err) {
        result.errors.push(`Failed to upload ${fileName}: ${String(err)}`);
      }
    }
  } catch (err) {
    result.errors.push(`Sync failed: ${String(err)}`);
  }

  return result;
}

export async function fetchOneDriveMessages(
  graphClient: Client,
  folderPath: string = DEFAULT_FOLDER_PATH
): Promise<NewsletterMessage[]> {
  const files = await listOneDriveFiles(graphClient, folderPath);
  const messages: NewsletterMessage[] = [];

  for (const file of files) {
    try {
      const content = await getFileContent(graphClient, file.id);
      const orderMatch = file.name.match(/^(\d+)-/);
      const order = orderMatch ? parseInt(orderMatch[1], 10) : messages.length + 1;
      const title = file.name
        .replace(/^\d+-/, "")
        .replace(/\.html$/i, "")
        .trim();

      messages.push({
        id: file.id,
        title: title || file.name,
        htmlContent: content,
        order,
        fileName: file.name,
        lastModified: new Date(file.lastModifiedDateTime),
        status: "synced",
        oneDriveItemId: file.id,
      });
    } catch (err) {
      console.error(`Failed to fetch content for ${file.name}:`, err);
    }
  }

  return messages.sort((a, b) => a.order - b.order);
}

// ── Schedule config (skip days) ──────────────────────

export async function getScheduleConfig(
  graphClient: Client,
  folderPath: string = DEFAULT_FOLDER_PATH
): Promise<ScheduleConfig> {
  const defaultConfig: ScheduleConfig = {
    skipDates: [],
    notes: {},
    lastUpdated: new Date().toISOString(),
    updatedBy: "",
  };

  try {
    // List folder contents and find the schedule config file
    let listPath: string;
    if (ONEDRIVE_FOLDER_ITEM_ID) {
      listPath = `${DRIVE_BASE}/items/${ONEDRIVE_FOLDER_ITEM_ID}/children`;
    } else {
      const encodedPath = encodeURIComponent(folderPath).replace(/%2F/g, "/");
      listPath = `${DRIVE_BASE}/root:${encodedPath}:/children`;
    }

    const listResponse = await graphClient
      .api(listPath)
      .select("id,name")
      .get();

    // Find the schedule config file in the list (case-insensitive)
    const allFiles = listResponse.value || [];
    const configFile = allFiles.find(
      (f: { name: string }) => f.name.toLowerCase() === SCHEDULE_FILE_NAME.toLowerCase()
    );
    
    if (!configFile) {
      return defaultConfig;
    }

    // Found the file, now get its content by item ID - use download URL method
    const driveItem = await graphClient
      .api(`${DRIVE_BASE}/items/${configFile.id}`)
      .select("@microsoft.graph.downloadUrl")
      .get();
    
    const downloadUrl = driveItem["@microsoft.graph.downloadUrl"];
    let text: string;
    if (downloadUrl) {
      const fetchResponse = await fetch(downloadUrl);
      text = await fetchResponse.text();
    } else {
      const contentPath = `${DRIVE_BASE}/items/${configFile.id}/content`;
      const response = await graphClient.api(contentPath).get();
      if (typeof response === "string") {
        text = response;
      } else if (response instanceof Blob) {
        text = await response.text();
      } else if (response instanceof ArrayBuffer) {
        text = new TextDecoder().decode(response);
      } else {
        text = await new Response(response).text();
      }
    }
    
    return JSON.parse(text) as ScheduleConfig;
  } catch {
    return defaultConfig;
  }
}

export async function saveScheduleConfig(
  graphClient: Client,
  config: ScheduleConfig,
  folderPath: string = DEFAULT_FOLDER_PATH
): Promise<void> {
  // Use folder item ID if available
  let apiPath: string;
  if (ONEDRIVE_FOLDER_ITEM_ID) {
    apiPath = `${DRIVE_BASE}/items/${ONEDRIVE_FOLDER_ITEM_ID}:/${SCHEDULE_FILE_NAME}:/content`;
  } else {
    const encodedPath = encodeURIComponent(
      `${folderPath}/${SCHEDULE_FILE_NAME}`
    ).replace(/%2F/g, "/");
    apiPath = `${DRIVE_BASE}/root:${encodedPath}:/content`;
  }

  await graphClient.api(apiPath).put(JSON.stringify(config, null, 2));
}

// The DocumentIndex.xlsx is on the PA SharePoint drive.  We try both the
// app-configured drive and the PA drive so whichever is accessible works.
const PA_DRIVE_BASE = "/drives/b!n3T9Gbqmg0O2eszbebFLkVA5zDSKVf9Iq0BGw_Jwg1YdB2GHu-Y9Rp-A8SN8_-rV";
const EXCEL_FILE_PATH = "/IndexTable/DocumentIndex.xlsx";

/**
 * Reads currentDocumentIndex from the Power Automate Excel counter file.
 * Downloads the file directly (bypasses the workbook API which returns 404)
 * and extracts the value from the raw xlsx XML.
 * Returns null if the file cannot be reached.
 */
export async function getDocumentIndex(graphClient: Client): Promise<number | null> {
  for (const base of [DRIVE_BASE, PA_DRIVE_BASE]) {
    try {
      const item = await graphClient
        .api(`${base}/root:${EXCEL_FILE_PATH}`)
        .select("@microsoft.graph.downloadUrl")
        .get();

      const downloadUrl: string | undefined = item?.["@microsoft.graph.downloadUrl"];
      if (!downloadUrl) continue;

      const res = await fetch(downloadUrl);
      if (!res.ok) continue;

      const val = await parseXlsxIndex(await res.arrayBuffer());
      if (val !== null) return val;
    } catch {
      // try next drive
    }
  }
  return null;
}

/**
 * Proper xlsx (ZIP + DEFLATE) parser.  Walks the ZIP local-file-header chain,
 * finds xl/worksheets/sheet1.xml, decompresses it with the browser-native
 * DecompressionStream API, then reads the value from cell B2.
 */
async function parseXlsxIndex(buf: ArrayBuffer): Promise<number | null> {
  const bytes = new Uint8Array(buf);
  const view = new DataView(buf);
  let offset = 0;

  while (offset + 30 <= bytes.length) {
    // ZIP local-file-header signature 0x04034b50
    if (view.getUint32(offset, true) !== 0x04034b50) break;

    const method      = view.getUint16(offset + 8,  true);
    const compSize    = view.getUint32(offset + 18, true);
    const fileNameLen = view.getUint16(offset + 26, true);
    const extraLen    = view.getUint16(offset + 28, true);
    const dataStart   = offset + 30 + fileNameLen + extraLen;

    const fileName = new TextDecoder().decode(
      bytes.slice(offset + 30, offset + 30 + fileNameLen)
    );

    if (fileName === "xl/worksheets/sheet1.xml") {
      const compressed = bytes.slice(dataStart, dataStart + compSize);
      let xml: string;

      if (method === 0) {
        // Stored — no compression
        xml = new TextDecoder().decode(compressed);
      } else if (method === 8) {
        // Raw DEFLATE — use browser-native DecompressionStream
        const ds = new DecompressionStream("deflate-raw");
        const writer = ds.writable.getWriter();
        const reader = ds.readable.getReader();
        writer.write(compressed);
        writer.close();
        const chunks: Uint8Array[] = [];
        for (;;) {
          const { done, value } = await reader.read();
          if (done) break;
          chunks.push(value);
        }
        const out = new Uint8Array(chunks.reduce((n, c) => n + c.length, 0));
        let pos = 0;
        for (const c of chunks) { out.set(c, pos); pos += c.length; }
        xml = new TextDecoder().decode(out);
      } else {
        break; // unsupported compression method
      }

      return extractB2Value(xml);
    }

    offset = dataStart + compSize;
  }

  return null;
}

/** Read the numeric value of cell B2 from a worksheet XML string. */
function extractB2Value(xml: string): number | null {
  // Find row r="2"
  const rowMatch = xml.match(/<row\b[^>]*\br="2"[^>]*>([\s\S]*?)<\/row>/);
  if (!rowMatch) return null;
  const row = rowMatch[1];

  // Try explicit r="B2" attribute
  const explicit = row.match(/<c\b[^>]*\br="B2"[^>]*>[\s\S]*?<v>(\d+)<\/v>/);
  if (explicit) return parseInt(explicit[1], 10);

  // Fallback: second <v> element in the row (column B = second cell)
  const allV = [...row.matchAll(/<v>(\d+)<\/v>/g)];
  if (allV.length >= 2) return parseInt(allV[1][1], 10);

  return null;
}

