import { defineParameterType, Given, When, Then } from '@cucumber/cucumber';
import assert from 'assert';
import Decimal from 'decimal.js';
import crypto from 'crypto';
import { CustomWorld } from '../support/custom_world';
import { CapitalProjects } from '../pages/capital_projects';
import { DuesManagement } from '../pages/dues_management';
import { ManagerCockpit } from '../pages/manager_cockpit';
import { byId, fill, textOf } from '../support/flutter';
import { parseDecimal } from '../support/money';
import { querySql, waitSql } from '../support/stack';
import { VIRTUAL_IBANS } from '../support/api';

const CENT = new Decimal('0.01');
const ACTIVE_UNITS = 'FROM units WHERE site_id = 1 AND deleted_at IS NULL';

defineParameterType({
  name: 'money',
  regexp: /[+-]?(?:\d+(?:\.\d+)?|\.\d+)/,
  transformer: (amount: string) => new Decimal(amount),
});

let capitalProjectsPage: CapitalProjects;

// -- SC-10-01-01 Steps --------------------------------------------------------

Given('the site manager opens the capital projects segment', async function (this: CustomWorld) {
  await this.loginAs('manager');
  await new ManagerCockpit(this.page!).wait();
  capitalProjectsPage = new CapitalProjects(this.page!);
  await capitalProjectsPage.open();
});

When(
  'the manager creates capital project {string} with budget {string} allocated {word} in {int} installments',
  async function (this: CustomWorld, title: string, budgetStr: string, basisStr: string, installments: number) {
    const budget = parseDecimal(budgetStr);
    const byLandShare = basisStr.includes('land') || basisStr.includes('share');
    await capitalProjectsPage.create(title, budget.toFixed(2), byLandShare, installments);
  }
);

When(
  'the manager creates capital project {string} with budget {money} allocated by land share in {int} installments',
  async function (this: CustomWorld, title: string, budget: Decimal, installments: number) {
    await capitalProjectsPage.create(title, budget.toFixed(2), true, installments);
  }
);

Then(
  'the project is stored as {string} with budget {money} and allocation {string}',
  async function (this: CustomWorld, status: string, budget: Decimal, basis: string) {
    const row = await waitSql(
      'SELECT status || \'|\' || total_budget || \'|\' || allocation_basis FROM capital_projects;',
      `${status}|${budget.toFixed(2)}|${basis}`
    );
    assert.strictEqual(row, `${status}|${budget.toFixed(2)}|${basis}`);
  }
);

Then(
  'the unit shares shown add up to exactly {money}',
  async function (this: CustomWorld, budget: Decimal) {
    await capitalProjectsPage.showUnitShares();
    const shares = await capitalProjectsPage.unitShareTexts();
    const sum = Object.values(shares).reduce((acc, val) => acc.plus(val), new Decimal(0));
    assert.strictEqual(sum.toFixed(2), budget.toFixed(2));
  }
);

Then(
  'unit {string} is shown its land share proportion of {money}',
  async function (this: CustomWorld, unit: string, budget: Decimal) {
    const rows = (await querySql(`SELECT unit_number, land_share ${ACTIVE_UNITS};`)).split('\n');
    const land: Record<string, Decimal> = {};
    let totalLand = new Decimal(0);
    for (const r of rows) {
      if (!r.trim()) continue;
      const [u, s] = r.split('|');
      const share = new Decimal(s);
      land[u] = share;
      totalLand = totalLand.plus(share);
    }
    const expected = budget.times(land[unit]).dividedBy(totalLand).toDecimalPlaces(2, Decimal.ROUND_HALF_UP);
    const shares = await capitalProjectsPage.unitShareTexts();
    assert.strictEqual(shares[unit]?.toFixed(2), expected.toFixed(2));
  }
);

// -- SC-10-04-01 Steps --------------------------------------------------------

Given(
  'the owner of unit {word} has paid {money} by FAST with description {string}',
  async function (this: CustomWorld, unit: string, amount: Decimal, description: string) {
    const iban = VIRTUAL_IBANS[unit];
    assert.ok(iban, `Unknown unit virtual IBAN for ${unit}`);
    const txId = `E2E-FAST-${crypto.randomBytes(5).toString('hex')}`;
    await this.api.webhookTransfer(iban, amount, txId, description);
  }
);

