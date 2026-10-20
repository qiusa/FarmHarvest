import { UIAbility, Want } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';

export default class EntryAbility extends UIAbility {
  onCreate(_want: Want): void {
    // App data and reminders are initialized by the entry page when it becomes visible.
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/Index', (error) => {
      if (error.code) {
        console.error(`Failed to load the main page: ${error.message}`);
      }
    });
  }
}
