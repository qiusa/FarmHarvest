import { common } from '@kit.AbilityKit';
import { url } from '@kit.ArkTS';
import { fileIo, picker } from '@kit.CoreFileKit';
import { http } from '@kit.NetworkKit';
import {
  BackupData,
  CropPreset,
  CropRecord
} from '../model/CropModels';
import { CropStore } from './CropStore';

export enum ImportMode {
  MERGE = 'merge',
  REPLACE = 'replace'
}

export interface ImportSummary {
  text: string;
  recordsAdded: number;
  recordsOverwritten: number;
  cropsAdded: number;
  cropsOverwritten: number;
}

export interface UploadResult {
  fileName: string;
  localPath: string;
  downloadURL: string;
  size: number;
}

interface UploadErrorPayload {
  error?: string;
}

interface UploadedFilePayload {
  fileName: string;
  localPath: string;
  url?: string;
  size: number;
}

const BACKUP_FILE_NAME = 'FarmHarvest.json';
const REMOTE_BACKUP_URL = 'http://192.168.200.94:10023/source/FarmHarvest.json';
const UPLOAD_ENDPOINT = 'http://192.168.200.94:3211/api/source-files';
const UPLOAD_TOKEN = '93c294dc9066ad5fce4e35ad4dc008a7a87feef0465d8af7';
const SOURCE_HOST = '192.168.200.94';
const SOURCE_PORT = 10023;
const MAX_BACKUP_CHARS = 10 * 1024 * 1024;

export class BackupService {
  static backupFileName(): string {
    return BACKUP_FILE_NAME;
  }

  static remoteBackupURL(): string {
    return REMOTE_BACKUP_URL;
  }

  static exportBackupJSON(): string {
    return JSON.stringify(CropStore.backupData(), null, 2);
  }

  static async uploadCurrentBackup(): Promise<UploadResult> {
    const bodyJSON = BackupService.exportBackupJSON();
    if (bodyJSON.length > MAX_BACKUP_CHARS) {
      throw new Error('备份文件超过 10 MB，已取消上传。');
    }
    const boundary = `FarmHarvest-${Date.now()}-${Math.random().toString(36).slice(2)}`;
    const body = `--${boundary}\r\n` +
      `Content-Disposition: form-data; name="file"; filename="${BACKUP_FILE_NAME}"\r\n` +
      'Content-Type: application/json; charset=utf-8\r\n\r\n' +
      `${bodyJSON}\r\n--${boundary}--\r\n`;

    const client = http.createHttp();
    try {
      const response = await client.request(UPLOAD_ENDPOINT, {
        method: http.RequestMethod.POST,
        extraData: body,
        header: {
          'content-type': `multipart/form-data; boundary=${boundary}`,
          'x-upload-token': UPLOAD_TOKEN,
          accept: 'application/json'
        },
        connectTimeout: 30000,
        readTimeout: 600000,
        expectDataType: http.HttpDataType.STRING
      });
      const responseBody = BackupService.responseText(response.result);
      if (response.responseCode !== 201) {
        let detail = '';
        try {
          const errorBody = JSON.parse(responseBody) as UploadErrorPayload;
          detail = errorBody.error ?? '';
        } catch (_) {
          // Use the HTTP status message below when the response is not JSON.
        }
        throw new Error(detail.length > 0
          ? `上传失败：${detail}`
          : `上传失败：服务器返回 HTTP ${response.responseCode}。`);
      }

      const payload = JSON.parse(responseBody) as UploadedFilePayload;
      const downloadURL = BackupService.validatedUploadedURL(payload.url, payload.localPath);
      if (downloadURL.length === 0) {
        throw new Error('文件已上传，但服务器返回的下载地址无效。');
      }
      CropStore.setLastUploadTimestamp(Date.now());
      return {
        fileName: payload.fileName,
        localPath: payload.localPath,
        downloadURL,
        size: payload.size
      };
    } finally {
      client.destroy();
    }
  }

