import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import {
  BackupData,
  BUILTIN_PRESETS,
  CropPreset,
  CropRecord,
  HarvestCycle,
  makeId,
  newCycle
} from '../model/CropModels';

const STATE_FILE = 'farmharvest-state.json';
const META_FILE = 'farmharvest-meta.json';

interface UploadMetadata {
  lastSuccessfulUploadTimestamp?: number;
}

interface NormalizableCropRecord {
  id: string;
  name: string;
  colorHex?: string;
  minutes?: number;
  plantedAt: string | number;
  harvests?: HarvestCycle[];
  note?: string;
  harvestAt?: string | number;
  extraHarvests?: Array<string | number>;
}

export class CropStore {
  private static context: common.UIAbilityContext | undefined;
  private static state: BackupData | undefined;

  static initialize(context: common.UIAbilityContext): void {
    CropStore.context = context;
    CropStore.state = CropStore.readState();
  }

  static records(): CropRecord[] {
    return CropStore.clone(CropStore.currentState().records);
  }

  static presets(): CropPreset[] {
    const state = CropStore.currentState();
    const hidden = new Set<string>(state.hiddenBuiltins);
    return [
      ...BUILTIN_PRESETS.filter((preset: CropPreset) => !hidden.has(preset.id)),
      ...CropStore.clone(state.customCrops)
    ];
  }

  static customPresets(): CropPreset[] {
    return CropStore.clone(CropStore.currentState().customCrops);
  }

  static addCustomPreset(name: string, minutes: number): CropPreset {
    const state = CropStore.clone(CropStore.currentState());
    const preset: CropPreset = {
      id: makeId(),
      name,
      colorHex: CropStore.paletteColor(state.customCrops.length),
      minutes: Math.max(1, Math.floor(minutes))
    };
    state.customCrops.push(preset);
    CropStore.saveState(state);
    return preset;
  }

  static createRecord(preset: CropPreset, minutes: number, note?: string): CropRecord {
    const now = new Date();
    const record: CropRecord = {
      id: makeId(),
      name: preset.name,
      colorHex: preset.colorHex,
      minutes,
      plantedAt: now.toISOString(),
      harvests: [newCycle(new Date(now.getTime() + minutes * 60000))],
      note
    };
    const state = CropStore.clone(CropStore.currentState());
    state.records.unshift(record);
    CropStore.saveState(state);
    return record;
  }

  static updateRecord(updated: CropRecord): boolean {
    const state = CropStore.clone(CropStore.currentState());
    const index = state.records.findIndex((record: CropRecord) => record.id === updated.id);
    if (index < 0) {
      return false;
    }
    state.records[index] = CropStore.clone(updated);
    return CropStore.saveState(state);
  }

  static toggleCycle(recordId: string, cycleId: string): boolean {
    const state = CropStore.clone(CropStore.currentState());
    const record = state.records.find((item: CropRecord) => item.id === recordId);
    const cycle = record?.harvests.find((item: HarvestCycle) => item.id === cycleId);
    if (record === undefined || cycle === undefined) {
      return false;
    }
    cycle.harvested = !cycle.harvested;
    return CropStore.saveState(state);
  }

  static renew(record: CropRecord): boolean {
    const state = CropStore.clone(CropStore.currentState());
    const target = state.records.find((item: CropRecord) => item.id === record.id);
    if (target === undefined) {
      return false;
    }
    const next = new Date(Date.now() + Math.max(1, record.minutes) * 60000);
    target.harvests.push(newCycle(next));
    target.harvests.sort((a: HarvestCycle, b: HarvestCycle) =>
      new Date(a.date).getTime() - new Date(b.date).getTime());
    return CropStore.saveState(state);
  }

  static deleteRecord(recordId: string): boolean {
    const state = CropStore.clone(CropStore.currentState());
    state.records = state.records.filter((record: CropRecord) => record.id !== recordId);
    return CropStore.saveState(state);
  }

  static clearEndedRecords(nowMillis: number): boolean {
    const state = CropStore.clone(CropStore.currentState());
    state.records = state.records.filter((record: CropRecord) =>
      record.harvests.length === 0 ||
      !record.harvests.every((cycle: HarvestCycle) =>
        cycle.harvested || new Date(cycle.date).getTime() <= nowMillis));
    return CropStore.saveState(state);
  }

  static replaceData(data: BackupData): boolean {
    return CropStore.saveState(CropStore.normalizeBackup(data));
  }

  static backupData(): BackupData {
    const state = CropStore.clone(CropStore.currentState());
    state.exportedAt = new Date().toISOString();
    return state;
  }

  static hiddenBuiltinIds(): string[] {
    return [...CropStore.currentState().hiddenBuiltins];
  }

  static lastUploadTimestamp(): number {
    const context = CropStore.context;
    if (context === undefined) {
      return 0;
    }
    try {
      const raw = fileIo.readTextSync(`${context.filesDir}/${META_FILE}`);
      const meta = JSON.parse(raw) as UploadMetadata;
      return meta.lastSuccessfulUploadTimestamp ?? 0;
    } catch (_) {
      return 0;
    }
  }

