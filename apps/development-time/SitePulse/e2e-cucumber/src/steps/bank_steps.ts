import { Given, When, Then } from '@cucumber/cucumber';
import assert from 'assert';
import AdmZip from 'adm-zip';
import * as fs from 'fs';
import * as path from 'path';
import * as os from 'os';
import { CustomWorld } from '../support/custom_world';
import { DuesManagement } from '../pages/dues_management';
import { ImportSummary } from '../pages/import_summary';
import { ManagerCockpit } from '../pages/manager_cockpit';
import { byId, byIdPrefix } from '../support/flutter';
import { querySql } from '../support/stack';

const EXCEL_BANKS: Record<string, string> = {
  KUVEYT_TURK: 'Kuveyt Türk Katılım Bankası',
  YAPI_KREDI: 'Yapı Kredi Bankası',
};

let currentBankCode = '';
let currentBankName = '';

Given(
  'the supported-bank catalogue contains bank {string} with format {string}',
  async function (this: CustomWorld, bankCode: string, format: string) {
    assert.strictEqual(format, 'EXCEL');
    assert.ok(bankCode in EXCEL_BANKS, `Bank ${bankCode} not catalogued with format EXCEL`);
    currentBankCode = bankCode;
    currentBankName = EXCEL_BANKS[bankCode];
  }
);

Given('the manager opens Excel \\/ statement upload', async function (this: CustomWorld) {
  await this.loginAs('manager');
  await new ManagerCockpit(this.page!).wait();
  const dues = new DuesManagement(this.page!);
  await dues.open();
  await byId(this.page!, 'btn_open_bank_import').click();
});

When('the sample workbook options are displayed', async function (this: CustomWorld) {
  await byIdPrefix(this.page!, 'btn_download_bank_sample_').first().waitFor({ timeout: 10000 });
});

Then(
  'a downloadable sample workbook is shown for {string}',
  async function (this: CustomWorld, bankName: string) {
    const code = currentBankCode.toLowerCase();
    const btn = byId(this.page!, `btn_download_bank_sample_${code}`);
    await btn.waitFor({ timeout: 10000 });
    assert.strictEqual(await btn.count(), 1);
  }
);

Then(
  'the downloaded workbook is a valid Excel file with fictional transaction rows',
  async function (this: CustomWorld) {
    const code = currentBankCode.toLowerCase();
    const [download] = await Promise.all([
      this.page!.waitForEvent('download'),
      byId(this.page!, `btn_download_bank_sample_${code}`).click(),
    ]);

    const filename = download.suggestedFilename();
    assert.strictEqual(filename, `${code}_ornek_ekstre.xlsx`);

    const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'e2e-cucumber-'));
    const savedPath = path.join(tmpDir, filename);
    await download.saveAs(savedPath);
    this.downloadedSamplePath = savedPath;

    const zip = new AdmZip(savedPath);
    const sharedStrings = zip.readAsText('xl/sharedStrings.xml');
    const worksheet = zip.readAsText('xl/worksheets/sheet1.xml');

    assert.ok(sharedStrings.includes(currentBankName), `expected ${currentBankName} in sharedStrings`);
    assert.ok(sharedStrings.includes(`SAMPLE-${currentBankCode}-001`), `expected SAMPLE-${currentBankCode}-001 in sharedStrings`);
    assert.ok(sharedStrings.includes('Z BLOK D:999'), 'expected Z BLOK D:999 in sharedStrings');
    assert.ok(sharedStrings.includes('0,01'), 'expected 0,01 in sharedStrings');
    assert.ok(worksheet.includes('r="E17"'), 'expected r="E17" in worksheet');
  }
);

Then(
  'uploading the sample does not settle or mutate real dues',
  async function (this: CustomWorld) {
    assert.ok(this.downloadedSamplePath, 'no downloaded sample path');
    const paymentsBefore = await querySql('SELECT count(*)::text FROM payment_entries;');
    const paidBefore = await querySql('SELECT coalesce(sum(paid_amount), 0)::text FROM dues_liabilities;');

    const [fileChooser] = await Promise.all([
      this.page!.waitForEvent('filechooser'),
      byId(this.page!, 'btn_import_pick_file').click(),
    ]);

    await fileChooser.setFiles(this.downloadedSamplePath);
    const summary = new ImportSummary(this.page!);
    await summary.wait();
    const [matchedCount] = await summary.matched();
    assert.strictEqual(matchedCount, 0);

    const paymentsAfter = await querySql('SELECT count(*)::text FROM payment_entries;');
    const paidAfter = await querySql('SELECT coalesce(sum(paid_amount), 0)::text FROM dues_liabilities;');

    assert.strictEqual(paymentsAfter, paymentsBefore);
    assert.strictEqual(paidAfter, paidBefore);
  }
);
