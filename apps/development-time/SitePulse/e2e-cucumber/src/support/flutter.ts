import { Locator, Page } from 'playwright';

export const ID_ATTR = 'flt-semantics-identifier';

export function byId(page: Page, testId: string): Locator {
  return page.locator(`[${ID_ATTR}="${testId}"]`);
}

export function byIdPrefix(page: Page, prefix: string): Locator {
  return page.locator(`[${ID_ATTR}^="${prefix}"]`);
}

export async function waitForApp(page: Page, timeoutMs = 30000): Promise<void> {
  await page.waitForSelector('flt-semantics-host, flt-semantics', { state: 'attached', timeout: timeoutMs });
}

export async function fill(page: Page, testId: string, value: string): Promise<void> {
  const field = byId(page, testId);
  await field.first().waitFor({ state: 'attached' });

  for (let attempt = 0; attempt < 3; attempt++) {
    await field.first().click();
    let target = field.locator('input, textarea').first();
    try {
      await target.waitFor({ state: 'attached', timeout: 3000 });
    } catch {
      target = page.locator('input:focus, textarea:focus').first();
    }
    await target.press('Control+a');
    await target.press('Delete');
    const valAfterClear = await target.evaluate((e: any) => e.value ?? '');
    if (valAfterClear !== '') {
      continue;
    }
    await target.type(value);
    const finalVal = await target.evaluate((e: any) => e.value ?? '');
    if (finalVal === value) {
      return;
    }
  }
  throw new Error(`could not set ${JSON.stringify(testId)} to ${JSON.stringify(value)}`);
}

export async function textOf(locator: Locator): Promise<string> {
  await locator.first().waitFor({ state: 'attached' });
  return locator.first().evaluate((e: any) => {
    const own = (e.getAttribute('aria-label') || e.textContent || '').trim();
    if (own) return own;
    const parts = [...e.querySelectorAll('[aria-label], input, textarea')].map(
      (c: any) => (c.getAttribute('aria-label') || c.value || '').trim()
    ).filter(Boolean);
    return parts.join(' ');
  });
}

export async function inputValue(page: Page, testId: string): Promise<string> {
  const field = byId(page, testId);
  await field.first().waitFor({ state: 'attached' });
  const target = field.locator('input, textarea').first();
  if ((await target.count()) > 0) {
    return target.evaluate((e: any) => e.value ?? '');
  }
  return '';
}
