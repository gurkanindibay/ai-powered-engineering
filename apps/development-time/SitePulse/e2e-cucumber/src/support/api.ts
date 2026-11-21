import crypto from 'crypto';
import Decimal from 'decimal.js';
import { getApiBaseUrl } from './stack';

export const WEBHOOK_SECRET = 'gui-e2e-webhook-secret';
export const VIRTUAL_IBANS: Record<string, string> = {
  A14: 'TR620020500009863791600001',
  '14': 'TR620020500009863791600001',
  B3: 'TR620020500009863791600002',
};

export class ApiClient {
  private base: string;

  constructor(base?: string) {
    this.base = base || getApiBaseUrl();
  }

  async login(email: string, password: string): Promise<{ token: string; user: any }> {
    const res = await fetch(`${this.base}/api/v1/auth/login`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ email, password }),
    });
    if (!res.ok) {
      throw new Error(`login failed: ${res.status} ${await res.text()}`);
    }
    const data = await res.json();
    return { token: data.access_token, user: data.user };
  }

  async webhookTransfer(
    virtualIban: string,
    amount: Decimal | string,
    transactionId: string,
    description = 'FAST transfer'
  ): Promise<any> {
    const payload = JSON.stringify({
      transaction_id: transactionId,
      virtual_iban: virtualIban,
      amount: new Decimal(amount).toFixed(2),
      currency: 'TRY',
      description,
    });
    const sig = crypto.createHmac('sha256', WEBHOOK_SECRET).update(payload).digest('hex');
    const res = await fetch(`${this.base}/api/v1/bank/webhook/incoming-transfer`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'X-SitePulse-Signature': sig,
      },
      body: payload,
    });
    if (!res.ok) {
      throw new Error(`webhook transfer failed: ${res.status} ${await res.text()}`);
    }
    return res.json();
  }

  async createCapitalProject(
    token: string,
    siteId: string,
    title: string,
    budget: Decimal | string,
    basis = 'BY_LAND_SHARE',
    installments = 1,
    firstDue = '2026-11-30'
  ): Promise<any> {
    const total = new Decimal(budget);
    const per = total.dividedBy(installments).toDecimalPlaces(2, Decimal.ROUND_DOWN);
    const items = [];
    for (let i = 1; i <= installments; i++) {
      const instBudget = i < installments ? per : total.minus(per.times(installments - 1));
      items.push({
        installment_number: i,
        total_installments: installments,
        due_date: firstDue,
        installment_budget: instBudget.toFixed(2),
      });
    }
    const payload = {
      site_id: siteId,
      title,
      category: 'OTHER',
      total_budget: total.toFixed(2),
      allocation_basis: basis,
      contract_amount: total.toFixed(2),
      installments: items,
    };
    const res = await fetch(`${this.base}/api/v1/capital-projects`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${token}`,
      },
      body: JSON.stringify(payload),
    });
    if (!res.ok) {
      throw new Error(`create capital project failed: ${res.status} ${await res.text()}`);
    }
    return res.json();
  }

  async accrueInstallment(token: string, siteId: string, projectId: string, number: number): Promise<any> {
    const res = await fetch(`${this.base}/api/v1/capital-projects/${projectId}/accrue-installment?site_id=${siteId}`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${token}`,
      },
      body: JSON.stringify({ installment_number: number }),
    });
    if (!res.ok) {
      throw new Error(`accrue installment failed: ${res.status} ${await res.text()}`);
    }
    return res.json();
  }
}
