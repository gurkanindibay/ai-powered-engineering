import { Page } from 'playwright';
import Decimal from 'decimal.js';
import { byId, textOf } from '../support/flutter';
import { lastAmount } from '../support/money';

export class ImportSummary {
  constructor(public readonly page: Page) {}

  async wait(): Promise<this> {
    await byId(this.page, 'import_summary_matched').waitFor({ timeout: 15000 });
    return this;
  }

  async matched(): Promise<[number, Decimal]> {
    const text = await textOf(byId(this.page, 'import_summary_matched'));
    const countStr = text.split('(')[1]?.split(')')[0] || '0';
    return [parseInt(countStr, 10), lastAmount(text)];
  }
}
