import mammoth from "mammoth";

export interface ConversionResult {
  html: string;
  warnings: string[];
}

export async function convertDocxToHtml(
  file: File
): Promise<ConversionResult> {
  const arrayBuffer = await file.arrayBuffer();

  const result = await mammoth.convertToHtml(
    { arrayBuffer },
    {
      styleMap: [
        "p[style-name='Heading 1'] => h1:fresh",
        "p[style-name='Heading 2'] => h2:fresh",
        "p[style-name='Heading 3'] => h3:fresh",
        "p[style-name='Title'] => h1.title:fresh",
        "b => strong",
        "i => em",
        "u => u",
      ],
    }
  );

  const cleanHtml = cleanupHtml(result.value);

  return {
    html: cleanHtml,
    warnings: result.messages.map((m) => m.message),
  };
}

function cleanupHtml(html: string): string {
  let cleaned = html;

  // Remove empty paragraphs
  cleaned = cleaned.replace(/<p>\s*<\/p>/g, "");

  // Wrap in basic email-safe structure if not already wrapped
  if (!cleaned.includes("<html")) {
    cleaned = `<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<style>
  body { font-family: Arial, Helvetica, sans-serif; line-height: 1.6; color: #333; max-width: 600px; margin: 0 auto; padding: 20px; }
  h1 { color: #1a5276; border-bottom: 2px solid #e67e22; padding-bottom: 8px; }
  h2 { color: #2c3e50; }
  h3 { color: #34495e; }
  img { max-width: 100%; height: auto; }
  table { border-collapse: collapse; width: 100%; }
  td, th { border: 1px solid #ddd; padding: 8px; }
</style>
</head>
<body>
${cleaned}
</body>
</html>`;
  }

  return cleaned;
}

export function extractTitleFromFileName(fileName: string): string {
  return fileName
    .replace(/\.docx?$/i, "")
    .replace(/[_-]/g, " ")
    .replace(/\b\w/g, (c) => c.toUpperCase())
    .trim();
}
