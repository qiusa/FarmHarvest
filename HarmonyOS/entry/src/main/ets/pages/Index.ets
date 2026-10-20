import { common } from '@kit.AbilityKit';
import {
  CropPreset,
  CropRecord,
  HarvestCycle,
  BUILTIN_PRESETS,
  cycleIsDue,
  dateLabel,
  newCycle,
  parseStoredDate,
  recordIsClearable,
  remainingLabel
} from '../model/CropModels';
import { BackupService, ImportMode } from '../service/BackupService';
import { CropStore } from '../service/CropStore';
import { ReminderScheduler } from '../service/ReminderScheduler';

@Entry
@Component
struct Index {
  @State private activeTab: number = 0;
  @State private records: CropRecord[] = [];
  @State private presets: CropPreset[] = [];
  @State private selectedPresetID: string = BUILTIN_PRESETS[0].id;
  @State private minutesText: string = `${BUILTIN_PRESETS[0].minutes}`;
  @State private note: string = '';
  @State private nowMillis: number = Date.now();

  @State private showAddPreset: boolean = false;
  @State private newPresetName: string = '';
  @State private newPresetMinutes: string = '30';

  @State private editingRecord: CropRecord | undefined = undefined;
  @State private editName: string = '';
  @State private editNote: string = '';
  @State private editCycles: HarvestCycle[] = [];
  @State private expandedCycleID: string = '';
  @State private adjustHours: string = '1';
  @State private adjustMinutes: string = '0';
  @State private addCycleAbsolute: boolean = false;
  @State private addCycleHours: string = '1';
  @State private addCycleMinutes: string = '0';
  @State private addCycleDate: Date = new Date(Date.now() + 3600000);

  @State private pendingDeleteRecord: CropRecord | undefined = undefined;
  @State private pendingDeleteCycleID: string = '';
  @State private showClearConfirmation: boolean = false;
  @State private showRemoteReplaceConfirmation: boolean = false;

  @State private remoteImportMode: ImportMode = ImportMode.MERGE;
  @State private isImporting: boolean = false;
  @State private isUploading: boolean = false;
  @State private lastUploadTimestamp: number = 0;
  @State private notificationStatus: string = '到期提示仅在元服务运行时显示。';

  private context: common.UIAbilityContext | undefined = undefined;
  private clockTimer: number = -1;
  private notificationCheckRunning: boolean = false;

  aboutToAppear(): void {
    const hostContext = this.getUIContext().getHostContext();
    if (hostContext === undefined) {
      this.showMessage('无法读取元服务运行环境。');
      return;
    }
    this.context = hostContext as common.UIAbilityContext;
    CropStore.initialize(this.context);
    this.lastUploadTimestamp = CropStore.lastUploadTimestamp();
    this.refreshFromStore();
    this.clockTimer = setInterval(() => {
      this.nowMillis = Date.now();
      this.checkNotifications();
    }, 1000);
  }

  aboutToDisappear(): void {
    if (this.clockTimer >= 0) {
      clearInterval(this.clockTimer);
      this.clockTimer = -1;
    }
  }

  private refreshFromStore(): void {
    this.records = CropStore.records();
    this.presets = CropStore.presets();
    if (!this.presets.some((preset: CropPreset) => preset.id === this.selectedPresetID)) {
      const first = this.presets[0];
      if (first !== undefined) {
        this.selectedPresetID = first.id;
        this.minutesText = `${first.minutes}`;
      }
    }
    this.checkNotifications();
  }

  private checkNotifications(): void {
    if (this.notificationCheckRunning) {
      return;
    }
    this.notificationCheckRunning = true;
    try {
      this.notificationStatus = ReminderScheduler.checkForeground(
        this.records,
        this.nowMillis,
        (message: string) => this.getUIContext().getPromptAction().showToast({
          message,
          duration: 2500
        })
      );
    } catch (error) {
      this.notificationStatus = `前台提示显示失败：${(error as Error).message}`;
    } finally {
      this.notificationCheckRunning = false;
    }
  }

  private selectedPreset(): CropPreset | undefined {
    return this.presets.find((preset: CropPreset) => preset.id === this.selectedPresetID);
  }

  private parsedMinutes(): number | undefined {
    const value = Number.parseInt(this.minutesText.trim(), 10);
    return Number.isFinite(value) && value > 0 ? value : undefined;
  }

