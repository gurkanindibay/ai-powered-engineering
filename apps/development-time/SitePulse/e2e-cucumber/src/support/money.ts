import Decimal from 'decimal.js';

export function parseDecimal(value: string | number | Decimal): Decimal {
  if (value instanceof Decimal) return value;
  const str = String(value).trim().replace(/^₺\s?/, '');
  // Clean Turkish number format if present (e.g. 500.000,00 -> 500000.00)
  if (str.includes(',') && str.includes('.')) {
    const normalized = str.replace(/\./g, '').replace(',', '.');
    return new Decimal(normalized);
  }
  if (str.includes(',')) {
    return new Decimal(str.replace(',', '.'));
  }
  return new Decimal(str);
}

export function formatTry(amount: Decimal | string): string {
  const d = parseDecimal(amount);
  const parts = d.toFixed(2).split('.');
  const intPart = parts[0].replace(/\B(?=(\d{3})+(?!\d))/g, '.');
  return `₺${intPart},${parts[1]}`;
}

export function lastAmount(text: string): Decimal {
  const matches = [...text.matchAll(/₺\s?([0-9][0-9.,]*)/g)];
  if (!matches.length) {
    throw new Error(`no money amount found in: ${JSON.stringify(text)}`);
  }
  return parseDecimal(matches[matches.length - 1][1]);
}
