import { Page } from 'playwright';
import { byId, fill, waitForApp } from '../support/flutter';

const ROLES: Record<string, [string, string]> = {
  homeowner: ['homeOwner', 'homeowner'],
  manager: ['siteManager', 'manager'],
  saas: ['saasAdmin', 'saas'],
  resident: ['homeOwner', 'homeowner'],
  auditor: ['homeOwner', 'homeowner'],
};

export class LoginPage {
  constructor(public readonly page: Page, public readonly baseUrl: string) {}

  async open(): Promise<this> {
    await this.page.goto(this.baseUrl);
    await waitForApp(this.page, 45000);
    await byId(this.page, 'login_tab_quickAll').waitFor({ timeout: 45000 });
    return this;
  }

  async login(role: string, email: string, pass: string): Promise<void> {
    const [tab, prefix] = ROLES[role] || ['siteManager', 'manager'];
    for (let attempt = 0; attempt < 3; attempt++) {
      await byId(this.page, `login_tab_${tab}`).click();
      try {
        await byId(this.page, `login_${prefix}_email`).waitFor({ timeout: 8000 });
        break;
      } catch (err) {
        if (attempt === 2) throw err;
      }
    }
    await fill(this.page, `login_${prefix}_email`, email);
    await fill(this.page, `login_${prefix}_password`, pass);
    await byId(this.page, `login_${prefix}_submit`).click();
  }
}