  static async importRemoteBackup(mode: ImportMode): Promise<ImportSummary> {
    if (!BackupService.isAllowedRemoteURL(REMOTE_BACKUP_URL)) {
      throw new Error('远程备份地址无效。');
    }
    const client = http.createHttp();
    try {
      const response = await client.request(REMOTE_BACKUP_URL, {
        method: http.RequestMethod.GET,
        header: {
          accept: 'application/json',
          'cache-control': 'no-cache'
        },
        usingCache: false,
        connectTimeout: 30000,
        readTimeout: 30000,
        expectDataType: http.HttpDataType.STRING
      });
      if (response.responseCode < 200 || response.responseCode >= 300) {
        throw new Error(`远程服务器返回 HTTP ${response.responseCode}。`);
      }
      const text = BackupService.responseText(response.result);
      if (text.length > MAX_BACKUP_CHARS) {
        throw new Error('备份文件超过 10 MB，已取消导入。');
      }
      return BackupService.importBackupJSON(text, mode);
    } finally {
      client.destroy();
    }
  }

  static importBackupJSON(text: string, mode: ImportMode): ImportSummary {
    let backup: BackupData;
    try {
      backup = JSON.parse(text) as BackupData;
    } catch (_) {
      throw new Error('备份不是有效的 JSON 文件。');
    }
    if (backup.version > 1) {
      throw new Error(`备份版本 ${backup.version} 高于当前元服务支持的版本。`);
    }
    if (!Array.isArray(backup.records) || !Array.isArray(backup.customCrops)) {
      throw new Error('备份缺少记录或模板数据，无法导入。');
    }

    const local = CropStore.backupData();
    const recordsAdded = backup.records.filter((item: CropRecord) =>
      !local.records.some((existing: CropRecord) => existing.id === item.id)).length;
    const recordsOverwritten = backup.records.length - recordsAdded;
    const cropsAdded = backup.customCrops.filter((item: CropPreset) =>
      !local.customCrops.some((existing: CropPreset) => existing.id === item.id)).length;
    const cropsOverwritten = backup.customCrops.length - cropsAdded;

    let next: BackupData;
    if (mode === ImportMode.REPLACE) {
      next = {
        version: 1,
        exportedAt: new Date().toISOString(),
        records: backup.records,
        customCrops: backup.customCrops,
        hiddenBuiltins: backup.hiddenBuiltins ?? []
      };
    } else {
      const backupRecordIDs = new Set(backup.records.map((record: CropRecord) => record.id));
      const backupPresetIDs = new Set(backup.customCrops.map((preset: CropPreset) => preset.id));
      next = {
        version: 1,
        exportedAt: new Date().toISOString(),
        records: [
          ...local.records.filter((record: CropRecord) => !backupRecordIDs.has(record.id)),
          ...backup.records
        ],
        customCrops: [
          ...local.customCrops.filter((preset: CropPreset) => !backupPresetIDs.has(preset.id)),
          ...backup.customCrops
        ],
        hiddenBuiltins: BackupService.mergedHiddenBuiltins(
          local.hiddenBuiltins,
          backup.hiddenBuiltins ?? []
        )
      };
    }

    if (!CropStore.replaceData(next)) {
      throw new Error('导入失败：无法保存到本机存储。');
    }

    const textResult = mode === ImportMode.REPLACE
      ? `已替换：记录 ${backup.records.length} 条 · 模板 ${backup.customCrops.length} 个`
      : `已合并：${recordsAdded > 0 ? `新增记录 ${recordsAdded} 条` : '无新增记录'}` +
        `${recordsOverwritten > 0 ? ` · 覆盖 ${recordsOverwritten} 条` : ''}` +
        ` · ${cropsAdded > 0 ? `新增模板 ${cropsAdded} 个` : '无新增模板'}` +
        `${cropsOverwritten > 0 ? ` · 覆盖 ${cropsOverwritten} 个` : ''}`;
    return {
      text: textResult,
      recordsAdded,
      recordsOverwritten,
      cropsAdded,
      cropsOverwritten
    };
  }

