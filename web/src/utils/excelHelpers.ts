import * as XLSX from 'xlsx';

export function getXlsxLib() {
  return (XLSX as unknown as { default?: typeof XLSX }).default || XLSX;
}

export function normalizeExcelKey(key: string): string {
  return key
    .trim()
    .toLowerCase()
    .normalize('NFD')
    .replace(/[\u0300-\u036f]/g, '')
    .replace(/đ/g, 'd')
    .replace(/[^a-z0-9]/g, '');
}

export async function readExcelRows(file: File): Promise<Record<string, unknown>[]> {
  const xlsxLib = getXlsxLib();
  const buffer = await file.arrayBuffer();
  const bytes = new Uint8Array(buffer);
  const workbook = xlsxLib.read(bytes, { type: 'array' });
  const firstSheet = workbook.SheetNames[0];
  if (!firstSheet) return [];
  const sheet = workbook.Sheets[firstSheet];
  return xlsxLib.utils.sheet_to_json<Record<string, unknown>>(sheet, { defval: '' });
}

export async function readAllExcelSheets(
  file: File
): Promise<{ sheetName: string; rowNumber: number; data: Record<string, unknown> }[]> {
  const xlsxLib = getXlsxLib();
  const buffer = await file.arrayBuffer();
  const bytes = new Uint8Array(buffer);
  const workbook = xlsxLib.read(bytes, { type: 'array' });
  const allRows: { sheetName: string; rowNumber: number; data: Record<string, unknown> }[] = [];

  for (const sheetName of workbook.SheetNames) {
    const sheet = workbook.Sheets[sheetName];
    if (!sheet) continue;
    const rows = xlsxLib.utils.sheet_to_json<Record<string, unknown>>(sheet, { defval: '' });
    rows.forEach((data, idx) => {
      allRows.push({ sheetName, rowNumber: idx + 2, data });
    });
  }
  return allRows;
}