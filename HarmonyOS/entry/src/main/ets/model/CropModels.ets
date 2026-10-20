export interface HarvestCycle {
  id: string;
  date: string;
  harvested: boolean;
}

export interface CropRecord {
  id: string;
  name: string;
  colorHex: string;
  minutes: number;
  plantedAt: string;
  harvests: HarvestCycle[];
  note?: string;
}

export interface CropPreset {
  id: string;
  name: string;
  colorHex: string;
  minutes: number;
}

export interface BackupData {
  version: number;
  exportedAt: string;
  records: CropRecord[];
  customCrops: CropPreset[];
  hiddenBuiltins: string[];
}

export const BUILTIN_PRESETS: CropPreset[] = [
  { id: 'carrot', name: '快速事项', colorHex: 'FF8C42', minutes: 20 },
  { id: 'cabbage', name: '常规事项', colorHex: '7AC74F', minutes: 40 },
  { id: 'tomato', name: '专注事项', colorHex: 'E63946', minutes: 60 },
  { id: 'corn', name: '长时事项', colorHex: 'FFD23F', minutes: 90 },
  { id: 'potato', name: '短时提醒', colorHex: 'C08457', minutes: 30 },
  { id: 'strawberry', name: '日常安排', colorHex: 'F06595', minutes: 45 }
];

export const CROP_PALETTE: string[] = [
  'FF8C42', '7AC74F', 'E63946', 'FFD23F', 'C08457',
  'F06595', '9B5DE5', '00BBF9', '00F5D4', 'F15BB5'
];

export function makeId(): string {
  return `${Date.now()}-${Math.random().toString(36).slice(2, 10)}`;
}

export function newCycle(date: Date): HarvestCycle {
  return {
    id: makeId(),
    date: date.toISOString(),
    harvested: false
  };
}

export function parseStoredDate(value: string | number | undefined): Date {
  if (typeof value === 'number') {
    // Swift's default JSONEncoder encodes Date as seconds from 2001-01-01.
    return new Date((value + 978307200) * 1000);
  }
  const parsed = new Date(value ?? '');
  return Number.isNaN(parsed.getTime()) ? new Date() : parsed;
}

export function dateLabel(value: string | Date): string {
  const date = typeof value === 'string' ? parseStoredDate(value) : value;
  const pad = (part: number): string => part.toString().padStart(2, '0');
  return `${date.getFullYear()}/${pad(date.getMonth() + 1)}/${pad(date.getDate())} ` +
    `${pad(date.getHours())}:${pad(date.getMinutes())}`;
}

export function remainingLabel(target: string, nowMillis: number): string {
  const seconds = Math.max(0, Math.floor((parseStoredDate(target).getTime() - nowMillis) / 1000));
  const days = Math.floor(seconds / 86400);
  const hours = Math.floor((seconds % 86400) / 3600);
  const minutes = Math.floor((seconds % 3600) / 60);
  const restSeconds = seconds % 60;
  if (days > 0) {
    return `${days}天 ${hours}小时`;
  }
  if (hours > 0) {
    return `${hours}小时 ${minutes}分`;
  }
  if (minutes > 0) {
    return `${minutes}分 ${restSeconds}秒`;
  }
  return `${restSeconds}秒`;
}

export function recordIsClearable(record: CropRecord, nowMillis: number): boolean {
  return record.harvests.length > 0 &&
    record.harvests.every((cycle: HarvestCycle) =>
      cycle.harvested || parseStoredDate(cycle.date).getTime() <= nowMillis);
}

export function cycleIsDue(cycle: HarvestCycle, nowMillis: number): boolean {
  return !cycle.harvested && parseStoredDate(cycle.date).getTime() <= nowMillis;
}