  static async exportBackupToFile(context: common.UIAbilityContext): Promise<boolean> {
    const documentPicker = new picker.DocumentViewPicker(context);
    const uris = await documentPicker.save({
      newFileNames: [BACKUP_FILE_NAME],
      fileSuffixChoices: ['JSON|json']
    });
    if (uris.length === 0) {
      return false;
    }
    const file = fileIo.openSync(
      uris[0],
      fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC
    );
    try {
      fileIo.writeSync(file.fd, BackupService.exportBackupJSON());
    } finally {
      fileIo.closeSync(file);
    }
    return true;
  }

  static async importBackupFromFile(
    context: common.UIAbilityContext,
    mode: ImportMode
  ): Promise<ImportSummary | undefined> {
    const documentPicker = new picker.DocumentViewPicker(context);
    const uris = await documentPicker.select({
      fileSuffixFilters: ['json']
    });
    if (uris.length === 0) {
      return undefined;
    }
    const text = fileIo.readTextSync(uris[0]);
    if (text.length > MAX_BACKUP_CHARS) {
      throw new Error('备份文件超过 10 MB，已取消导入。');
    }
    return BackupService.importBackupJSON(text, mode);
  }

  static isAllowedRemoteURL(value: string): boolean {
    try {
      const parsedURL = url.URL.parseURL(value);
      if (parsedURL.protocol === 'https:' &&
          parsedURL.username.length === 0 && parsedURL.password.length === 0) {
        return true;
      }
      if (parsedURL.protocol !== 'http:' || parsedURL.hostname.toLowerCase() !== SOURCE_HOST ||
          Number(parsedURL.port) !== SOURCE_PORT || parsedURL.username.length > 0 ||
          parsedURL.password.length > 0 || parsedURL.search.length > 0 ||
          parsedURL.hash.length > 0) {
        return false;
      }
      const parts = parsedURL.pathname.split('/').filter((part: string) => part.length > 0);
      return parts.length === 2 && parts[0] === 'source' &&
        parts[1] !== '.' && parts[1] !== '..' && !parts[1].includes('\\');
    } catch (_) {
      return false;
    }
  }

  private static mergedHiddenBuiltins(local: string[], backup: string[]): string[] {
    const merged: string[] = [];
    for (const id of local) {
      if (!merged.includes(id)) {
        merged.push(id);
      }
    }
    for (const id of backup) {
      if (!merged.includes(id)) {
        merged.push(id);
      }
    }
    return merged;
  }

  private static validatedUploadedURL(urlText: string | undefined, localPath: string): string {
    if (urlText !== undefined && BackupService.isAllowedUploadedURL(urlText)) {
      return urlText;
    }
    const parts = localPath.split('/');
    if (parts.length !== 2 || parts[0] !== 'source' ||
        parts[1].length === 0 || parts[1] === '.' || parts[1] === '..' ||
        parts[1].includes('\\')) {
      return '';
    }
    const fallback = `http://${SOURCE_HOST}:${SOURCE_PORT}/${localPath}`;
    return BackupService.isAllowedUploadedURL(fallback) ? fallback : '';
  }

  private static isAllowedUploadedURL(value: string): boolean {
    try {
      const parsedURL = url.URL.parseURL(value);
      if (parsedURL.protocol !== 'http:' || parsedURL.hostname.toLowerCase() !== SOURCE_HOST ||
          Number(parsedURL.port) !== SOURCE_PORT || parsedURL.username.length > 0 ||
          parsedURL.password.length > 0 || parsedURL.search.length > 0 ||
          parsedURL.hash.length > 0) {
        return false;
      }
      const parts = parsedURL.pathname.split('/').filter((part: string) => part.length > 0);
      return parts.length === 2 && parts[0] === 'source' &&
        parts[1] !== '.' && parts[1] !== '..' && !parts[1].includes('\\');
    } catch (_) {
      return false;
    }
  }

  private static responseText(result: string | Object | ArrayBuffer): string {
    return typeof result === 'string' ? result : JSON.stringify(result);
  }
}
