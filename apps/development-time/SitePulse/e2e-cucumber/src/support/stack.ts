import { Client } from 'pg';
import { execSync } from 'child_process';

export const E2E_API_PORT = parseInt(process.env.E2E_API_PORT || '8180', 10);
export const E2E_WEB_PORT = parseInt(process.env.E2E_WEB_PORT || '9190', 10);
export const DB_HOST = process.env.DB_HOST || '127.0.0.1';
export const DB_PORT = parseInt(process.env.DB_PORT || '5432', 10);
export const DB_USER = process.env.DB_USER || 'sitepulse_user';
export const DB_PASS = process.env.DB_PASS || 'sitepulse_secret';
export const DB_NAME = process.env.E2E_DB_NAME || process.env.DB_NAME || 'sitepulse';

export function getApiBaseUrl(): string {
  return `http://localhost:${E2E_API_PORT}`;
}

export function getWebBaseUrl(): string {
  return `http://localhost:${E2E_WEB_PORT}`;
}

export async function querySql(query: string, dbName: string = DB_NAME): Promise<string> {
  const client = new Client({
    host: DB_HOST,
    port: DB_PORT,
    user: DB_USER,
    password: DB_PASS,
    database: dbName,
  });
  await client.connect();
  try {
    const res = await client.query(query);
    if (!res.rows || res.rows.length === 0) return '';
    // Format output like psql pipe-delimited single/multi row
    return res.rows
      .map(row => Object.values(row).join('|'))
      .join('\n');
  } finally {
    await client.end();
  }
}

export async function waitSql(query: string, expected: string, timeoutMs = 10000, dbName: string = DB_NAME): Promise<string> {
  const start = Date.now();
  let last = '';
  while (Date.now() - start < timeoutMs) {
    try {
      last = await querySql(query, dbName);
      if (last.trim() === expected.trim()) {
        return last.trim();
      }
    } catch {
      // transient connection errors during reload
    }
    await new Promise(r => setTimeout(r, 250));
  }
  return last.trim();
}
