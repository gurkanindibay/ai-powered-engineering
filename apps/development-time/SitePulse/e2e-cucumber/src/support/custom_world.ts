import { setWorldConstructor, World, IWorldOptions, Before, After, AfterAll, setDefaultTimeout } from '@cucumber/cucumber';
import { Browser, BrowserContext, Page, chromium } from 'playwright';
import * as fs from 'fs';
import * as path from 'path';
import { ApiClient } from './api';
import { getWebBaseUrl, querySql } from './stack';
import { LoginPage } from '../pages/login_page';

setDefaultTimeout(60 * 1000);

export class CustomWorld extends World {
  browser?: Browser;
  context?: BrowserContext;
  page?: Page;
  api: ApiClient;
  actors: Record<string, { email: string; password: string }>;
  downloadedSamplePath?: string;
  pageErrors: string[] = [];

  constructor(options: IWorldOptions) {
    super(options);
    this.api = new ApiClient();
    this.actors = this.loadActors();
  }

  private loadActors(): Record<string, { email: string; password: string }> {
    const fixtureDir = path.resolve(__dirname, '../../../e2e/fixtures');
    const real = path.join(fixtureDir, 'actors.json');
    const example = path.join(fixtureDir, 'actors.example.json');
    const file = fs.existsSync(real) ? real : example;
    const data = JSON.parse(fs.readFileSync(file, 'utf-8'));
    data.saas = { email: 'admin@sitepulse.io', password: 'E2E-Bootstrap-Admin-1' };
    return data;
  }

  async loginAs(role: string): Promise<void> {
    if (!this.page) throw new Error('page not initialized');
    const actor = this.actors[role];
    if (!actor) throw new Error(`unknown actor role: ${role}`);
    const loginPage = new LoginPage(this.page, getWebBaseUrl());
    await loginPage.open();
    await loginPage.login(role, actor.email, actor.password);
  }
}

setWorldConstructor(CustomWorld);

let globalBrowser: Browser | null = null;

Before(async function (this: CustomWorld) {
  try {
    const res = await fetch('http://127.0.0.1:8189/reset', { method: 'POST' });
    if (!res.ok) console.warn('Reset endpoint returned', res.status);
  } catch {
    // Runner may manage reset externally
  }
  if (!globalBrowser) {
    globalBrowser = await chromium.launch({
      headless: true,
    });
  }
  this.browser = globalBrowser;
  this.context = await this.browser.newContext({
    viewport: { width: 1280, height: 900 },
    locale: 'tr-TR',
    permissions: ['clipboard-read', 'clipboard-write'],
  });
  this.page = await this.context.newPage();
  this.pageErrors = [];

  this.page.on('pageerror', exc => {
    this.pageErrors.push(`pageerror: ${exc.message || exc}`);
  });

  this.page.on('response', resp => {
    if (resp.status() >= 500) {
      this.pageErrors.push(`${resp.status()} ${resp.request().method()} ${resp.url()}`);
    }
  });
});

After(async function (this: CustomWorld, { result }) {
  if (result?.status !== 'PASSED' && this.page) {
    try {
      const screenshot = await this.page.screenshot();
      this.attach(screenshot, 'image/png');
    } catch {}
  }
  if (this.context) {
    await this.context.close();
  }
  if (this.pageErrors.length > 0 && result?.status === 'PASSED') {
    throw new Error(`Uncaught page/server errors:\n${this.pageErrors.join('\n')}`);
  }
});

AfterAll(async function () {
  if (globalBrowser) {
    await globalBrowser.close();
    globalBrowser = null;
  }
});
