import { Page } from 'playwright';
import { byId } from '../support/flutter';

export class DuesManagement {
  static readonly CAPITAL_SEGMENT = 4;

  constructor(public readonly page: Page) {}

  async open(): Promise<this> {
    await byId(this.page, 'nav_dues').click();
    await byId(this.page, 'segment_tab_0').waitFor({ timeout: 15000 });
    return this;
  }

  async segment(index: number): Promise<this> {
    await byId(this.page, `segment_tab_${index}`).click();
    return this;
  }
}