  private showMessage(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message, duration: 2500 });
    } catch (error) {
      console.warn(`Unable to show toast: ${JSON.stringify(error)}`);
    }
  }

  private titleForTab(): string {
    if (this.activeTab === 0) {
      return '新建事项';
    }
    return this.activeTab === 1 ? '事项记录' : '数据备份';
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      Column() {
        this.header()
        if (this.activeTab === 0) {
          this.newItemPage()
        } else if (this.activeTab === 1) {
          this.recordsPage()
        } else {
          this.dataPage()
        }
        this.bottomTabs()
      }
      .width('100%')
      .height('100%')
      .backgroundColor('#F4F7F1')

      if (this.showAddPreset) {
        this.addPresetDialog()
      }
      if (this.editingRecord !== undefined) {
        this.editRecordDialog()
      }
      if (this.pendingDeleteRecord !== undefined) {
        this.deleteRecordDialog()
      }
      if (this.pendingDeleteCycleID.length > 0) {
        this.deleteCycleDialog()
      }
      if (this.showClearConfirmation) {
        this.clearConfirmationDialog()
      }
      if (this.showRemoteReplaceConfirmation) {
        this.remoteReplaceDialog()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F4F7F1')
  }

  @Builder
  private header() {
    Row() {
      Column({ space: 3 }) {
        Text(this.titleForTab())
          .fontSize(24)
          .fontWeight(FontWeight.Bold)
          .fontColor('#1E3023')
        Text('把每个时间点，都安排得刚刚好')
          .fontSize(12)
          .fontColor('#768276')
      }
      .alignItems(HorizontalAlign.Start)

      Blank()

      if (this.activeTab === 0) {
        Button('＋ 模板')
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor('#23633B')
          .backgroundColor('#E2EEDF')
          .borderRadius(18)
          .height(38)
          .onClick(() => {
            this.newPresetName = '';
            this.newPresetMinutes = '30';
            this.showAddPreset = true;
          })
      }
    }
    .width('100%')
    .padding({ left: 20, right: 20, top: 16, bottom: 14 })
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  private bottomTabs() {
    Row() {
      this.tabButton('＋', '新建事项', 0)
      this.tabButton('◷', '记录', 1)
      this.tabButton('⇧', '数据', 2)
    }
    .width('100%')
    .height(66)
    .padding({ left: 10, right: 10, top: 6, bottom: 8 })
    .backgroundColor('#FFFFFF')
  }

  @Builder
  private tabButton(icon: string, label: string, tab: number) {
    Column({ space: 3 }) {
      Text(icon)
        .fontSize(20)
        .fontColor(this.activeTab === tab ? '#2D7A46' : '#8A958A')
      Text(label)
        .fontSize(11)
        .fontWeight(this.activeTab === tab ? FontWeight.Medium : FontWeight.Regular)
        .fontColor(this.activeTab === tab ? '#2D7A46' : '#8A958A')
    }
    .layoutWeight(1)
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .onClick(() => {
      this.activeTab = tab;
      this.refreshFromStore();
    })
  }

  @Builder
  private newItemPage() {
    Scroll() {
      Column({ space: 16 }) {
        SectionCard({ title: '选择模板', subtitle: '选择事项类型，再设置这次提醒间隔' }) {
          Scroll() {
            Row({ space: 9 }) {
              ForEach(this.presets, (preset: CropPreset) => {
                this.presetChip(preset)
              }, (preset: CropPreset) => preset.id)
            }
            .padding({ right: 4 })
          }
          .scrollable(ScrollDirection.Horizontal)
          .scrollBar(BarState.Off)
          .width('100%')
        }

        SectionCard({ title: '提醒间隔', subtitle: '元服务运行时会在设定时间显示前台提示' }) {
          Row({ space: 10 }) {
            TextInput({ text: this.minutesText, placeholder: '30' })
              .type(InputType.Number)
              .fontSize(17)
              .fontColor('#203026')
              .backgroundColor('#F4F7F3')
              .borderRadius(12)
              .padding(12)
              .layoutWeight(1)
              .onChange((value: string) => {
                this.minutesText = value;
              })
            Text('分钟')
              .fontSize(14)
              .fontColor('#6F7E70')
          }

          if (this.parsedMinutes() !== undefined) {
            Text(`预计提醒：${dateLabel(new Date(this.nowMillis + (this.parsedMinutes() ?? 0) * 60000))}`)
              .fontSize(12)
              .fontColor('#768276')
          } else {
            Text('请输入大于 0 的分钟数')
              .fontSize(12)
              .fontColor('#D88745')
          }
        }

        SectionCard({ title: '备注（可选）', subtitle: '写下地点、对象或其他说明' }) {
          TextArea({ text: this.note, placeholder: '例如：会议材料' })
            .fontSize(14)
            .fontColor('#203026')
            .backgroundColor('#F4F7F3')
            .borderRadius(12)
            .height(92)
            .padding(12)
            .onChange((value: string) => {
              this.note = value;
            })
        }

        Button('添加提醒')
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor('#FFFFFF')
          .backgroundColor('#2F7D48')
          .borderRadius(16)
          .width('100%')
          .height(52)
          .enabled(this.selectedPreset() !== undefined && this.parsedMinutes() !== undefined)
          .onClick(() => this.addRecord())

        Text(this.notificationStatus)
          .fontSize(11)
          .fontColor('#879187')
          .width('100%')
          .textAlign(TextAlign.Center)
          .padding({ top: 2, bottom: 8 })
      }
      .width('100%')
      .padding({ left: 18, right: 18, top: 4, bottom: 16 })
    }
    .layoutWeight(1)
    .scrollBar(BarState.Off)
  }

  @Builder
  private presetChip(preset: CropPreset) {
    Column({ space: 7 }) {
      Row({ space: 7 }) {
        Text(preset.name.substring(0, 1))
          .fontSize(12)
          .fontWeight(FontWeight.Bold)
          .fontColor('#FFFFFF')
          .width(24)
          .height(24)
          .textAlign(TextAlign.Center)
          .backgroundColor(`#${preset.colorHex}`)
          .borderRadius(12)
        Text(this.selectedPresetID === preset.id ? '已选' : `${preset.minutes} 分钟`)
          .fontSize(10)
          .fontColor(this.selectedPresetID === preset.id ? '#2F7D48' : '#7D887D')
      }
      Text(preset.name)
        .fontSize(13)
        .fontWeight(this.selectedPresetID === preset.id ? FontWeight.Bold : FontWeight.Medium)
        .fontColor('#243328')
        .maxLines(1)
    }
    .alignItems(HorizontalAlign.Start)
    .width(116)
    .padding(11)
    .backgroundColor(this.selectedPresetID === preset.id ? '#EAF4E7' : '#F6F8F5')
    .borderRadius(14)
    .onClick(() => {
      this.selectedPresetID = preset.id;
      this.minutesText = `${preset.minutes}`;
    })
  }

  @Builder
  private recordsPage() {
    Scroll() {
      Column({ space: 14 }) {
        Row({ space: 8 }) {
          this.statCard('待提醒', this.countPending(), '#E89A36')
          this.statCard('已到期', this.countReady(), '#3D965C')
          this.statCard('总计', this.records.length, '#637A67')
        }
        .width('100%')

        Row() {
          Text(`提醒记录（${this.records.length}）`)
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor('#253529')
          Blank()
          Button('清理已结束')
            .fontSize(12)
            .fontColor(this.clearableCount() > 0 ? '#B34D39' : '#A8B0A7')
            .backgroundColor('#FFFFFF')
            .borderRadius(14)
            .enabled(this.clearableCount() > 0)
            .onClick(() => {
              this.showClearConfirmation = true;
            })
        }
        .width('100%')
        .padding({ top: 2 })

        if (this.records.length === 0) {
          Column({ space: 10 }) {
            Text('◷')
              .fontSize(38)
              .fontColor('#A0B4A0')
            Text('还没有提醒记录')
              .fontSize(16)
              .fontWeight(FontWeight.Bold)
              .fontColor('#526052')
            Text('到「新建事项」页面添加一条记录。')
              .fontSize(12)
              .fontColor('#879187')
          }
          .width('100%')
          .padding({ top: 52, bottom: 52 })
          .backgroundColor('#FFFFFF')
          .borderRadius(18)
        } else {
          ForEach(this.records, (record: CropRecord) => {
            this.recordCard(record)
          }, (record: CropRecord) => record.id)
        }
      }
      .width('100%')
      .padding({ left: 18, right: 18, top: 4, bottom: 18 })
    }
    .layoutWeight(1)
    .scrollBar(BarState.Off)
  }

  @Builder
  private statCard(title: string, value: number, color: string) {
    Column({ space: 3 }) {
      Text(`${value}`)
        .fontSize(21)
        .fontWeight(FontWeight.Bold)
        .fontColor(color)
      Text(title)
        .fontSize(11)
        .fontColor('#7D887D')
    }
    .layoutWeight(1)
    .padding({ top: 12, bottom: 12 })
    .backgroundColor('#FFFFFF')
    .borderRadius(15)
  }

  @Builder
  private recordCard(record: CropRecord) {
    Column({ space: 11 }) {
      Row({ space: 9 }) {
        Text(record.name.substring(0, 1))
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor('#FFFFFF')
          .width(36)
          .height(36)
          .textAlign(TextAlign.Center)
          .backgroundColor(`#${record.colorHex}`)
          .borderRadius(18)

        Column({ space: 2 }) {
          Text(record.name)
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor('#223127')
          Text(record.harvests.length > 1
            ? `${record.harvests.length} 次提醒 · 默认间隔 ${record.minutes} 分钟`
            : `提醒间隔 ${record.minutes} 分钟`)
            .fontSize(10)
            .fontColor('#899389')
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Button('编辑')
          .fontSize(11)
          .fontColor('#2F7545')
          .backgroundColor('#EEF5EC')
          .borderRadius(13)
          .onClick(() => this.beginEdit(record))
        Button('再提醒')
          .fontSize(11)
          .fontColor('#FFFFFF')
          .backgroundColor('#438652')
          .borderRadius(13)
          .onClick(() => this.renewRecord(record))
      }
      .width('100%')

      if (record.note !== undefined && record.note.length > 0) {
        Text(record.note)
          .fontSize(12)
          .fontColor('#707C70')
          .width('100%')
          .padding({ left: 45 })
      }

      ForEach([...record.harvests].sort((a: HarvestCycle, b: HarvestCycle) =>
        parseStoredDate(a.date).getTime() - parseStoredDate(b.date).getTime()),
      (cycle: HarvestCycle, index: number) => {
        this.cycleRow(record, cycle, index)
      }, (cycle: HarvestCycle) => cycle.id)

      Row() {
        Blank()
        Button('删除记录')
          .fontSize(11)
          .fontColor('#B85B4A')
          .backgroundColor('#FFF2EF')
          .borderRadius(13)
          .onClick(() => {
            this.pendingDeleteRecord = record;
          })
      }
      .width('100%')
    }
    .width('100%')
    .padding(15)
    .backgroundColor('#FFFFFF')
    .borderRadius(18)
  }

  @Builder
  private cycleRow(record: CropRecord, cycle: HarvestCycle, index: number) {
    Row({ space: 8 }) {
      Column({ space: 4 }) {
        Text(`第 ${index + 1} 次 · ${dateLabel(cycle.date)}`)
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.cycleColor(cycle))
        Text(this.cycleStatus(cycle))
          .fontSize(11)
          .fontColor(this.cycleColor(cycle))
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Button(cycle.harvested ? '撤销' : '已完成')
        .fontSize(11)
        .fontColor(cycle.harvested ? '#69756A' : '#2C7542')
        .backgroundColor(cycle.harvested ? '#F0F2EF' : '#EAF5E9')
        .borderRadius(13)
        .onClick(() => this.toggleCycle(record, cycle))
    }
    .width('100%')
    .padding({ left: 44, top: 3, bottom: 3 })
  }

  private cycleStatus(cycle: HarvestCycle): string {
    if (cycle.harvested) {
      return '已完成';
    }
    if (cycleIsDue(cycle, this.nowMillis)) {
      return '已到期';
    }
    return `还剩 ${remainingLabel(cycle.date, this.nowMillis)}`;
  }

  private cycleColor(cycle: HarvestCycle): string {
    if (cycle.harvested) {
      return '#438A55';
    }
    const remaining = parseStoredDate(cycle.date).getTime() - this.nowMillis;
    if (remaining <= 0) {
      return '#D77830';
    }
    if (remaining <= 10 * 60000) {
      return '#D64236';
    }
    if (remaining <= 20 * 60000) {
      return '#D97928';
    }
    if (remaining <= 30 * 60000) {
      return '#927015';
    }
    return '#6E796E';
  }

  private countReady(): number {
    return this.records.filter((record: CropRecord) =>
      record.harvests.length > 0 && recordIsClearable(record, this.nowMillis)).length;
  }

  private countPending(): number {
    return this.records.length - this.countReady();
  }

  private clearableCount(): number {
    return this.records.filter((record: CropRecord) =>
      recordIsClearable(record, this.nowMillis)).length;
  }

  private addRecord(): void {
    const preset = this.selectedPreset();
    const minutes = this.parsedMinutes();
    if (preset === undefined || minutes === undefined) {
      return;
    }
    const previousCount = this.records.length;
    const trimmedNote = this.note.trim();
    const record = CropStore.createRecord(preset, minutes, trimmedNote.length > 0 ? trimmedNote : undefined);
    this.refreshFromStore();
    this.note = '';
    if (this.records.length > previousCount) {
      this.showMessage(`已添加「${record.name}」记录。`);
    } else {
      this.showMessage('保存失败，请检查设备存储空间后重试。');
    }
  }

  private toggleCycle(record: CropRecord, cycle: HarvestCycle): void {
    if (!CropStore.toggleCycle(record.id, cycle.id)) {
      this.showMessage('更新失败，请稍后重试。');
      return;
    }
    this.refreshFromStore();
  }

  private renewRecord(record: CropRecord): void {
    if (!CropStore.renew(record)) {
      this.showMessage('续期失败，请稍后重试。');
      return;
    }
    this.refreshFromStore();
    this.showMessage(`已为「${record.name}」安排下一次提醒。`);
  }

  private beginEdit(record: CropRecord): void {
    this.editingRecord = JSON.parse(JSON.stringify(record)) as CropRecord;
    this.editName = record.name;
    this.editNote = record.note ?? '';
    this.editCycles = JSON.parse(JSON.stringify(record.harvests)) as HarvestCycle[];
    this.editCycles.sort((a: HarvestCycle, b: HarvestCycle) =>
      parseStoredDate(a.date).getTime() - parseStoredDate(b.date).getTime());
    this.expandedCycleID = '';
    this.addCycleAbsolute = false;
    this.addCycleHours = '1';
    this.addCycleMinutes = '0';
    this.addCycleDate = new Date(Date.now() + Math.max(1, record.minutes) * 60000);
  }

  private closeEdit(): void {
    this.editingRecord = undefined;
    this.expandedCycleID = '';
    this.pendingDeleteCycleID = '';
  }

  private saveEdit(): void {
    const original = this.editingRecord;
    if (original === undefined || this.editCycles.length === 0) {
      this.showMessage('至少保留一个提醒时间才能保存。');
      return;
    }
    const sorted = [...this.editCycles].sort((a: HarvestCycle, b: HarvestCycle) =>
      parseStoredDate(a.date).getTime() - parseStoredDate(b.date).getTime());
    const firstDate = parseStoredDate(sorted[0].date);
    const plantedAt = parseStoredDate(original.plantedAt);
    const updated: CropRecord = {
      id: original.id,
      name: this.editName.trim().length > 0 ? this.editName.trim() : original.name,
      colorHex: original.colorHex,
      minutes: Math.max(0, Math.floor((firstDate.getTime() - plantedAt.getTime()) / 60000)),
      plantedAt: original.plantedAt,
      harvests: sorted,
      note: this.editNote.trim().length > 0 ? this.editNote.trim() : undefined
    };
    if (!CropStore.updateRecord(updated)) {
      this.showMessage('保存失败，请稍后重试。');
      return;
    }
    this.closeEdit();
    this.refreshFromStore();
    this.showMessage('记录已更新。');
  }

  private updateCycleDate(cycleID: string, value: Date): void {
    const cycle = this.editCycles.find((item: HarvestCycle) => item.id === cycleID);
    if (cycle === undefined) {
      return;
    }
    const current = parseStoredDate(cycle.date);
    const next = new Date(
      value.getFullYear(),
      value.getMonth(),
      value.getDate(),
      current.getHours(),
      current.getMinutes(),
      0,
      0
    );
    this.editCycles = this.editCycles.map((item: HarvestCycle): HarvestCycle => {
      if (item.id !== cycleID) {
        return item;
      }
      return {
        id: item.id,
        date: next.toISOString(),
        harvested: item.harvested
      };
    });
  }

  private updateCycleTime(cycleID: string, value: TimePickerResult): void {
    const cycle = this.editCycles.find((item: HarvestCycle) => item.id === cycleID);
    if (cycle === undefined) {
      return;
    }
    const current = parseStoredDate(cycle.date);
    const next = new Date(
      current.getFullYear(),
      current.getMonth(),
      current.getDate(),
      value.hour ?? current.getHours(),
      value.minute ?? current.getMinutes(),
      0,
      0
    );
    this.editCycles = this.editCycles.map((item: HarvestCycle): HarvestCycle => {
      if (item.id !== cycleID) {
        return item;
      }
      return {
        id: item.id,
        date: next.toISOString(),
        harvested: item.harvested
      };
    });
  }

  private showCycleDatePicker(cycleID: string): void {
    const cycle = this.editCycles.find((item: HarvestCycle) => item.id === cycleID);
    if (cycle === undefined) {
      return;
    }
    this.getUIContext().showDatePickerDialog({
      selected: parseStoredDate(cycle.date),
      start: new Date(2000, 0, 1),
      end: new Date(2100, 11, 31),
      onDateAccept: (value: Date) => this.updateCycleDate(cycleID, value)
    });
  }

  private showCycleTimePicker(cycleID: string): void {
    const cycle = this.editCycles.find((item: HarvestCycle) => item.id === cycleID);
    if (cycle === undefined) {
      return;
    }
    this.getUIContext().showTimePickerDialog({
      selected: parseStoredDate(cycle.date),
      format: TimePickerFormat.HOUR_MINUTE,
      useMilitaryTime: true,
      onAccept: (value: TimePickerResult) => this.updateCycleTime(cycleID, value)
    });
  }

  private showAddCycleDatePicker(): void {
    this.getUIContext().showDatePickerDialog({
      selected: this.addCycleDate,
      start: new Date(2000, 0, 1),
      end: new Date(2100, 11, 31),
      onDateAccept: (value: Date) => {
        const current = this.addCycleDate;
        this.addCycleDate = new Date(
          value.getFullYear(),
          value.getMonth(),
          value.getDate(),
          current.getHours(),
          current.getMinutes()
        );
      }
    });
  }

  private showAddCycleTimePicker(): void {
    this.getUIContext().showTimePickerDialog({
      selected: this.addCycleDate,
      format: TimePickerFormat.HOUR_MINUTE,
      useMilitaryTime: true,
      onAccept: (value: TimePickerResult) => {
        this.addCycleDate = new Date(
          this.addCycleDate.getFullYear(),
          this.addCycleDate.getMonth(),
          this.addCycleDate.getDate(),
          value.hour,
          value.minute
        );
      }
    });
  }

  private clockLabel(date: Date): string {
    const pad = (value: number): string => value.toString().padStart(2, '0');
    return `${pad(date.getHours())}:${pad(date.getMinutes())}`;
  }

  private setCycleFromNow(cycleID: string): void {
    const hours = Number.parseInt(this.adjustHours.trim(), 10);
    const minutes = Number.parseInt(this.adjustMinutes.trim(), 10);
    if (!Number.isFinite(hours) || !Number.isFinite(minutes) || hours < 0 || minutes < 0 ||
        hours * 60 + minutes <= 0) {
      this.showMessage('请输入大于 0 的有效时长。');
      return;
    }
    const target = new Date(Date.now() + (hours * 60 + minutes) * 60000).toISOString();
    this.editCycles = this.editCycles.map((cycle: HarvestCycle): HarvestCycle => {
      if (cycle.id !== cycleID) {
        return cycle;
      }
      return {
        id: cycle.id,
        date: target,
        harvested: cycle.harvested
      };
    });
  }

  private addNextCycle(): void {
    let target: Date;
    if (this.addCycleAbsolute) {
      target = this.addCycleDate;
    } else {
      const hours = Number.parseInt(this.addCycleHours.trim(), 10);
      const minutes = Number.parseInt(this.addCycleMinutes.trim(), 10);
      if (!Number.isFinite(hours) || !Number.isFinite(minutes) || hours < 0 || minutes < 0 ||
          hours * 60 + minutes <= 0) {
        this.showMessage('请输入大于 0 的有效时长。');
        return;
      }
      target = new Date(Date.now() + (hours * 60 + minutes) * 60000);
    }
    if (target.getTime() <= Date.now()) {
      this.showMessage('新增提醒时间必须晚于现在。');
      return;
    }
    this.editCycles = [...this.editCycles, newCycle(target)].sort(
      (a: HarvestCycle, b: HarvestCycle) =>
        parseStoredDate(a.date).getTime() - parseStoredDate(b.date).getTime());
    this.addCycleDate = target;
  }

  private removeCycle(cycleID: string): void {
    this.editCycles = this.editCycles.filter((cycle: HarvestCycle) => cycle.id !== cycleID);
    this.pendingDeleteCycleID = '';
  }

  private addCustomPreset(): void {
    const name = this.newPresetName.trim();
    const minutes = Number.parseInt(this.newPresetMinutes.trim(), 10);
    if (name.length === 0 || !Number.isFinite(minutes) || minutes <= 0) {
      this.showMessage('请填写事项名称和大于 0 的提醒间隔（分钟）。');
      return;
    }
    const preset = CropStore.addCustomPreset(name, minutes);
    this.showAddPreset = false;
    this.refreshFromStore();
    this.selectedPresetID = preset.id;
    this.minutesText = `${preset.minutes}`;
    this.showMessage(`已添加模板「${preset.name}」。`);
  }

  private clearEnded(): void {
    if (!CropStore.clearEndedRecords(this.nowMillis)) {
      this.showMessage('清理失败，请稍后重试。');
      return;
    }
    this.showClearConfirmation = false;
    this.refreshFromStore();
    this.showMessage('已清理所有已结束或已到期的记录。');
  }

  private async uploadBackup(): Promise<void> {
    this.isUploading = true;
    try {
      const result = await BackupService.uploadCurrentBackup();
      this.lastUploadTimestamp = CropStore.lastUploadTimestamp();
      if (result.fileName === BackupService.backupFileName()) {
        this.showMessage(`上传成功：${result.fileName}，可从固定地址导入。`);
      } else {
        this.showMessage(
          `上传成功，但服务器将同名文件保存为 ${result.fileName}；固定地址仍指向旧文件。`
        );
      }
    } catch (error) {
      this.showMessage(`上传失败：${(error as Error).message}`);
    } finally {
      this.isUploading = false;
    }
  }

  private async importRemote(mode: ImportMode): Promise<void> {
    this.isImporting = true;
    const before = CropStore.records();
    try {
      const summary = await BackupService.importRemoteBackup(mode);
      this.refreshFromStore();
      const after = CropStore.records();
      this.showMessage(mode === ImportMode.MERGE && JSON.stringify(before) === JSON.stringify(after)
        ? `远程备份与本机记录一致（覆盖 ${summary.recordsOverwritten} 条）`
        : summary.text);
    } catch (error) {
      this.showMessage(`远程导入失败：${(error as Error).message}`);
    } finally {
      this.isImporting = false;
    }
  }

  private requestRemoteImport(): void {
    if (!BackupService.isAllowedRemoteURL(BackupService.remoteBackupURL())) {
      this.showMessage('请输入有效的 HTTPS 地址，或可信局域网共享目录地址。');
      return;
    }
    if (this.remoteImportMode === ImportMode.REPLACE) {
      this.showRemoteReplaceConfirmation = true;
    } else {
      this.importRemote(ImportMode.MERGE);
    }
  }

  private async saveBackupFile(): Promise<void> {
    if (this.context === undefined) {
      this.showMessage('当前页面尚未准备好，请稍后再试。');
      return;
    }
    try {
      const saved = await BackupService.exportBackupToFile(this.context);
      if (saved) {
        this.showMessage('备份文件已导出。');
      }
    } catch (error) {
      this.showMessage(`导出失败：${(error as Error).message}`);
    }
  }

  private async importBackupFile(): Promise<void> {
    if (this.context === undefined) {
      this.showMessage('当前页面尚未准备好，请稍后再试。');
      return;
    }
    try {
      const result = await BackupService.importBackupFromFile(this.context, ImportMode.MERGE);
      if (result !== undefined) {
        this.refreshFromStore();
        this.showMessage(result.text);
      }
    } catch (error) {
      this.showMessage(`文件导入失败：${(error as Error).message}`);
    }
  }

  @Builder
  private dataPage() {
    Scroll() {
      Column({ space: 15 }) {
        SectionCard({ title: '上传备份到共享目录', subtitle: '把当前记录和自定义模板上传到可信局域网' }) {
          Text(`上传文件名：${BackupService.backupFileName()}`)
            .fontSize(12)
            .fontColor('#69766A')
          Text('上传接口不会覆盖已有文件；同名时服务器会自动追加序号。')
            .fontSize(11)
            .fontColor('#8A958A')
          Button(this.isUploading ? '正在上传备份…' : '上传当前备份')
            .width('100%')
            .height(46)
            .fontSize(14)
            .fontWeight(FontWeight.Bold)
            .fontColor('#FFFFFF')
            .backgroundColor(this.isUploading ? '#9BB49E' : '#367B49')
            .borderRadius(14)
            .enabled(!this.isUploading)
            .onClick(() => this.uploadBackup())
          Text(this.lastUploadTimestamp > 0
            ? `最近上传：${dateLabel(new Date(this.lastUploadTimestamp))}`
            : '最近上传：暂无')
            .fontSize(11)
            .fontColor('#7D887D')
        }

        SectionCard({ title: '远程备份地址', subtitle: '手机和电脑都可以使用此地址下载备份' }) {
          Text(BackupService.remoteBackupURL())
            .fontSize(11)
            .fontColor('#42614A')
            .fontFamily('monospace')
            .textSelectable(TextSelectableMode.SELECTABLE_FOCUSABLE)
          Text('HTTP 局域网地址仅建议在可信网络内使用。')
            .fontSize(11)
            .fontColor('#9A815E')
        }

        SectionCard({ title: '获取并导入', subtitle: '选择合并或替换后，从远程备份地址读取数据' }) {
          Row({ space: 8 }) {
            Button('合并')
              .layoutWeight(1)
              .fontSize(13)
              .fontColor(this.remoteImportMode === ImportMode.MERGE ? '#FFFFFF' : '#55705A')
              .backgroundColor(this.remoteImportMode === ImportMode.MERGE ? '#367B49' : '#EEF3EC')
              .borderRadius(13)
              .onClick(() => {
                this.remoteImportMode = ImportMode.MERGE;
              })
            Button('替换')
              .layoutWeight(1)
              .fontSize(13)
              .fontColor(this.remoteImportMode === ImportMode.REPLACE ? '#FFFFFF' : '#55705A')
              .backgroundColor(this.remoteImportMode === ImportMode.REPLACE ? '#367B49' : '#EEF3EC')
              .borderRadius(13)
              .onClick(() => {
                this.remoteImportMode = ImportMode.REPLACE;
              })
          }
          Text(this.remoteImportMode === ImportMode.MERGE
            ? '同 ID 的记录和模板会更新，本机独有项目会保留。'
            : '本机记录、自定义模板和内置模板隐藏状态都会被备份覆盖。')
            .fontSize(11)
            .fontColor('#7D887D')
          Button(this.isImporting ? '正在下载并导入…' : '获取并导入')
            .width('100%')
            .height(46)
            .fontSize(14)
            .fontWeight(FontWeight.Bold)
            .fontColor('#FFFFFF')
            .backgroundColor('#367B49')
            .borderRadius(14)
            .enabled(!this.isImporting)
            .onClick(() => this.requestRemoteImport())
        }

        SectionCard({ title: '本地备份', subtitle: '导出 JSON 文件，或选择已有备份文件导入' }) {
          Row({ space: 9 }) {
            Button('导出 JSON')
              .layoutWeight(1)
              .fontSize(12)
              .fontColor('#2F7545')
              .backgroundColor('#EAF4E7')
              .borderRadius(13)
              .onClick(() => this.saveBackupFile())
            Button('导入 JSON')
              .layoutWeight(1)
              .fontSize(12)
              .fontColor('#2F7545')
              .backgroundColor('#EAF4E7')
              .borderRadius(13)
              .onClick(() => this.importBackupFile())
          }
        }

        SectionCard({ title: '运行中提示', subtitle: '元服务处于前台时检查到期和提前两分钟提示' }) {
          Text(this.notificationStatus)
            .fontSize(12)
            .fontColor('#647364')
          Text('元服务当前不支持后台定时通知。到期前和到期时会在页面运行期间显示短暂提示；退出后不会提醒。事项和倒计时会保存在本机，重新打开后会检查已到期事项。')
            .fontSize(11)
            .fontColor('#8A958A')
        }
      }
      .width('100%')
      .padding({ left: 18, right: 18, top: 4, bottom: 18 })
    }
    .layoutWeight(1)
    .scrollBar(BarState.Off)
  }

  @Builder
  private addPresetDialog() {
    Stack({ alignContent: Alignment.Center }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('#88000000')
        .onClick(() => {
          this.showAddPreset = false;
        })

      Column({ space: 14 }) {
        Text('添加自定义模板')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor('#233328')
          .width('100%')

        TextInput({ text: this.newPresetName, placeholder: '模板名称' })
          .fontSize(14)
          .backgroundColor('#F2F6F0')
          .borderRadius(12)
          .padding(12)
          .onChange((value: string) => {
            this.newPresetName = value;
          })
        Row({ space: 8 }) {
          TextInput({ text: this.newPresetMinutes, placeholder: '30' })
            .type(InputType.Number)
            .fontSize(14)
            .backgroundColor('#F2F6F0')
            .borderRadius(12)
            .padding(12)
            .layoutWeight(1)
            .onChange((value: string) => {
              this.newPresetMinutes = value;
            })
          Text('分钟')
            .fontSize(13)
            .fontColor('#718071')
        }
        Row({ space: 9 }) {
          Button('取消')
            .layoutWeight(1)
            .fontColor('#576657')
            .backgroundColor('#EEF2ED')
            .borderRadius(13)
            .onClick(() => {
              this.showAddPreset = false;
            })
          Button('添加')
            .layoutWeight(1)
            .fontColor('#FFFFFF')
            .backgroundColor('#367B49')
            .borderRadius(13)
            .onClick(() => this.addCustomPreset())
        }
      }
      .width('90%')
      .padding(20)
      .backgroundColor('#FFFFFF')
      .borderRadius(20)
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  private editRecordDialog() {
    Column() {
      Column({ space: 10 }) {
        Row() {
          Text('编辑记录')
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .fontColor('#233328')
          Blank()
          Button('关闭')
            .fontSize(12)
            .fontColor('#687568')
            .backgroundColor('#F0F3EF')
            .borderRadius(13)
            .onClick(() => this.closeEdit())
        }
        .width('100%')

        Scroll() {
          Column({ space: 14 }) {
            TextInput({ text: this.editName, placeholder: '事项名称' })
              .fontSize(14)
              .backgroundColor('#F2F6F0')
              .borderRadius(12)
              .padding(12)
              .onChange((value: string) => {
                this.editName = value;
              })

            TextArea({ text: this.editNote, placeholder: '备注说明' })
              .fontSize(13)
              .backgroundColor('#F2F6F0')
              .borderRadius(12)
              .height(78)
              .padding(12)
              .onChange((value: string) => {
                this.editNote = value;
              })

            Text(`提醒时间（${this.editCycles.length} 次）`)
              .fontSize(14)
              .fontWeight(FontWeight.Bold)
              .fontColor('#344535')
              .width('100%')

            ForEach(this.editCycles, (cycle: HarvestCycle, index: number) => {
              this.editCycleCard(cycle, index)
            }, (cycle: HarvestCycle) => cycle.id)

            this.addCycleSection()
          }
          .width('100%')
          .padding({ bottom: 12 })
        }
        .layoutWeight(1)
        .scrollBar(BarState.Off)

        Row({ space: 9 }) {
          Button('取消')
            .layoutWeight(1)
            .height(44)
            .fontColor('#586658')
            .backgroundColor('#EEF2ED')
            .borderRadius(13)
            .onClick(() => this.closeEdit())
          Button('保存')
            .layoutWeight(1)
            .height(44)
            .fontWeight(FontWeight.Bold)
            .fontColor('#FFFFFF')
            .backgroundColor('#367B49')
            .enabled(this.editCycles.length > 0)
            .borderRadius(13)
            .onClick(() => this.saveEdit())
        }
        .width('100%')
      }
      .width('94%')
      .height('88%')
      .padding(18)
      .backgroundColor('#FFFFFF')
      .borderRadius(22)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor('#88000000')
  }

  @Builder
  private editCycleCard(cycle: HarvestCycle, index: number) {
    Column({ space: 9 }) {
      Row() {
        Column({ space: 3 }) {
          Text(`第 ${index + 1} 次`)
            .fontSize(13)
            .fontWeight(FontWeight.Bold)
            .fontColor('#26372A')
          Text(cycle.harvested
            ? '已完成'
            : (cycleIsDue(cycle, this.nowMillis)
              ? '已到期'
              : `还剩 ${remainingLabel(cycle.date, this.nowMillis)}`))
            .fontSize(11)
            .fontColor(cycle.harvested ? '#438A55' : (cycleIsDue(cycle, this.nowMillis) ? '#D77830' : '#798579'))
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        Button(cycle.harvested ? '撤销完成' : '标记完成')
          .fontSize(10)
          .fontColor('#34794A')
          .backgroundColor('#EAF4E7')
          .borderRadius(12)
          .onClick(() => {
            this.editCycles = this.editCycles.map((item: HarvestCycle): HarvestCycle => {
              if (item.id !== cycle.id) {
                return item;
              }
              return {
                id: item.id,
                date: item.date,
                harvested: !item.harvested
              };
            });
          })
        Button('删除')
          .fontSize(10)
          .fontColor('#B85B4A')
          .backgroundColor('#FFF1EE')
          .borderRadius(12)
          .onClick(() => {
            this.pendingDeleteCycleID = cycle.id;
          })
      }
      .width('100%')

      Text(dateLabel(cycle.date))
        .fontSize(12)
        .fontColor('#647264')
        .width('100%')

      Button(this.expandedCycleID === cycle.id ? '收起时间编辑' : '编辑提醒时间')
        .fontSize(11)
        .fontColor('#37774A')
        .backgroundColor('#EDF5EA')
        .borderRadius(12)
        .onClick(() => {
          if (this.expandedCycleID === cycle.id) {
            this.expandedCycleID = '';
          } else {
            this.expandedCycleID = cycle.id;
            const diff = Math.max(0, parseStoredDate(cycle.date).getTime() - Date.now());
            const totalMinutes = Math.floor(diff / 60000);
            this.adjustHours = `${Math.floor(totalMinutes / 60)}`;
            this.adjustMinutes = `${totalMinutes % 60}`;
          }
        })

      if (this.expandedCycleID === cycle.id) {
        Column({ space: 8 }) {
          Button(`选择日期 · ${dateLabel(cycle.date)}`)
            .width('100%')
            .fontSize(11)
            .fontColor('#37774A')
            .backgroundColor('#EDF5EA')
            .borderRadius(12)
            .onClick(() => this.showCycleDatePicker(cycle.id))
          Button(`选择时间 · ${this.clockLabel(parseStoredDate(cycle.date))}`)
            .width('100%')
            .fontSize(11)
            .fontColor('#37774A')
            .backgroundColor('#EDF5EA')
            .borderRadius(12)
            .onClick(() => this.showCycleTimePicker(cycle.id))

          Text('或从现在起调整')
            .fontSize(11)
            .fontWeight(FontWeight.Medium)
            .fontColor('#667366')
          Row({ space: 6 }) {
            TextInput({ text: this.adjustHours, placeholder: '1' })
              .type(InputType.Number)
              .fontSize(12)
              .backgroundColor('#F3F6F2')
              .borderRadius(9)
              .padding(9)
              .layoutWeight(1)
              .onChange((value: string) => {
                this.adjustHours = value;
              })
            Text('小时')
              .fontSize(10)
              .fontColor('#7A867A')
            TextInput({ text: this.adjustMinutes, placeholder: '0' })
              .type(InputType.Number)
              .fontSize(12)
              .backgroundColor('#F3F6F2')
              .borderRadius(9)
              .padding(9)
              .layoutWeight(1)
              .onChange((value: string) => {
                this.adjustMinutes = value;
              })
            Text('分钟')
              .fontSize(10)
              .fontColor('#7A867A')
          }
          Button('按此时长设置')
            .fontSize(11)
            .fontColor('#FFFFFF')
            .backgroundColor('#438652')
            .borderRadius(11)
            .onClick(() => this.setCycleFromNow(cycle.id))
        }
        .width('100%')
        .padding(10)
        .backgroundColor('#F8FAF7')
        .borderRadius(12)
      }
    }
    .width('100%')
    .padding(12)
    .backgroundColor('#F7F9F6')
    .borderRadius(15)
  }

  @Builder
  private addCycleSection() {
    Column({ space: 9 }) {
      Text('添加下一次提醒')
        .fontSize(14)
        .fontWeight(FontWeight.Bold)
        .fontColor('#344535')
        .width('100%')
      Row({ space: 8 }) {
        Button('从现在起')
          .layoutWeight(1)
          .fontSize(11)
          .fontColor(!this.addCycleAbsolute ? '#FFFFFF' : '#55705A')
          .backgroundColor(!this.addCycleAbsolute ? '#367B49' : '#EEF3EC')
          .borderRadius(12)
          .onClick(() => {
            this.addCycleAbsolute = false;
          })
        Button('指定时间')
          .layoutWeight(1)
          .fontSize(11)
          .fontColor(this.addCycleAbsolute ? '#FFFFFF' : '#55705A')
          .backgroundColor(this.addCycleAbsolute ? '#367B49' : '#EEF3EC')
          .borderRadius(12)
          .onClick(() => {
            this.addCycleAbsolute = true;
          })
      }
      .width('100%')

      if (this.addCycleAbsolute) {
        Button(`选择日期 · ${dateLabel(this.addCycleDate)}`)
          .width('100%')
          .fontSize(11)
          .fontColor('#37774A')
          .backgroundColor('#EDF5EA')
          .borderRadius(12)
          .onClick(() => this.showAddCycleDatePicker())
        Button(`选择时间 · ${this.clockLabel(this.addCycleDate)}`)
          .width('100%')
          .fontSize(11)
          .fontColor('#37774A')
          .backgroundColor('#EDF5EA')
          .borderRadius(12)
          .onClick(() => this.showAddCycleTimePicker())
      } else {
        Row({ space: 7 }) {
          TextInput({ text: this.addCycleHours, placeholder: '1' })
            .type(InputType.Number)
            .fontSize(12)
            .backgroundColor('#F3F6F2')
            .borderRadius(9)
            .padding(9)
            .layoutWeight(1)
            .onChange((value: string) => {
              this.addCycleHours = value;
            })
          Text('小时')
            .fontSize(10)
            .fontColor('#7A867A')
          TextInput({ text: this.addCycleMinutes, placeholder: '0' })
            .type(InputType.Number)
            .fontSize(12)
            .backgroundColor('#F3F6F2')
            .borderRadius(9)
            .padding(9)
            .layoutWeight(1)
            .onChange((value: string) => {
              this.addCycleMinutes = value;
            })
          Text('分钟')
            .fontSize(10)
            .fontColor('#7A867A')
        }
        Text(`预计提醒：${dateLabel(this.addCyclePreview())}`)
          .fontSize(11)
          .fontColor('#7E897E')
          .width('100%')
      }

      Button('添加这一次提醒')
        .width('100%')
        .height(40)
        .fontSize(12)
        .fontWeight(FontWeight.Medium)
        .fontColor('#34794A')
        .backgroundColor('#EAF4E7')
        .borderRadius(12)
        .onClick(() => this.addNextCycle())
    }
    .width('100%')
    .padding(13)
    .backgroundColor('#FFFFFF')
    .borderRadius(15)
  }

  private addCyclePreview(): Date {
    const hours = Number.parseInt(this.addCycleHours, 10);
    const minutes = Number.parseInt(this.addCycleMinutes, 10);
    if (!Number.isFinite(hours) || !Number.isFinite(minutes) || hours < 0 || minutes < 0) {
      return new Date(Date.now());
    }
    return new Date(Date.now() + (hours * 60 + minutes) * 60000);
  }

  @Builder
  private deleteRecordDialog() {
    Column() {
      Column({ space: 12 }) {
        Text(`删除「${this.pendingDeleteRecord?.name ?? ''}」？`)
          .fontSize(17)
          .fontWeight(FontWeight.Bold)
          .fontColor('#26372A')
          .width('100%')
        Text(this.deleteRecordMessage())
          .fontSize(12)
          .fontColor('#6E796E')
          .width('100%')
        Row({ space: 8 }) {
          Button('取消')
            .layoutWeight(1)
            .fontColor('#596659')
            .backgroundColor('#EEF2ED')
            .borderRadius(12)
            .onClick(() => {
              this.pendingDeleteRecord = undefined;
            })
          Button('删除')
            .layoutWeight(1)
            .fontColor('#FFFFFF')
            .backgroundColor('#C94C3A')
            .borderRadius(12)
            .onClick(() => this.confirmDeleteRecord())
        }
      }
      .width('88%')
      .padding(20)
      .backgroundColor('#FFFFFF')
      .borderRadius(18)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor('#88000000')
  }

  private deleteRecordMessage(): string {
    const record = this.pendingDeleteRecord;
    if (record === undefined) {
      return '';
    }
    const count = record.harvests.length;
    if (count <= 1) {
      return `提醒时间：${record.harvests[0] !== undefined ? dateLabel(record.harvests[0].date) : '未设置'}。此操作不可撤销。`;
    }
    const harvested = record.harvests.filter((cycle: HarvestCycle) => cycle.harvested).length;
    const next = record.harvests
      .filter((cycle: HarvestCycle) => !cycle.harvested &&
        parseStoredDate(cycle.date).getTime() > this.nowMillis)
      .map((cycle: HarvestCycle) => parseStoredDate(cycle.date).getTime())
      .sort((a: number, b: number) => a - b)[0];
    return `共 ${count} 次，已完成 ${harvested} 次。下次提醒：${next !== undefined ? dateLabel(new Date(next)) : '无'}。此操作不可撤销。`;
  }

  private confirmDeleteRecord(): void {
    const record = this.pendingDeleteRecord;
    if (record === undefined) {
      return;
    }
    if (!CropStore.deleteRecord(record.id)) {
      this.showMessage('删除失败，请稍后重试。');
      return;
    }
    this.pendingDeleteRecord = undefined;
    this.refreshFromStore();
    this.showMessage('记录已删除。');
  }

  @Builder
  private deleteCycleDialog() {
    Column() {
      Column({ space: 12 }) {
        Text('删除这一次提醒？')
          .fontSize(17)
          .fontWeight(FontWeight.Bold)
          .fontColor('#26372A')
          .width('100%')
        Text(this.deleteCycleMessage())
          .fontSize(12)
          .fontColor('#6E796E')
          .width('100%')
        Row({ space: 8 }) {
          Button('取消')
            .layoutWeight(1)
            .fontColor('#596659')
            .backgroundColor('#EEF2ED')
            .borderRadius(12)
            .onClick(() => {
              this.pendingDeleteCycleID = '';
            })
          Button('删除')
            .layoutWeight(1)
            .fontColor('#FFFFFF')
            .backgroundColor('#C94C3A')
            .borderRadius(12)
            .onClick(() => this.removeCycle(this.pendingDeleteCycleID))
        }
      }
      .width('88%')
      .padding(20)
      .backgroundColor('#FFFFFF')
      .borderRadius(18)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor('#88000000')
  }

  private deleteCycleMessage(): string {
    const cycle = this.editCycles.find((item: HarvestCycle) => item.id === this.pendingDeleteCycleID);
    if (cycle === undefined) {
      return '';
    }
    const remaining = this.editCycles.length - 1;
    return remaining === 0
      ? `提醒时间 ${dateLabel(cycle.date)}。这是唯一一次提醒，删除后需要重新添加才能保存。`
      : `提醒时间 ${dateLabel(cycle.date)}。删除后还剩 ${remaining} 次。`;
  }

  @Builder
  private clearConfirmationDialog() {
    Column() {
      Column({ space: 12 }) {
        Text('清理已结束或已到提醒时间的记录？')
          .fontSize(17)
          .fontWeight(FontWeight.Bold)
          .fontColor('#26372A')
          .width('100%')
        Text('仅清理所有提醒均已完成或已到期的记录；仍有未来提醒时间的记录会保留。')
          .fontSize(12)
          .fontColor('#6E796E')
          .width('100%')
        Row({ space: 8 }) {
          Button('取消')
            .layoutWeight(1)
            .fontColor('#596659')
            .backgroundColor('#EEF2ED')
            .borderRadius(12)
            .onClick(() => {
              this.showClearConfirmation = false;
            })
          Button('清除')
            .layoutWeight(1)
            .fontColor('#FFFFFF')
            .backgroundColor('#C94C3A')
            .borderRadius(12)
            .onClick(() => this.clearEnded())
        }
      }
      .width('88%')
      .padding(20)
      .backgroundColor('#FFFFFF')
      .borderRadius(18)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor('#88000000')
  }

  @Builder
  private remoteReplaceDialog() {
    Column() {
      Column({ space: 12 }) {
        Text('用远程备份替换本机数据？')
          .fontSize(17)
          .fontWeight(FontWeight.Bold)
          .fontColor('#26372A')
          .width('100%')
        Text('当前提醒记录、自定义模板和内置模板隐藏状态将被远程备份覆盖。')
          .fontSize(12)
          .fontColor('#6E796E')
          .width('100%')
        Row({ space: 8 }) {
          Button('取消')
            .layoutWeight(1)
            .fontColor('#596659')
            .backgroundColor('#EEF2ED')
            .borderRadius(12)
            .onClick(() => {
              this.showRemoteReplaceConfirmation = false;
            })
          Button('下载并替换')
            .layoutWeight(1)
            .fontSize(11)
            .fontColor('#FFFFFF')
            .backgroundColor('#C94C3A')
            .borderRadius(12)
            .onClick(() => {
              this.showRemoteReplaceConfirmation = false;
              this.importRemote(ImportMode.REPLACE);
            })
        }
      }
      .width('88%')
      .padding(20)
      .backgroundColor('#FFFFFF')
      .borderRadius(18)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor('#88000000')
  }
}

@Component
struct SectionCard {
  @Prop title: string = '';
  @Prop subtitle: string = '';
  @BuilderParam content: () => void = this.emptyContent;

  @Builder
  private emptyContent() {}

  build() {
    Column({ space: 12 }) {
      Column({ space: 4 }) {
        Text(this.title)
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor('#203026')
        Text(this.subtitle)
          .fontSize(11)
          .fontColor('#859085')
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)

      this.content()
    }
    .width('100%')
    .padding(16)
    .backgroundColor('#FFFFFF')
    .borderRadius(18)
  }
}
