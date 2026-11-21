import { Page } from 'playwright';
import Decimal from 'decimal.js';
import { byId, byIdPrefix, fill, textOf } from '../support/flutter';
import { lastAmount } from '../support/money';
import { DuesManagement } from './dues_management';

export class CapitalProjects {
  constructor(public readonly page: Page) {}

  async open(): Promise<this> {
    const dues = new DuesManagement(this.page);
    await dues.open();
    await dues.segment(DuesManagement.CAPITAL_SEGMENT);
    await byId(this.page, 'btn_open_capital_project_wizard').waitFor({ timeout: 15000 });
    return this;
  }

  async create(title: string, budget: string, byLandShare = true, installments = 1): Promise<void> {
    await byId(this.page, 'btn_open_capital_project_wizard').click();
    await byId(this.page, 'input_capital_project_title').waitFor({ timeout: 10000 });
    await fill(this.page, 'input_capital_project_title', title);
    await fill(this.page, 'input_capital_project_budget', budget);
    await byId(this.page, byLandShare ? 'radio_allocation_by_land_share' : 'radio_allocation_equal').click();
    await byId(this.page, `chip_installments_${installments}`).click();
    await byId(this.page, 'btn_submit_capital_project').click();
    await byIdPrefix(this.page, 'project_tab_').first().waitFor({ timeout: 15000 });
  }

  async showUnitShares(): Promise<this> {
    await byId(this.page, 'subtab_button_1').click();
    await byIdPrefix(this.page, 'unit_share_').first().waitFor({ timeout: 10000 });
    return this;
  }

  async unitShareTexts(): Promise<Record<string, Decimal>> {
    const ids: string[] = await this.page.$$eval(
      '[flt-semantics-identifier^="unit_share_"]',
      (els: Element[]) => els.map(e => e.getAttribute('flt-semantics-identifier') || '').filter(Boolean)
    );
    const result: Record<string, Decimal> = {};
    for (const id of ids) {
      const text = await textOf(byId(this.page, id));
      const key = id.substring(id.lastIndexOf('_') + 1);
      result[key] = lastAmount(text);
    }
    return result;
  }
}