When('the site manager opens the virman dialog in dues management', async function (this: CustomWorld) {
  await this.loginAs('manager');
  await new ManagerCockpit(this.page!).wait();
  const dues = new DuesManagement(this.page!);
  await dues.open();
  await byId(this.page!, 'btn_dues_more_actions').click();
  await byId(this.page!, 'menu_item_virman').click();
});

Then(
  'the virman unit list shows an advance of {string}',
  async function (this: CustomWorld, formatted: string) {
    const dropdown = byId(this.page!, 'virman_unit_dropdown');
    await dropdown.waitFor({ timeout: 10000 });
    const text = await textOf(dropdown);
    assert.ok(text.includes(formatted), `expected ${formatted} in dropdown text: ${text}`);
  }
);

// -- SC-10-04-02 Steps --------------------------------------------------------

Given(
  'unit {word} has an advance balance of {money} and an accrued capital due of {money}',
  async function (this: CustomWorld, unit: string, advance: Decimal, due: Decimal) {
    const iban = VIRTUAL_IBANS[unit] || VIRTUAL_IBANS[`A${unit}`];
    assert.ok(iban, `Virtual IBAN missing for unit ${unit}`);
    const txId = `E2E-FAST-${crypto.randomBytes(5).toString('hex')}`;
    await this.api.webhookTransfer(iban, advance, txId, 'AHMET YILMAZ AVANS');

    const manager = await this.api.login(this.actors.manager.email, this.actors.manager.password);
    // 2 units in the site: total budget = due * 2 so each unit owes exactly `due`
    const totalBudget = due.times(2);
    const project = await this.api.createCapitalProject(
      manager.token,
      manager.user.site_id,
      'Çatı İzolasyonu',
      totalBudget,
      'EQUAL_PER_UNIT',
      1
    );
    const projId = project.id || project.project_id;
    await this.api.accrueInstallment(manager.token, manager.user.site_id, projId, 1);
  }
);

When(
  'the site manager executes a virman transfer of {money} to the capital project',
  async function (this: CustomWorld, amount: Decimal) {
    await this.loginAs('manager');
    await new ManagerCockpit(this.page!).wait();
    const dues = new DuesManagement(this.page!);
    await dues.open();
    await byId(this.page!, 'btn_dues_more_actions').click();
    await byId(this.page!, 'menu_item_virman').click();
    await byId(this.page!, 'virman_unit_dropdown').waitFor({ timeout: 10000 });
    await fill(this.page!, 'virman_amount_input', amount.toFixed(2));
    await byId(this.page!, 'btn_confirm_virman').click();
    await byId(this.page!, 'btn_confirm_virman').waitFor({ state: 'detached', timeout: 15000 });
  }
);

Then(
  'the advance balance of unit {word} decreases to {money}',
  async function (this: CustomWorld, unit: string, expected: Decimal) {
    const val = await waitSql(
      `SELECT balance FROM advance_balances WHERE unit_id = (SELECT id FROM units WHERE unit_number = ${parseInt(unit, 10)}) AND debtor_type = 'OWNER';`,
      expected.toFixed(2),
      10000
    );
    assert.strictEqual(new Decimal(val).toFixed(2), expected.toFixed(2));
  }
);

Then('the capital dues liability is fully paid', async function (this: CustomWorld) {
  const val = await waitSql(
    "SELECT status FROM dues_liabilities WHERE unit_id = (SELECT id FROM units WHERE unit_number = 14) AND expense_type = 'CAPITAL_DUES';",
    'PAID',
    10000
  );
  assert.strictEqual(val, 'PAID');
});

Then('an inter-ledger audit record is stored in collection_transactions', async function (this: CustomWorld) {
  const cnt = await waitSql(
    "SELECT count(*)::text FROM payment_entries WHERE payment_channel = 'INTER_LEDGER';",
    '1',
    10000
  );
  assert.strictEqual(cnt, '1');
});
