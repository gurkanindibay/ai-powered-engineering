import { Page } from 'playwright';
import { byId } from '../support/flutter';

export class ManagerCockpit {
  constructor(public readonly page: Page) {}

  async wait(): Promise<this> {
    await byId(this.page, 'btn_open_unified_dues_center').waitFor({ timeout: 20000 });
    return this;
  }
}
