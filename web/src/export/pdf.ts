export interface PdfReport {
  readonly title: string;
  readonly subtitle?: string;
  readonly sections: readonly { readonly heading: string; readonly lines: readonly string[] }[];
}

function ascii(value: string): string { return value.normalize("NFKD").replace(/[^\x20-\x7e]/g, "?").replaceAll("\\", "\\\\").replaceAll("(", "\\(").replaceAll(")", "\\)"); }

/** Small deterministic, one-page PDF 1.4 report for browser-local downloads. */
export function buildPdfReport(report: PdfReport): Uint8Array {
  const pages: string[][] = [[]];
  let commands = pages[0];
  const text = (size: number, x: number, y: number, value: string) => commands.push(`/F1 ${size} Tf`, `1 0 0 1 ${x} ${y} Tm (${ascii(value)}) Tj`);
  const nextPage = () => { commands = []; pages.push(commands); };
  text(18, 52, 780, report.title);
  let y = 752;
  if (report.subtitle) { text(10, 52, y, report.subtitle); y -= 24; }
  for (const section of report.sections) {
    if (y < 90) { nextPage(); y = 760; }
    text(12, 52, y, section.heading); y -= 17;
    for (const sourceLine of section.lines) {
      const lineCount = Math.max(1, Math.ceil(sourceLine.length / 92));
      for (let lineIndex = 0; lineIndex < lineCount; lineIndex += 1) {
        if (y < 72) { nextPage(); y = 760; text(10, 52, y, `${section.heading} (continued)`); y -= 17; }
        text(9, 52, y, sourceLine.slice(lineIndex * 92, (lineIndex + 1) * 92)); y -= 13;
      }
    }
    y -= 8;
  }
  const encoder = new TextEncoder();
  const pageReferences = pages.map((_, index) => `${4 + index * 2} 0 R`).join(" ");
  const objects = ["<< /Type /Catalog /Pages 2 0 R >>", `<< /Type /Pages /Kids [${pageReferences}] /Count ${pages.length} >>`, "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"];
  pages.forEach((pageCommands, index) => {
    const contentReference = 5 + index * 2;
    const stream = `BT\n${pageCommands.join("\n")}\nET\n`;
    objects.push(`<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 3 0 R >> >> /Contents ${contentReference} 0 R >>`);
    objects.push(`<< /Length ${encoder.encode(stream).length} >>\nstream\n${stream}endstream`);
  });
  let document = "%PDF-1.4\n%CellCounter\n"; const offsets = [0];
  for (let index = 0; index < objects.length; index += 1) { offsets.push(encoder.encode(document).length); document += `${index + 1} 0 obj\n${objects[index]}\nendobj\n`; }
  const xref = encoder.encode(document).length;
  document += `xref\n0 ${objects.length + 1}\n0000000000 65535 f \n`;
  for (const offset of offsets.slice(1)) document += `${String(offset).padStart(10, "0")} 00000 n \n`;
  document += `trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\nstartxref\n${xref}\n%%EOF\n`;
  return encoder.encode(document);
}
