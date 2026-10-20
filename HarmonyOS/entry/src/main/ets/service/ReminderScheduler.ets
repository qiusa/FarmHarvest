import { CropRecord, HarvestCycle, parseStoredDate } from '../model/CropModels';

/**
 * ReminderAgent and NotificationKit publishing are not available to atomic
 * services in the current SDK API set. While the service page is visible, use
 * a short UI toast as a best-effort cue; this is not a background notification.
 */
export class ReminderScheduler {
  private static notifiedKeys: Set<string> = new Set<string>();

  static checkForeground(
    records: CropRecord[],
    nowMillis: number,
    showToast: (message: string) => void
  ): string {
    let sent = 0;
    let failed = false;
    for (const record of records) {
      const sortedCycles = record.harvests.slice().sort(
        (left: HarvestCycle, right: HarvestCycle) =>
          parseStoredDate(left.date).getTime() - parseStoredDate(right.date).getTime()
      );
      for (const cycle of sortedCycles) {
        if (cycle.harvested) {
          continue;
        }
        const target = parseStoredDate(cycle.date).getTime();
        const suffix = sortedCycles.length > 1
          ? `（第 ${sortedCycles.findIndex((item: HarvestCycle) => item.id === cycle.id) + 1}/${sortedCycles.length} 次）`
          : '';

        if (target - 120000 <= nowMillis && nowMillis < target) {
          const key = `${record.id}:${cycle.id}:${target}:early`;
          if (!ReminderScheduler.notifiedKeys.has(key)) {
            ReminderScheduler.notifiedKeys.add(key);
            try {
              showToast(`${record.name} 即将到时间${suffix} · 还有 2 分钟`);
              sent += 1;
            } catch (error) {
              failed = true;
              console.warn(`Unable to show pre-reminder: ${JSON.stringify(error)}`);
            }
          }
        }

        if (target <= nowMillis) {
          const key = `${record.id}:${cycle.id}:${target}:due`;
          if (!ReminderScheduler.notifiedKeys.has(key)) {
            ReminderScheduler.notifiedKeys.add(key);
            try {
              showToast(`${record.name} 时间到了${suffix} · ${ReminderScheduler.formatDate(new Date(target))}`);
              sent += 1;
            } catch (error) {
              failed = true;
              console.warn(`Unable to show due reminder: ${JSON.stringify(error)}`);
            }
          }
        }
      }
    }

    if (failed) {
      return '部分前台提示未能显示；元服务不支持后台定时通知。';
    }
    if (sent > 0) {
      return `已显示 ${sent} 条前台提示。元服务未运行时不会在后台触发提醒。`;
    }
    return '倒计时与到期前提示仅在元服务运行时生效；退出后不会后台提醒。';
  }

  private static formatDate(date: Date): string {
    const pad = (part: number): string => part.toString().padStart(2, '0');
    return `${date.getMonth() + 1}月${date.getDate()}日 ${pad(date.getHours())}:${pad(date.getMinutes())}`;
  }
}