  static setLastUploadTimestamp(timestamp: number): void {
    const context = CropStore.context;
    if (context === undefined) {
      return;
    }
    CropStore.writeText(`${context.filesDir}/${META_FILE}`, JSON.stringify({
      lastSuccessfulUploadTimestamp: timestamp
    }));
  }

  private static paletteColor(index: number): string {
    const palette: string[] = [
      'FF8C42', '7AC74F', 'E63946', 'FFD23F', 'C08457',
      'F06595', '9B5DE5', '00BBF9', '00F5D4', 'F15BB5'
    ];
    return palette[index % palette.length];
  }

  private static currentState(): BackupData {
    if (CropStore.state === undefined) {
      CropStore.state = CropStore.readState();
    }
    return CropStore.state;
  }

  private static readState(): BackupData {
    const context = CropStore.context;
    const empty: BackupData = {
      version: 1,
      exportedAt: new Date().toISOString(),
      records: [],
      customCrops: [],
      hiddenBuiltins: []
    };
    if (context === undefined) {
      return empty;
    }
    try {
      const raw = fileIo.readTextSync(`${context.filesDir}/${STATE_FILE}`);
      return CropStore.normalizeBackup(JSON.parse(raw) as BackupData);
    } catch (_) {
      return empty;
    }
  }

  private static saveState(next: BackupData): boolean {
    const context = CropStore.context;
    if (context === undefined) {
      return false;
    }
    const normalized = CropStore.normalizeBackup(next);
    normalized.exportedAt = new Date().toISOString();
    const success = CropStore.writeText(
      `${context.filesDir}/${STATE_FILE}`,
      JSON.stringify(normalized, null, 2)
    );
    if (success) {
      CropStore.state = normalized;
    }
    return success;
  }

  private static writeText(path: string, text: string): boolean {
    let file: fileIo.File | undefined;
    try {
      file = fileIo.openSync(
        path,
        fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC
      );
      fileIo.writeSync(file.fd, text);
      return true;
    } catch (error) {
      console.error(`FarmHarvest could not write ${path}: ${JSON.stringify(error)}`);
      return false;
    } finally {
      if (file !== undefined) {
        try {
          fileIo.closeSync(file);
        } catch (_) {
          // The primary write result is more useful than a close cleanup error.
        }
      }
    }
  }

  private static normalizeBackup(source: BackupData): BackupData {
    const records = Array.isArray(source.records)
      ? source.records.map((record: CropRecord) =>
        CropStore.normalizeRecord(record as NormalizableCropRecord))
      : [];
    const customCrops = Array.isArray(source.customCrops)
      ? source.customCrops.map((preset: CropPreset): CropPreset => {
        const normalizedPreset: CropPreset = {
          id: String(preset.id),
          name: String(preset.name),
          colorHex: String(preset.colorHex),
          minutes: Math.max(1, Number(preset.minutes) || 30)
        };
        return normalizedPreset;
      })
      : [];
    return {
      version: Number(source.version) || 1,
      exportedAt: typeof source.exportedAt === 'string'
        ? source.exportedAt
        : new Date().toISOString(),
      records,
      customCrops,
      hiddenBuiltins: Array.isArray(source.hiddenBuiltins)
        ? source.hiddenBuiltins.map((id: string) => String(id))
        : []
    };
  }

  private static normalizeRecord(source: NormalizableCropRecord): CropRecord {
    let harvests: HarvestCycle[] = Array.isArray(source.harvests)
      ? source.harvests.map((cycle: HarvestCycle): HarvestCycle => ({
        id: String(cycle.id || makeId()),
        date: CropStore.normalizeDate(cycle.date),
        harvested: Boolean(cycle.harvested)
      }))
      : [];

    if (harvests.length === 0 && source.harvestAt !== undefined) {
      const oldDates: Array<string | number> = [
        source.harvestAt,
        ...(source.extraHarvests ?? [])
      ];
      harvests = oldDates.map((date: string | number): HarvestCycle => ({
        id: makeId(),
        date: CropStore.normalizeDate(date),
        harvested: false
      }));
    }

    return {
      id: String(source.id),
      name: String(source.name),
      colorHex: String(source.colorHex || '7AC74F'),
      minutes: Math.max(0, Number(source.minutes) || 0),
      plantedAt: CropStore.normalizeDate(source.plantedAt),
      harvests: harvests.sort((a: HarvestCycle, b: HarvestCycle) =>
        new Date(a.date).getTime() - new Date(b.date).getTime()),
      note: typeof source.note === 'string' ? source.note : undefined
    };
  }

  private static normalizeDate(value: string | number | undefined): string {
    if (typeof value === 'number') {
      return new Date((value + 978307200) * 1000).toISOString();
    }
    const parsed = new Date(value ?? '');
    return Number.isNaN(parsed.getTime()) ? new Date().toISOString() : parsed.toISOString();
  }

  private static clone<T>(value: T): T {
    return JSON.parse(JSON.stringify(value)) as T;
  }
}
