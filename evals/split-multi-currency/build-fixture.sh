#!/usr/bin/env bash
# Builds the "Ledgerly" fixture repository in the current working directory.
#
# Branches:
#   main                    initial app (2 commits)
#   develop                 integration branch, 2 commits ahead of main
#   feature/multi-currency  oversized feature branch cut from develop (9 commits)
#
# Deterministic: fixed author/committer identity and dates. No network access.
set -euo pipefail

if [ -e .git ]; then
  echo "build-fixture.sh: refusing to run inside an existing git repository ($(pwd))" >&2
  exit 1
fi

git init -q -b main
git config user.name "Fixture Bot"
git config user.email fixture@example.com
git config commit.gpgsign false
git config tag.gpgsign false
git config core.autocrlf false
git config core.hooksPath .git/hooks

commit() {
  local when="$1" message="$2"
  git add -A
  GIT_AUTHOR_DATE="$when" GIT_COMMITTER_DATE="$when" git commit -q --no-verify -m "$message"
}

# ---------------------------------------------------------------------------
# main, commit 1: project skeleton, database, customers and invoices model
# ---------------------------------------------------------------------------
mkdir -p src/db/migrations src/customers src/invoices

cat > .gitignore <<'EOF'
node_modules/
dist/
coverage/
.env
EOF

cat > .eslintrc.json <<'EOF'
{
  "root": true,
  "parser": "@typescript-eslint/parser",
  "plugins": ["@typescript-eslint"],
  "extends": ["eslint:recommended", "plugin:@typescript-eslint/recommended"],
  "env": { "node": true, "es2022": true },
  "ignorePatterns": ["dist/"]
}
EOF

cat > package.json <<'EOF'
{
  "name": "ledgerly",
  "version": "0.4.0",
  "private": true,
  "description": "Small invoicing app for freelancers and small studios",
  "type": "module",
  "scripts": {
    "build": "tsc -p tsconfig.json",
    "lint": "eslint src --ext .ts,.tsx",
    "typecheck": "tsc -p tsconfig.json --noEmit",
    "start": "node dist/server.js",
    "worker": "node dist/worker.js"
  },
  "dependencies": {
    "pg": "^8.11.3",
    "react": "^18.2.0",
    "react-dom": "^18.2.0"
  },
  "devDependencies": {
    "@types/node": "^20.11.0",
    "@types/pg": "^8.10.9",
    "@types/react": "^18.2.48",
    "@types/react-dom": "^18.2.18",
    "@typescript-eslint/eslint-plugin": "^6.19.0",
    "@typescript-eslint/parser": "^6.19.0",
    "eslint": "^8.56.0",
    "typescript": "^5.3.3"
  }
}
EOF

cat > package-lock.json <<'EOF'
{
  "name": "ledgerly",
  "version": "0.4.0",
  "lockfileVersion": 3,
  "requires": true,
  "packages": {
    "": {
      "name": "ledgerly",
      "version": "0.4.0",
      "dependencies": {
        "pg": "^8.11.3",
        "react": "^18.2.0",
        "react-dom": "^18.2.0"
      },
      "devDependencies": {
        "@types/node": "^20.11.0",
        "@types/pg": "^8.10.9",
        "@types/react": "^18.2.48",
        "@types/react-dom": "^18.2.18",
        "@typescript-eslint/eslint-plugin": "^6.19.0",
        "@typescript-eslint/parser": "^6.19.0",
        "eslint": "^8.56.0",
        "typescript": "^5.3.3"
      }
    },
    "node_modules/eslint": {
      "version": "8.56.0",
      "resolved": "https://registry.npmjs.org/eslint/-/eslint-8.56.0.tgz",
      "dev": true
    },
    "node_modules/pg": {
      "version": "8.11.3",
      "resolved": "https://registry.npmjs.org/pg/-/pg-8.11.3.tgz"
    },
    "node_modules/react": {
      "version": "18.2.0",
      "resolved": "https://registry.npmjs.org/react/-/react-18.2.0.tgz"
    },
    "node_modules/react-dom": {
      "version": "18.2.0",
      "resolved": "https://registry.npmjs.org/react-dom/-/react-dom-18.2.0.tgz"
    },
    "node_modules/typescript": {
      "version": "5.3.3",
      "resolved": "https://registry.npmjs.org/typescript/-/typescript-5.3.3.tgz",
      "dev": true
    }
  }
}
EOF

cat > tsconfig.json <<'EOF'
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "ESNext",
    "moduleResolution": "Bundler",
    "jsx": "react-jsx",
    "strict": true,
    "noUncheckedIndexedAccess": true,
    "esModuleInterop": true,
    "skipLibCheck": true,
    "outDir": "dist",
    "rootDir": "src"
  },
  "include": ["src"]
}
EOF

cat > README.md <<'EOF'
# Ledgerly

Ledgerly is a small invoicing app for freelancers and small studios. It keeps
a list of customers, issues invoices against them, and gives the account owner
a server-rendered admin area to review what is outstanding.

## Getting started

```sh
npm install
npm run build
DATABASE_URL=postgres://localhost/ledgerly npm start
```

`npm run lint` runs ESLint over `src/`. `npm run typecheck` runs the compiler
without emitting.

## Layout

| Path                   | What lives there                                    |
| ---------------------- | --------------------------------------------------- |
| `src/db/`              | Postgres client and SQL migrations (run in order)   |
| `src/customers/`       | Customer model and lookups                          |
| `src/invoices/`        | Invoice model, totals and the invoice service       |
| `src/admin/`           | Server-rendered admin pages, layout and navigation  |
| `src/jobs/`            | Recurring background jobs and the loader for them   |
| `config/jobs.json`     | Which jobs the worker loads, and their cron strings |
| `src/routes.ts`        | Every HTTP route the app serves                     |
| `src/server.ts`        | Minimal `node:http` server that dispatches routes   |
| `src/worker.ts`        | Process that runs the configured jobs               |

## Conventions

- Money amounts on invoice lines are stored as `NUMERIC` in major units.
- Migrations are plain SQL files, numbered, and never edited once merged.
- A background job only runs if it is listed in `config/jobs.json`; the
  `module` field names a file in `src/jobs/` that is loaded at worker boot.
EOF

cat > src/db/client.ts <<'EOF'
import pg from 'pg';

/**
 * The minimal query surface repositories and services depend on. Keeping it
 * this small makes it trivial to substitute an in-memory fake.
 */
export interface Db {
  query<T = Record<string, unknown>>(sql: string, params?: readonly unknown[]): Promise<T[]>;
}

/** Creates a pooled Postgres-backed Db. */
export function createDb(connectionString: string): Db {
  const pool = new pg.Pool({ connectionString, max: 10 });
  return {
    async query<T>(sql: string, params: readonly unknown[] = []): Promise<T[]> {
      const result = await pool.query(sql, params as unknown[]);
      return result.rows as T[];
    },
  };
}
EOF

cat > src/db/migrations/001_create_customers.sql <<'EOF'
CREATE TABLE customers (
  id          SERIAL      PRIMARY KEY,
  name        TEXT        NOT NULL,
  tax_id      TEXT,
  country     CHAR(2)     NOT NULL,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX customers_name_idx ON customers (lower(name));
EOF

cat > src/db/migrations/002_create_invoices.sql <<'EOF'
CREATE TABLE invoices (
  id           SERIAL      PRIMARY KEY,
  customer_id  INTEGER     NOT NULL REFERENCES customers (id),
  number       TEXT        NOT NULL UNIQUE,
  status       TEXT        NOT NULL DEFAULT 'draft'
                 CHECK (status IN ('draft', 'sent', 'paid', 'void')),
  issued_on    DATE,
  due_on       DATE,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX invoices_customer_idx ON invoices (customer_id, created_at DESC);

CREATE TABLE invoice_lines (
  id           SERIAL         PRIMARY KEY,
  invoice_id   INTEGER        NOT NULL REFERENCES invoices (id) ON DELETE CASCADE,
  description  TEXT           NOT NULL,
  quantity     NUMERIC(12, 3) NOT NULL DEFAULT 1,
  unit_price   NUMERIC(12, 2) NOT NULL,
  position     INTEGER        NOT NULL
);
EOF

cat > src/customers/customer.ts <<'EOF'
/**
 * Customers are the parties Ledgerly bills. A customer owns zero or more
 * invoices; see src/invoices/invoice.ts.
 */
export interface Customer {
  id: number;
  name: string;
  /** VAT / tax registration number, if the customer supplied one. */
  taxId: string | null;
  /** ISO 3166-1 alpha-2 country code, upper case. */
  country: string;
  createdAt: Date;
}

/** Shape of a row in the `customers` table. */
export interface CustomerRow {
  id: number;
  name: string;
  tax_id: string | null;
  country: string;
  created_at: Date;
}

export function customerFromRow(row: CustomerRow): Customer {
  return {
    id: row.id,
    name: row.name,
    taxId: row.tax_id,
    country: row.country.toUpperCase(),
    createdAt: row.created_at,
  };
}

/** Name shown in admin tables, e.g. "Acme GmbH (DE123456789)". */
export function displayName(customer: Customer): string {
  return customer.taxId ? `${customer.name} (${customer.taxId})` : customer.name;
}
EOF

cat > src/invoices/invoice.ts <<'EOF'
import type { Customer } from '../customers/customer';

export type InvoiceStatus = 'draft' | 'sent' | 'paid' | 'void';

/** One billable line on an invoice. Prices are in major units (e.g. dollars). */
export interface InvoiceLine {
  description: string;
  quantity: number;
  unitPrice: number;
}

export interface Invoice {
  id: number;
  customerId: Customer['id'];
  /** Human-facing invoice number, unique across the account, e.g. "INV-2026-0042". */
  number: string;
  status: InvoiceStatus;
  /** ISO dates (YYYY-MM-DD); null while the invoice is a draft. */
  issuedOn: string | null;
  dueOn: string | null;
  lines: InvoiceLine[];
}

/** Shape of a row in the `invoices` table. */
export interface InvoiceRow {
  id: number;
  customer_id: number;
  number: string;
  status: InvoiceStatus;
  issued_on: string | null;
  due_on: string | null;
}

/** Shape of a row in the `invoice_lines` table. NUMERIC columns arrive as strings. */
export interface InvoiceLineRow {
  invoice_id: number;
  description: string;
  quantity: string;
  unit_price: string;
  position: number;
}

export function invoiceFromRow(row: InvoiceRow, lineRows: readonly InvoiceLineRow[]): Invoice {
  return {
    id: row.id,
    customerId: row.customer_id,
    number: row.number,
    status: row.status,
    issuedOn: row.issued_on,
    dueOn: row.due_on,
    lines: [...lineRows]
      .sort((a, b) => a.position - b.position)
      .map((line) => ({
        description: line.description,
        quantity: Number(line.quantity),
        unitPrice: Number(line.unit_price),
      })),
  };
}

export function lineAmount(line: InvoiceLine): number {
  return line.quantity * line.unitPrice;
}

/** Sum of all line amounts, rounded to cents. */
export function totalOf(lines: readonly InvoiceLine[]): number {
  const raw = lines.reduce((sum, line) => sum + lineAmount(line), 0);
  return Math.round(raw * 100) / 100;
}

/** A sent invoice whose due date is before `today` (YYYY-MM-DD). */
export function isOverdue(invoice: Invoice, today: string): boolean {
  return invoice.status === 'sent' && invoice.dueOn !== null && invoice.dueOn < today;
}
EOF

commit "2026-01-12T10:00:00+00:00" "Initial Ledgerly skeleton: customers and invoices"

# ---------------------------------------------------------------------------
# main, commit 2: invoice service, admin, routes, server, jobs
# ---------------------------------------------------------------------------
mkdir -p src/admin/pages src/jobs

cat > src/invoices/invoice-service.ts <<'EOF'
import type { Db } from '../db/client';
import { customerFromRow, type Customer, type CustomerRow } from '../customers/customer';
import {
  invoiceFromRow,
  totalOf,
  type Invoice,
  type InvoiceLineRow,
  type InvoiceRow,
} from './invoice';

export interface InvoiceSummary {
  invoice: Invoice;
  customer: Customer;
  total: number;
}

/** Read-side operations on invoices, plus draft cleanup for the purge job. */
export class InvoiceService {
  constructor(private readonly db: Db) {}

  async findById(id: number): Promise<Invoice | null> {
    const [row] = await this.db.query<InvoiceRow>('SELECT * FROM invoices WHERE id = $1', [id]);
    if (!row) return null;
    const lines = await this.db.query<InvoiceLineRow>(
      'SELECT * FROM invoice_lines WHERE invoice_id = $1',
      [id],
    );
    return invoiceFromRow(row, lines);
  }

  async listForCustomer(customerId: number): Promise<Invoice[]> {
    const rows = await this.db.query<InvoiceRow>(
      'SELECT * FROM invoices WHERE customer_id = $1 ORDER BY created_at DESC',
      [customerId],
    );
    return this.withLines(rows);
  }

  async summarize(id: number): Promise<InvoiceSummary | null> {
    const invoice = await this.findById(id);
    if (!invoice) return null;
    return this.toSummary(invoice);
  }

  async listRecentSummaries(limit = 50): Promise<InvoiceSummary[]> {
    const rows = await this.db.query<InvoiceRow>(
      'SELECT * FROM invoices ORDER BY created_at DESC LIMIT $1',
      [limit],
    );
    const invoices = await this.withLines(rows);
    return Promise.all(invoices.map((invoice) => this.toSummary(invoice)));
  }

  /** Amount the customer still owes across unpaid invoices. */
  async outstandingBalance(customerId: number): Promise<number> {
    const invoices = await this.listForCustomer(customerId);
    return invoices
      .filter((invoice) => invoice.status !== 'paid')
      .reduce((sum, invoice) => sum + totalOf(invoice.lines), 0);
  }

  /** Removes drafts nobody has touched for `days` days. Returns how many were removed. */
  async deleteDraftsOlderThan(days: number): Promise<number> {
    const rows = await this.db.query<{ id: number }>(
      `DELETE FROM invoices
        WHERE status = 'draft' AND created_at < now() - ($1 || ' days')::interval
        RETURNING id`,
      [days],
    );
    return rows.length;
  }

  private async toSummary(invoice: Invoice): Promise<InvoiceSummary> {
    const [customerRow] = await this.db.query<CustomerRow>(
      'SELECT * FROM customers WHERE id = $1',
      [invoice.customerId],
    );
    if (!customerRow) {
      throw new Error(`Invoice ${invoice.number} references missing customer ${invoice.customerId}`);
    }
    return { invoice, customer: customerFromRow(customerRow), total: totalOf(invoice.lines) };
  }

  private async withLines(rows: readonly InvoiceRow[]): Promise<Invoice[]> {
    if (rows.length === 0) return [];
    const lines = await this.db.query<InvoiceLineRow>(
      'SELECT * FROM invoice_lines WHERE invoice_id = ANY($1)',
      [rows.map((row) => row.id)],
    );
    return rows.map((row) => invoiceFromRow(row, lines.filter((line) => line.invoice_id === row.id)));
  }
}
EOF

cat > src/admin/nav.ts <<'EOF'
/** One entry in the admin sidebar. */
export interface NavItem {
  label: string;
  href: string;
}

/** Sidebar entries, rendered by AdminLayout in this order. */
export const navItems: NavItem[] = [
  { label: 'Customers', href: '/admin/customers' },
  { label: 'Invoices', href: '/admin/invoices' },
];
EOF

cat > src/admin/layout.tsx <<'EOF'
import type { ReactNode } from 'react';
import { navItems } from './nav';

export interface AdminLayoutProps {
  title: string;
  children: ReactNode;
}

/** Shared chrome for every admin page: document head, sidebar and heading. */
export function AdminLayout({ title, children }: AdminLayoutProps) {
  return (
    <html lang="en">
      <head>
        <meta charSet="utf-8" />
        <title>{`${title} · Ledgerly`}</title>
        <link rel="stylesheet" href="/static/admin.css" />
      </head>
      <body>
        <nav className="admin-nav">
          <a className="brand" href="/admin/invoices">
            Ledgerly
          </a>
          <ul>
            {navItems.map((item) => (
              <li key={item.href}>
                <a href={item.href}>{item.label}</a>
              </li>
            ))}
          </ul>
        </nav>
        <main>
          <h1>{title}</h1>
          {children}
        </main>
      </body>
    </html>
  );
}
EOF

cat > src/admin/render.ts <<'EOF'
import { createElement, type ComponentType } from 'react';
import { renderToString } from 'react-dom/server';
import type { RouteContext } from '../routes';

/**
 * Adapts a page component into a route handler: `load` gathers the page's
 * props from the request context and the result is rendered to HTML.
 */
export function renderPage<P extends object>(
  Page: ComponentType<P>,
  load: (ctx: RouteContext) => Promise<P>,
): (ctx: RouteContext) => Promise<string> {
  return async (ctx) => renderToString(createElement(Page, await load(ctx)));
}
EOF

cat > src/admin/pages/customers-page.tsx <<'EOF'
import { displayName, type Customer } from '../../customers/customer';
import { formatAmount } from '../../lib/format';
import { AdminLayout } from '../layout';

export interface CustomerListRow {
  customer: Customer;
  /** Sum of sent, unpaid invoices. */
  outstanding: number;
}

export interface CustomersPageProps {
  rows: CustomerListRow[];
}

export function CustomersPage({ rows }: CustomersPageProps) {
  return (
    <AdminLayout title="Customers">
      {rows.length === 0 ? (
        <p className="empty">No customers yet.</p>
      ) : (
        <table className="data-table">
          <thead>
            <tr>
              <th>Name</th>
              <th>Country</th>
              <th>Customer since</th>
              <th className="num">Outstanding</th>
            </tr>
          </thead>
          <tbody>
            {rows.map(({ customer, outstanding }) => (
              <tr key={customer.id}>
                <td>{displayName(customer)}</td>
                <td>{customer.country}</td>
                <td>{customer.createdAt.toISOString().slice(0, 10)}</td>
                <td className="num">{formatAmount(outstanding)}</td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
    </AdminLayout>
  );
}
EOF

cat > src/admin/pages/invoices-page.tsx <<'EOF'
import { displayName } from '../../customers/customer';
import { isOverdue } from '../../invoices/invoice';
import type { InvoiceSummary } from '../../invoices/invoice-service';
import { formatAmount } from '../../lib/format';
import { AdminLayout } from '../layout';

export interface InvoicesPageProps {
  summaries: InvoiceSummary[];
  /** Overrides "today" for overdue highlighting; YYYY-MM-DD. */
  today?: string;
}

export function InvoicesPage({ summaries, today = new Date().toISOString().slice(0, 10) }: InvoicesPageProps) {
  return (
    <AdminLayout title="Invoices">
      <table className="data-table">
        <thead>
          <tr>
            <th>Number</th>
            <th>Customer</th>
            <th>Status</th>
            <th>Due</th>
            <th className="num">Total</th>
          </tr>
        </thead>
        <tbody>
          {summaries.map(({ invoice, customer, total }) => (
            <tr key={invoice.id} className={isOverdue(invoice, today) ? 'overdue' : undefined}>
              <td>
                <a href={`/api/invoices/${invoice.id}`}>{invoice.number}</a>
              </td>
              <td>{displayName(customer)}</td>
              <td>{invoice.status}</td>
              <td>{invoice.dueOn ?? '—'}</td>
              <td className="num">{formatAmount(total)}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </AdminLayout>
  );
}
EOF

cat > src/routes.ts <<'EOF'
import type { Db } from './db/client';
import { app } from './app';
import { renderPage } from './admin/render';
import { CustomersPage } from './admin/pages/customers-page';
import { InvoicesPage } from './admin/pages/invoices-page';
import { customerFromRow, type CustomerRow } from './customers/customer';
import { InvoiceService } from './invoices/invoice-service';

export type HttpMethod = 'GET' | 'POST' | 'PUT' | 'DELETE';

/** Everything a handler receives for one request. */
export interface RouteContext {
  db: Db;
  params: Record<string, string>;
  query: URLSearchParams;
  body: unknown;
}

export interface RouteDefinition {
  method: HttpMethod;
  /** Express-style pattern; `:name` segments populate `params`. First match wins. */
  path: string;
  /** Return a string to send HTML, anything else is sent as JSON; null means 404. */
  handler: (ctx: RouteContext) => Promise<unknown>;
}

async function listCustomers(db: Db) {
  const rows = await db.query<CustomerRow>('SELECT * FROM customers ORDER BY lower(name)');
  return rows.map(customerFromRow);
}

async function customerRows(db: Db) {
  const service = new InvoiceService(db);
  const customers = await listCustomers(db);
  return Promise.all(
    customers.map(async (customer) => ({
      customer,
      outstanding: await service.outstandingBalance(customer.id),
    })),
  );
}

export const routes: RouteDefinition[] = [
  { method: 'GET', path: '/api/health', handler: async () => ({ ok: true, startedAt: app.locals.startedAt ?? null }) },

  // Customers
  { method: 'GET', path: '/api/customers', handler: ({ db }) => listCustomers(db) },
  {
    method: 'GET',
    path: '/api/customers/:id',
    handler: async ({ db, params }) => {
      const [row] = await db.query<CustomerRow>('SELECT * FROM customers WHERE id = $1', [
        Number(params.id),
      ]);
      return row ? customerFromRow(row) : null;
    },
  },
  {
    method: 'GET',
    path: '/api/customers/:id/invoices',
    handler: ({ db, params }) => new InvoiceService(db).listForCustomer(Number(params.id)),
  },
  {
    method: 'GET',
    path: '/api/customers/:id/balance',
    handler: async ({ db, params }) => ({
      balance: await new InvoiceService(db).outstandingBalance(Number(params.id)),
    }),
  },

  // Invoices
  {
    method: 'GET',
    path: '/api/invoices/:id',
    handler: ({ db, params }) => new InvoiceService(db).summarize(Number(params.id)),
  },

  // Admin pages
  {
    method: 'GET',
    path: '/admin/customers',
    handler: renderPage(CustomersPage, async ({ db }) => ({ rows: await customerRows(db) })),
  },
  {
    method: 'GET',
    path: '/admin/invoices',
    handler: renderPage(InvoicesPage, async ({ db }) => ({
      summaries: await new InvoiceService(db).listRecentSummaries(),
    })),
  },
];
EOF

cat > src/server.ts <<'EOF'
import { createServer, type IncomingMessage, type ServerResponse } from 'node:http';
import { app } from './app';
import { createDb, type Db } from './db/client';
import { routes, type RouteContext, type RouteDefinition } from './routes';

interface Match {
  route: RouteDefinition;
  params: Record<string, string>;
}

/** Finds the first route whose method and path pattern match. */
export function matchRoute(method: string, pathname: string): Match | null {
  const actual = pathname.split('/');
  for (const route of routes) {
    if (route.method !== method) continue;
    const pattern = route.path.split('/');
    if (pattern.length !== actual.length) continue;
    const params: Record<string, string> = {};
    const matched = pattern.every((segment, i) => {
      const value = actual[i] ?? '';
      if (segment.startsWith(':')) {
        params[segment.slice(1)] = decodeURIComponent(value);
        return true;
      }
      return segment === value;
    });
    if (matched) return { route, params };
  }
  return null;
}

/** Repeated form fields (checkbox groups) become arrays. */
function formToObject(raw: string): Record<string, string | string[]> {
  const out: Record<string, string | string[]> = {};
  for (const [key, value] of new URLSearchParams(raw)) {
    const existing = out[key];
    out[key] = existing === undefined ? value : Array.isArray(existing) ? [...existing, value] : [existing, value];
  }
  return out;
}

async function readBody(req: IncomingMessage): Promise<unknown> {
  const chunks: Buffer[] = [];
  for await (const chunk of req) chunks.push(chunk as Buffer);
  if (chunks.length === 0) return undefined;
  const raw = Buffer.concat(chunks).toString('utf8');
  const type = req.headers['content-type'] ?? '';
  if (type.includes('application/json')) return JSON.parse(raw);
  if (type.includes('application/x-www-form-urlencoded')) return formToObject(raw);
  return raw;
}

function send(res: ServerResponse, status: number, payload: unknown): void {
  if (typeof payload === 'string') {
    res.writeHead(status, { 'content-type': 'text/html; charset=utf-8' });
    res.end(`<!doctype html>${payload}`);
    return;
  }
  res.writeHead(status, { 'content-type': 'application/json' });
  res.end(JSON.stringify(payload ?? null));
}

export function startServer(db: Db, port = Number(process.env.PORT ?? 3000)) {
  app.locals.startedAt = new Date();
  const server = createServer(async (req, res) => {
    const url = new URL(req.url ?? '/', 'http://localhost');
    const match = matchRoute(req.method ?? 'GET', url.pathname);
    if (!match) return send(res, 404, { error: 'not_found' });
    try {
      const ctx: RouteContext = {
        db,
        params: match.params,
        query: url.searchParams,
        body: await readBody(req),
      };
      const result = await match.route.handler(ctx);
      send(res, result === null ? 404 : 200, result);
    } catch (error) {
      console.error(error);
      send(res, 500, { error: 'internal_error' });
    }
  });
  server.listen(port);
  return server;
}

if (import.meta.url === `file://${process.argv[1]}`) {
  startServer(createDb(process.env.DATABASE_URL ?? 'postgres://localhost/ledgerly'));
}
EOF

cat > src/jobs/job.ts <<'EOF'
import type { Db } from '../db/client';

/** What a job receives each time it runs. */
export interface JobContext {
  db: Db;
  /** Start time of this run; use it instead of `new Date()` so runs are reproducible. */
  now: Date;
  log: (message: string) => void;
}

/**
 * A recurring background job. `cron` uses standard five-field syntax and is
 * evaluated in UTC by the worker process.
 */
export interface CronJob {
  name: string;
  cron: string;
  run: (ctx: JobContext) => Promise<void>;
}
EOF

cat > src/jobs/purge-drafts.ts <<'EOF'
import { InvoiceService } from '../invoices/invoice-service';
import type { JobContext } from './job';

/** Drafts untouched for this many days are deleted. */
export const DRAFT_RETENTION_DAYS = 90;

export async function purgeDrafts({ db, log }: JobContext): Promise<void> {
  const removed = await new InvoiceService(db).deleteDraftsOlderThan(DRAFT_RETENTION_DAYS);
  log(`purge-drafts: removed ${removed} stale draft invoice(s)`);
}

export default purgeDrafts;
EOF

cat > src/jobs/registry.ts <<'EOF'
import { readFile } from 'node:fs/promises';
import type { CronJob } from './job';

/** One entry in config/jobs.json. */
interface JobConfigEntry {
  name: string;
  /** File in src/jobs/ (without extension) whose default function runs the job. */
  module: string;
  cron: string;
}

export const JOBS_CONFIG_URL = new URL('../../config/jobs.json', import.meta.url);

/**
 * Reads config/jobs.json and loads each job's module by name. The worker
 * calls this once at boot; a job that is not in the config never runs, and a
 * configured module that cannot be loaded stops the worker from starting.
 */
export async function loadJobs(configUrl: URL = JOBS_CONFIG_URL): Promise<CronJob[]> {
  const entries = JSON.parse(await readFile(configUrl, 'utf8')) as JobConfigEntry[];
  return Promise.all(
    entries.map(async (entry) => {
      const loaded = (await import(`./${entry.module}`)) as { default?: CronJob['run'] };
      if (typeof loaded.default !== 'function') {
        throw new Error(`Job "${entry.name}": ./${entry.module} has no default run function`);
      }
      return { name: entry.name, cron: entry.cron, run: loaded.default };
    }),
  );
}

export async function findJob(name: string): Promise<CronJob | undefined> {
  return (await loadJobs()).find((job) => job.name === name);
}
EOF

mkdir -p config src/lib

cat > config/jobs.json <<'EOF'
[
  { "name": "purge-drafts", "module": "purge-drafts", "cron": "0 3 * * *" }
]
EOF

cat > src/app.ts <<'EOF'
/**
 * Process-wide values shared by every request. server.ts fills this in once
 * at startup and route handlers read from it. Keys are free-form so new
 * wiring does not need a type change here.
 */
export interface AppLocals {
  startedAt?: Date;
  [key: string]: unknown;
}

export const app: { locals: AppLocals } = { locals: {} };
EOF

cat > src/lib/format.ts <<'EOF'
const amountFormat = new Intl.NumberFormat('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 });

/**
 * Formats an amount for admin tables: thousands separators, always two
 * decimals, minus sign for credits. 1234.5 -> "1,234.50".
 */
export function formatAmount(n: number): string {
  return amountFormat.format(n);
}
EOF

cat > src/worker.ts <<'EOF'
import { createDb } from './db/client';
import { loadJobs } from './jobs/registry';

/** True when a five-field cron string matches `at` in UTC. Supports wildcards, steps and comma lists. */
export function cronMatches(expression: string, at: Date): boolean {
  const fields = expression.trim().split(/\s+/);
  if (fields.length !== 5) throw new Error(`Invalid cron string: "${expression}"`);
  const values = [at.getUTCMinutes(), at.getUTCHours(), at.getUTCDate(), at.getUTCMonth() + 1, at.getUTCDay()];
  return fields.every((field, i) => {
    const value = values[i] ?? -1;
    if (field === '*') return true;
    if (field.startsWith('*/')) return value % Number(field.slice(2)) === 0;
    return field.split(',').map(Number).includes(value);
  });
}

/** Loads the configured jobs, then checks once a minute which of them are due. */
export async function startWorker(databaseUrl: string): Promise<void> {
  const db = createDb(databaseUrl);
  const jobs = await loadJobs();
  console.log(`worker: loaded ${jobs.map((job) => job.name).join(', ')}`);
  setInterval(() => {
    const now = new Date();
    for (const job of jobs) {
      if (!cronMatches(job.cron, now)) continue;
      job
        .run({ db, now, log: (message) => console.log(message) })
        .catch((error: unknown) => console.error(`worker: ${job.name} failed`, error));
    }
  }, 60_000);
}

if (import.meta.url === `file://${process.argv[1]}`) {
  await startWorker(process.env.DATABASE_URL ?? 'postgres://localhost/ledgerly');
}
EOF

commit "2026-01-19T15:30:00+00:00" "Invoice service, admin pages, routes and draft purge job"

# ---------------------------------------------------------------------------
# develop: integration branch, two commits ahead of main
# ---------------------------------------------------------------------------
git checkout -q -b develop

cat > src/customers/customer-search.ts <<'EOF'
import type { Db } from '../db/client';
import { customerFromRow, type Customer, type CustomerRow } from './customer';

export interface CustomerSearchOptions {
  /** Maximum results; clamped to 1..100. Default 20. */
  limit?: number;
  /** Restrict to one ISO country code. */
  country?: string;
}

const MAX_LIMIT = 100;

/** Escapes LIKE wildcards so user input is matched literally. */
export function escapeLike(value: string): string {
  return value.replace(/[\\%_]/g, (ch) => `\\${ch}`);
}

/**
 * Case-insensitive substring search over customer name and tax id. Terms
 * shorter than two characters return nothing rather than the whole table.
 */
export async function searchCustomers(
  db: Db,
  term: string,
  options: CustomerSearchOptions = {},
): Promise<Customer[]> {
  const trimmed = term.trim();
  if (trimmed.length < 2) return [];
  const limit = Math.min(Math.max(Math.trunc(options.limit ?? 20), 1), MAX_LIMIT);
  const params: unknown[] = [`%${escapeLike(trimmed.toLowerCase())}%`, limit];
  let sql = `SELECT * FROM customers
    WHERE (lower(name) LIKE $1 ESCAPE '\\' OR lower(tax_id) LIKE $1 ESCAPE '\\')`;
  if (options.country) {
    params.push(options.country.toUpperCase());
    sql += ` AND country = $${params.length}`;
  }
  sql += ' ORDER BY lower(name) LIMIT $2';
  const rows = await db.query<CustomerRow>(sql, params);
  return rows.map(customerFromRow);
}
EOF

cat > src/routes.ts <<'EOF'
import type { Db } from './db/client';
import { app } from './app';
import { renderPage } from './admin/render';
import { CustomersPage } from './admin/pages/customers-page';
import { InvoicesPage } from './admin/pages/invoices-page';
import { customerFromRow, type CustomerRow } from './customers/customer';
import { searchCustomers } from './customers/customer-search';
import { InvoiceService } from './invoices/invoice-service';

export type HttpMethod = 'GET' | 'POST' | 'PUT' | 'DELETE';

/** Everything a handler receives for one request. */
export interface RouteContext {
  db: Db;
  params: Record<string, string>;
  query: URLSearchParams;
  body: unknown;
}

export interface RouteDefinition {
  method: HttpMethod;
  /** Express-style pattern; `:name` segments populate `params`. First match wins. */
  path: string;
  /** Return a string to send HTML, anything else is sent as JSON; null means 404. */
  handler: (ctx: RouteContext) => Promise<unknown>;
}

async function listCustomers(db: Db) {
  const rows = await db.query<CustomerRow>('SELECT * FROM customers ORDER BY lower(name)');
  return rows.map(customerFromRow);
}

async function customerRows(db: Db) {
  const service = new InvoiceService(db);
  const customers = await listCustomers(db);
  return Promise.all(
    customers.map(async (customer) => ({
      customer,
      outstanding: await service.outstandingBalance(customer.id),
    })),
  );
}

export const routes: RouteDefinition[] = [
  { method: 'GET', path: '/api/health', handler: async () => ({ ok: true, startedAt: app.locals.startedAt ?? null }) },

  // Customers
  { method: 'GET', path: '/api/customers', handler: ({ db }) => listCustomers(db) },
  {
    // Must stay above /api/customers/:id so "search" is not read as an id.
    method: 'GET',
    path: '/api/customers/search',
    handler: ({ db, query }) =>
      searchCustomers(db, query.get('q') ?? '', {
        limit: query.has('limit') ? Number(query.get('limit')) : undefined,
        country: query.get('country') ?? undefined,
      }),
  },
  {
    method: 'GET',
    path: '/api/customers/:id',
    handler: async ({ db, params }) => {
      const [row] = await db.query<CustomerRow>('SELECT * FROM customers WHERE id = $1', [
        Number(params.id),
      ]);
      return row ? customerFromRow(row) : null;
    },
  },
  {
    method: 'GET',
    path: '/api/customers/:id/invoices',
    handler: ({ db, params }) => new InvoiceService(db).listForCustomer(Number(params.id)),
  },
  {
    method: 'GET',
    path: '/api/customers/:id/balance',
    handler: async ({ db, params }) => ({
      balance: await new InvoiceService(db).outstandingBalance(Number(params.id)),
    }),
  },

  // Invoices
  {
    method: 'GET',
    path: '/api/invoices/:id',
    handler: ({ db, params }) => new InvoiceService(db).summarize(Number(params.id)),
  },

  // Admin pages
  {
    method: 'GET',
    path: '/admin/customers',
    handler: renderPage(CustomersPage, async ({ db }) => ({ rows: await customerRows(db) })),
  },
  {
    method: 'GET',
    path: '/admin/invoices',
    handler: renderPage(InvoicesPage, async ({ db }) => ({
      summaries: await new InvoiceService(db).listRecentSummaries(),
    })),
  },
];
EOF

commit "2026-02-03T11:00:00+00:00" "Add customer search by name or tax id"

cat > src/invoices/invoice-service.ts <<'EOF'
import type { Db } from '../db/client';
import { customerFromRow, type Customer, type CustomerRow } from '../customers/customer';
import {
  invoiceFromRow,
  totalOf,
  type Invoice,
  type InvoiceLineRow,
  type InvoiceRow,
} from './invoice';

export interface InvoiceSummary {
  invoice: Invoice;
  customer: Customer;
  total: number;
}

/** Read-side operations on invoices, plus draft cleanup for the purge job. */
export class InvoiceService {
  constructor(private readonly db: Db) {}

  async findById(id: number): Promise<Invoice | null> {
    const [row] = await this.db.query<InvoiceRow>('SELECT * FROM invoices WHERE id = $1', [id]);
    if (!row) return null;
    const lines = await this.db.query<InvoiceLineRow>(
      'SELECT * FROM invoice_lines WHERE invoice_id = $1',
      [id],
    );
    return invoiceFromRow(row, lines);
  }

  async listForCustomer(customerId: number): Promise<Invoice[]> {
    const rows = await this.db.query<InvoiceRow>(
      'SELECT * FROM invoices WHERE customer_id = $1 ORDER BY created_at DESC',
      [customerId],
    );
    return this.withLines(rows);
  }

  async summarize(id: number): Promise<InvoiceSummary | null> {
    const invoice = await this.findById(id);
    if (!invoice) return null;
    return this.toSummary(invoice);
  }

  async listRecentSummaries(limit = 50): Promise<InvoiceSummary[]> {
    const rows = await this.db.query<InvoiceRow>(
      'SELECT * FROM invoices ORDER BY created_at DESC LIMIT $1',
      [limit],
    );
    const invoices = await this.withLines(rows);
    return Promise.all(invoices.map((invoice) => this.toSummary(invoice)));
  }

  /**
   * Amount the customer still owes. Only sent invoices count: drafts have not
   * been billed yet and void invoices never will be.
   */
  async outstandingBalance(customerId: number): Promise<number> {
    const invoices = await this.listForCustomer(customerId);
    const owed = invoices
      .filter((invoice) => invoice.status === 'sent')
      .reduce((sum, invoice) => sum + totalOf(invoice.lines), 0);
    return Math.round(owed * 100) / 100;
  }

  /** Removes drafts nobody has touched for `days` days. Returns how many were removed. */
  async deleteDraftsOlderThan(days: number): Promise<number> {
    const rows = await this.db.query<{ id: number }>(
      `DELETE FROM invoices
        WHERE status = 'draft' AND created_at < now() - ($1 || ' days')::interval
        RETURNING id`,
      [days],
    );
    return rows.length;
  }

  private async toSummary(invoice: Invoice): Promise<InvoiceSummary> {
    const [customerRow] = await this.db.query<CustomerRow>(
      'SELECT * FROM customers WHERE id = $1',
      [invoice.customerId],
    );
    if (!customerRow) {
      throw new Error(`Invoice ${invoice.number} references missing customer ${invoice.customerId}`);
    }
    return { invoice, customer: customerFromRow(customerRow), total: totalOf(invoice.lines) };
  }

  private async withLines(rows: readonly InvoiceRow[]): Promise<Invoice[]> {
    if (rows.length === 0) return [];
    const lines = await this.db.query<InvoiceLineRow>(
      'SELECT * FROM invoice_lines WHERE invoice_id = ANY($1)',
      [rows.map((row) => row.id)],
    );
    return rows.map((row) => invoiceFromRow(row, lines.filter((line) => line.invoice_id === row.id)));
  }
}
EOF

commit "2026-02-10T09:20:00+00:00" "Fix outstanding balance counting drafts and void invoices"

# ---------------------------------------------------------------------------
# feature/multi-currency: cut from the tip of develop, built in spec order
# ---------------------------------------------------------------------------
git checkout -q -b feature/multi-currency

# --- F1: money value object, currency column, nav entry ----------------------
mkdir -p src/lib/money

cat > src/lib/money/currencies.ts <<'EOF'
/**
 * ISO 4217 currency metadata used by the money library.
 *
 * `minorUnits` is the number of decimal digits in the currency's minor unit
 * (2 for USD cents, 0 for JPY, 3 for KWD fils). Amounts are always held as
 * integers in minor units, so this table is what turns 1234 into "12.34".
 *
 * The table is deliberately limited to currencies customers have asked for;
 * add rows as needed rather than pulling in the full ISO list.
 */
export interface CurrencyInfo {
  /** Three-letter ISO 4217 alphabetic code. */
  readonly code: string;
  /** English display name. */
  readonly name: string;
  /** Digits after the decimal separator in the minor unit. */
  readonly minorUnits: 0 | 2 | 3;
  /** Symbol used when a locale-aware formatter is not available. */
  readonly symbol: string;
}

export const CURRENCIES = {
  AUD: { code: 'AUD', name: 'Australian Dollar', minorUnits: 2, symbol: 'A$' },
  BHD: { code: 'BHD', name: 'Bahraini Dinar', minorUnits: 3, symbol: 'BD' },
  CAD: { code: 'CAD', name: 'Canadian Dollar', minorUnits: 2, symbol: 'C$' },
  CHF: { code: 'CHF', name: 'Swiss Franc', minorUnits: 2, symbol: 'CHF' },
  DKK: { code: 'DKK', name: 'Danish Krone', minorUnits: 2, symbol: 'kr' },
  EUR: { code: 'EUR', name: 'Euro', minorUnits: 2, symbol: '€' },
  GBP: { code: 'GBP', name: 'Pound Sterling', minorUnits: 2, symbol: '£' },
  ISK: { code: 'ISK', name: 'Icelandic Króna', minorUnits: 0, symbol: 'kr' },
  JPY: { code: 'JPY', name: 'Japanese Yen', minorUnits: 0, symbol: '¥' },
  KWD: { code: 'KWD', name: 'Kuwaiti Dinar', minorUnits: 3, symbol: 'KD' },
  NOK: { code: 'NOK', name: 'Norwegian Krone', minorUnits: 2, symbol: 'kr' },
  SEK: { code: 'SEK', name: 'Swedish Krona', minorUnits: 2, symbol: 'kr' },
  SGD: { code: 'SGD', name: 'Singapore Dollar', minorUnits: 2, symbol: 'S$' },
  USD: { code: 'USD', name: 'US Dollar', minorUnits: 2, symbol: '$' },
} as const satisfies Record<string, CurrencyInfo>;

export type CurrencyCode = keyof typeof CURRENCIES;

/** Every supported code, alphabetically. */
export const ALL_CURRENCY_CODES: readonly CurrencyCode[] = (Object.keys(CURRENCIES) as CurrencyCode[]).sort();

export class UnknownCurrencyError extends Error {
  constructor(readonly input: string) {
    super(`Unknown or unsupported currency code: "${input}"`);
    this.name = 'UnknownCurrencyError';
  }
}

/** Exact, case-sensitive check. Use parseCurrencyCode for user or database input. */
export function isCurrencyCode(value: string): value is CurrencyCode {
  return Object.prototype.hasOwnProperty.call(CURRENCIES, value);
}

/** Normalises and validates input such as "usd " or "USD" into a CurrencyCode. */
export function parseCurrencyCode(value: string): CurrencyCode {
  const normalised = value.trim().toUpperCase();
  if (!isCurrencyCode(normalised)) throw new UnknownCurrencyError(value);
  return normalised;
}

export function currencyInfo(code: CurrencyCode): CurrencyInfo {
  return CURRENCIES[code];
}

/** 10^minorUnits: the number of minor units in one major unit. */
export function minorUnitFactor(code: CurrencyCode): number {
  return 10 ** CURRENCIES[code].minorUnits;
}
EOF

cat > src/lib/money/rounding.ts <<'EOF'
/**
 * Rounding helpers for turning fractional minor-unit values into integers.
 *
 * Money arithmetic defaults to banker's rounding (round half to even): ties
 * go to the nearest even integer, so rounding errors do not drift in one
 * direction when many values are summed.
 */
export type RoundingMode = 'half-even' | 'half-up' | 'down';

/**
 * Tolerance for recognising an exact .5 tie after floating-point
 * multiplication, e.g. 0.135 * 100 === 13.500000000000002.
 */
const TIE_EPSILON = 1e-9;

/** Ties to even: 0.5 -> 0, 1.5 -> 2, 2.5 -> 2, -2.5 -> -2. */
export function roundHalfEven(value: number): number {
  assertFinite(value);
  const floor = Math.floor(value);
  const fraction = value - floor;
  if (fraction > 0.5 + TIE_EPSILON) return floor + 1;
  if (fraction < 0.5 - TIE_EPSILON) return floor;
  return floor % 2 === 0 ? floor : floor + 1;
}

/** Ties away from zero: 2.5 -> 3, -2.5 -> -3. */
export function roundHalfUp(value: number): number {
  assertFinite(value);
  const magnitude = Math.floor(Math.abs(value) + 0.5 + TIE_EPSILON);
  return value < 0 && magnitude !== 0 ? -magnitude : magnitude;
}

/** Truncates toward zero: 2.9 -> 2, -2.9 -> -2. */
export function roundDown(value: number): number {
  assertFinite(value);
  return Math.trunc(value) || 0;
}

export function round(value: number, mode: RoundingMode = 'half-even'): number {
  switch (mode) {
    case 'half-even':
      return roundHalfEven(value);
    case 'half-up':
      return roundHalfUp(value);
    case 'down':
      return roundDown(value);
  }
}

function assertFinite(value: number): void {
  if (!Number.isFinite(value)) {
    throw new RangeError(`Cannot round non-finite value ${value}`);
  }
}
EOF

cat > src/lib/money/money.ts <<'EOF'
import { currencyInfo, minorUnitFactor, parseCurrencyCode, type CurrencyCode } from './currencies';
import { round, type RoundingMode } from './rounding';

/**
 * Thrown when an operation combines amounts in different currencies.
 * Converting between currencies is deliberately not this module's job.
 */
export class CurrencyMismatchError extends Error {
  constructor(
    readonly left: CurrencyCode,
    readonly right: CurrencyCode,
  ) {
    super(`Cannot combine ${left} with ${right} without converting first`);
    this.name = 'CurrencyMismatchError';
  }
}

/** Serialised form used in API responses. `amount` is in minor units. */
export interface MoneyJSON {
  amount: number;
  currency: CurrencyCode;
}

/**
 * An immutable amount of money in a single currency.
 *
 * The amount is an integer number of minor units (cents, pence, yen). Never
 * build Money from a float amount of major units except through `fromMajor`,
 * which applies an explicit rounding mode.
 */
export class Money {
  private constructor(
    /** Integer amount in the currency's minor unit. */
    readonly minor: number,
    readonly currency: CurrencyCode,
  ) {}

  static ofMinor(minor: number, currency: CurrencyCode): Money {
    if (!Number.isSafeInteger(minor)) {
      throw new RangeError(`Money amount must be a safe integer of minor units, got ${minor}`);
    }
    // Normalise -0 so equals() and JSON output never disagree.
    return new Money(minor === 0 ? 0 : minor, currency);
  }

  static fromMajor(major: number, currency: CurrencyCode, mode: RoundingMode = 'half-even'): Money {
    return Money.ofMinor(round(major * minorUnitFactor(currency), mode), currency);
  }

  static zero(currency: CurrencyCode): Money {
    return new Money(0, currency);
  }

  /** Parses "12.34 EUR" or "EUR 12.34" (code is case-insensitive). */
  static parse(input: string): Money {
    const match = /^\s*(?:([A-Za-z]{3})\s+)?(-?\d+(?:\.\d+)?)(?:\s+([A-Za-z]{3}))?\s*$/.exec(input);
    const code = match?.[1] ?? match?.[3];
    if (!match || !code || (match[1] && match[3])) {
      throw new SyntaxError(`Cannot parse money value: "${input}"`);
    }
    const currency = parseCurrencyCode(code);
    const digits = currencyInfo(currency).minorUnits;
    const [, fraction = ''] = (match[2] ?? '').split('.');
    if (fraction.length > digits) {
      throw new RangeError(`${currency} allows at most ${digits} decimal places: "${input}"`);
    }
    return Money.fromMajor(Number(match[2]), currency);
  }

  /** Sums amounts that must all be in `currency`; an empty list gives zero. */
  static sum(amounts: readonly Money[], currency: CurrencyCode): Money {
    return amounts.reduce((total, amount) => total.add(amount), Money.zero(currency));
  }

  /** Digits after the decimal separator for this amount's currency. */
  get minorUnits(): number {
    return currencyInfo(this.currency).minorUnits;
  }

  toMajor(): number {
    return this.minor / minorUnitFactor(this.currency);
  }

  add(other: Money): Money {
    this.assertSameCurrency(other);
    return Money.ofMinor(this.minor + other.minor, this.currency);
  }

  subtract(other: Money): Money {
    this.assertSameCurrency(other);
    return Money.ofMinor(this.minor - other.minor, this.currency);
  }

  multiply(factor: number, mode: RoundingMode = 'half-even'): Money {
    if (!Number.isFinite(factor)) {
      throw new RangeError(`Cannot multiply money by ${factor}`);
    }
    return Money.ofMinor(round(this.minor * factor, mode), this.currency);
  }

  negate(): Money {
    return Money.ofMinor(-this.minor, this.currency);
  }

  isZero(): boolean {
    return this.minor === 0;
  }

  isNegative(): boolean {
    return this.minor < 0;
  }

  isPositive(): boolean {
    return this.minor > 0;
  }

  equals(other: Money): boolean {
    return this.currency === other.currency && this.minor === other.minor;
  }

  compare(other: Money): -1 | 0 | 1 {
    this.assertSameCurrency(other);
    return this.minor < other.minor ? -1 : this.minor > other.minor ? 1 : 0;
  }

  /**
   * Splits the amount according to `ratios` without losing or inventing a
   * single minor unit. Leftover units go to the first parts, one each.
   *
   *   Money.ofMinor(100, 'USD').allocate([1, 1, 1]) // 34, 33, 33 cents
   */
  allocate(ratios: readonly number[]): Money[] {
    if (ratios.length === 0) {
      throw new RangeError('allocate() needs at least one ratio');
    }
    const totalRatio = ratios.reduce((sum, ratio) => sum + ratio, 0);
    if (!(totalRatio > 0)) {
      throw new RangeError('allocate() ratios must sum to a positive number');
    }
    const parts = ratios.map((ratio) => Math.floor((this.minor * ratio) / totalRatio));
    let remainder = this.minor - parts.reduce((sum, part) => sum + part, 0);
    for (let i = 0; remainder > 0; i = (i + 1) % parts.length) {
      parts[i] = (parts[i] ?? 0) + 1;
      remainder -= 1;
    }
    return parts.map((part) => Money.ofMinor(part, this.currency));
  }

  /** Locale-aware display string, e.g. "$1,234.56" or "¥1,235". */
  format(locale = 'en-US'): string {
    return new Intl.NumberFormat(locale, {
      style: 'currency',
      currency: this.currency,
      minimumFractionDigits: this.minorUnits,
      maximumFractionDigits: this.minorUnits,
    }).format(this.toMajor());
  }

  /** Unambiguous, locale-independent form: "1234.56 USD". */
  toString(): string {
    return `${this.toMajor().toFixed(this.minorUnits)} ${this.currency}`;
  }

  toJSON(): MoneyJSON {
    return { amount: this.minor, currency: this.currency };
  }

  private assertSameCurrency(other: Money): void {
    if (other.currency !== this.currency) {
      throw new CurrencyMismatchError(this.currency, other.currency);
    }
  }
}
EOF

cat > src/lib/money/index.ts <<'EOF'
/**
 * Public surface of the money library. Import from 'src/lib/money' rather
 * than from individual files so internals can move freely.
 */
export { Money, CurrencyMismatchError, type MoneyJSON } from './money';
export {
  ALL_CURRENCY_CODES,
  CURRENCIES,
  UnknownCurrencyError,
  currencyInfo,
  isCurrencyCode,
  minorUnitFactor,
  parseCurrencyCode,
  type CurrencyCode,
  type CurrencyInfo,
} from './currencies';
export { round, roundDown, roundHalfEven, roundHalfUp, type RoundingMode } from './rounding';
EOF

cat > src/db/migrations/004_add_currency_to_invoices.sql <<'EOF'
-- Every invoice is billed in exactly one currency. Existing invoices were all
-- issued in US dollars, so the default backfills them correctly.
ALTER TABLE invoices
  ADD COLUMN currency CHAR(3) NOT NULL DEFAULT 'USD'
    CHECK (currency ~ '^[A-Z]{3}$');

-- Customers may ask to see totals in their own currency. NULL means "show
-- the invoice currency".
ALTER TABLE customers
  ADD COLUMN preferred_currency CHAR(3)
    CHECK (preferred_currency IS NULL OR preferred_currency ~ '^[A-Z]{3}$');
EOF

cat > src/invoices/invoice.ts <<'EOF'
import type { Customer } from '../customers/customer';
import { parseCurrencyCode, type CurrencyCode } from '../lib/money';

export type InvoiceStatus = 'draft' | 'sent' | 'paid' | 'void';

/** One billable line on an invoice. Prices are in major units (e.g. dollars). */
export interface InvoiceLine {
  description: string;
  quantity: number;
  unitPrice: number;
}

export interface Invoice {
  id: number;
  customerId: Customer['id'];
  /** Human-facing invoice number, unique across the account, e.g. "INV-2026-0042". */
  number: string;
  status: InvoiceStatus;
  /** Currency every line on this invoice is priced and billed in. */
  currency: CurrencyCode;
  /** ISO dates (YYYY-MM-DD); null while the invoice is a draft. */
  issuedOn: string | null;
  dueOn: string | null;
  lines: InvoiceLine[];
}

/** Shape of a row in the `invoices` table. */
export interface InvoiceRow {
  id: number;
  customer_id: number;
  number: string;
  status: InvoiceStatus;
  currency: string;
  issued_on: string | null;
  due_on: string | null;
}

/** Shape of a row in the `invoice_lines` table. NUMERIC columns arrive as strings. */
export interface InvoiceLineRow {
  invoice_id: number;
  description: string;
  quantity: string;
  unit_price: string;
  position: number;
}

export function invoiceFromRow(row: InvoiceRow, lineRows: readonly InvoiceLineRow[]): Invoice {
  return {
    id: row.id,
    customerId: row.customer_id,
    number: row.number,
    status: row.status,
    currency: parseCurrencyCode(row.currency),
    issuedOn: row.issued_on,
    dueOn: row.due_on,
    lines: [...lineRows]
      .sort((a, b) => a.position - b.position)
      .map((line) => ({
        description: line.description,
        quantity: Number(line.quantity),
        unitPrice: Number(line.unit_price),
      })),
  };
}

export function lineAmount(line: InvoiceLine): number {
  return line.quantity * line.unitPrice;
}

/** Sum of all line amounts, rounded to cents. */
export function totalOf(lines: readonly InvoiceLine[]): number {
  const raw = lines.reduce((sum, line) => sum + lineAmount(line), 0);
  return Math.round(raw * 100) / 100;
}

/** A sent invoice whose due date is before `today` (YYYY-MM-DD). */
export function isOverdue(invoice: Invoice, today: string): boolean {
  return invoice.status === 'sent' && invoice.dueOn !== null && invoice.dueOn < today;
}
EOF

cat > src/admin/nav.ts <<'EOF'
/** One entry in the admin sidebar. */
export interface NavItem {
  label: string;
  href: string;
}

/** Sidebar entries, rendered by AdminLayout in this order. */
export const navItems: NavItem[] = [
  { label: 'Customers', href: '/admin/customers' },
  { label: 'Invoices', href: '/admin/invoices' },
  { label: 'Currencies', href: '/admin/currencies' },
];
EOF

commit "2026-03-02T09:14:00+00:00" "Multi-currency: Money value object, currency column, Currencies nav entry"

# --- F2: vitest tooling and first money tests --------------------------------
mkdir -p test/lib/money

cat > package.json <<'EOF'
{
  "name": "ledgerly",
  "version": "0.4.0",
  "private": true,
  "description": "Small invoicing app for freelancers and small studios",
  "type": "module",
  "scripts": {
    "build": "tsc -p tsconfig.json",
    "lint": "eslint src --ext .ts,.tsx",
    "typecheck": "tsc -p tsconfig.json --noEmit",
    "start": "node dist/server.js",
    "worker": "node dist/worker.js",
    "test": "vitest run",
    "test:watch": "vitest"
  },
  "dependencies": {
    "pg": "^8.11.3",
    "react": "^18.2.0",
    "react-dom": "^18.2.0"
  },
  "devDependencies": {
    "@types/node": "^20.11.0",
    "@types/pg": "^8.10.9",
    "@types/react": "^18.2.48",
    "@types/react-dom": "^18.2.18",
    "@typescript-eslint/eslint-plugin": "^6.19.0",
    "@typescript-eslint/parser": "^6.19.0",
    "eslint": "^8.56.0",
    "typescript": "^5.3.3",
    "vitest": "^1.6.0"
  }
}
EOF

cat > package-lock.json <<'EOF'
{
  "name": "ledgerly",
  "version": "0.4.0",
  "lockfileVersion": 3,
  "requires": true,
  "packages": {
    "": {
      "name": "ledgerly",
      "version": "0.4.0",
      "dependencies": {
        "pg": "^8.11.3",
        "react": "^18.2.0",
        "react-dom": "^18.2.0"
      },
      "devDependencies": {
        "@types/node": "^20.11.0",
        "@types/pg": "^8.10.9",
        "@types/react": "^18.2.48",
        "@types/react-dom": "^18.2.18",
        "@typescript-eslint/eslint-plugin": "^6.19.0",
        "@typescript-eslint/parser": "^6.19.0",
        "eslint": "^8.56.0",
        "typescript": "^5.3.3",
        "vitest": "^1.6.0"
      }
    },
    "node_modules/@vitest/runner": {
      "version": "1.6.0",
      "resolved": "https://registry.npmjs.org/@vitest/runner/-/runner-1.6.0.tgz",
      "dev": true
    },
    "node_modules/eslint": {
      "version": "8.56.0",
      "resolved": "https://registry.npmjs.org/eslint/-/eslint-8.56.0.tgz",
      "dev": true
    },
    "node_modules/pg": {
      "version": "8.11.3",
      "resolved": "https://registry.npmjs.org/pg/-/pg-8.11.3.tgz"
    },
    "node_modules/react": {
      "version": "18.2.0",
      "resolved": "https://registry.npmjs.org/react/-/react-18.2.0.tgz"
    },
    "node_modules/react-dom": {
      "version": "18.2.0",
      "resolved": "https://registry.npmjs.org/react-dom/-/react-dom-18.2.0.tgz"
    },
    "node_modules/tinypool": {
      "version": "0.8.4",
      "resolved": "https://registry.npmjs.org/tinypool/-/tinypool-0.8.4.tgz",
      "dev": true
    },
    "node_modules/typescript": {
      "version": "5.3.3",
      "resolved": "https://registry.npmjs.org/typescript/-/typescript-5.3.3.tgz",
      "dev": true
    },
    "node_modules/vitest": {
      "version": "1.6.0",
      "resolved": "https://registry.npmjs.org/vitest/-/vitest-1.6.0.tgz",
      "dev": true
    }
  }
}
EOF

cat > vitest.config.ts <<'EOF'
import { defineConfig } from 'vitest/config';

export default defineConfig({
  test: {
    include: ['test/**/*.test.ts'],
    setupFiles: ['test/setup.ts'],
    environment: 'node',
    restoreMocks: true,
    coverage: {
      include: ['src/**/*.ts'],
      exclude: ['src/db/migrations/**'],
    },
  },
});
EOF

cat > test/setup.ts <<'EOF'
import { afterEach, vi } from 'vitest';

// Date and currency formatting must not depend on the machine running tests.
process.env.TZ = 'UTC';

afterEach(() => {
  vi.useRealTimers();
});
EOF

cat > test/lib/money/money.test.ts <<'EOF'
import { describe, expect, it } from 'vitest';
import { CurrencyMismatchError, Money } from '../../../src/lib/money';

describe('Money', () => {
  describe('construction', () => {
    it('stores amounts as integer minor units', () => {
      const amount = Money.ofMinor(1234, 'USD');
      expect(amount.minor).toBe(1234);
      expect(amount.toMajor()).toBe(12.34);
    });

    it('rejects fractional minor units', () => {
      expect(() => Money.ofMinor(12.5, 'USD')).toThrow(RangeError);
    });

    it('converts major units using the minor-unit digits of the currency', () => {
      expect(Money.fromMajor(12.34, 'USD').minor).toBe(1234);
      expect(Money.fromMajor(1234, 'JPY').minor).toBe(1234);
      expect(Money.fromMajor(1.234, 'KWD').minor).toBe(1234);
    });

    it('rounds half to even by default', () => {
      expect(Money.fromMajor(0.125, 'USD').minor).toBe(12);
      expect(Money.fromMajor(0.135, 'USD').minor).toBe(14);
    });

    it('supports explicit rounding modes', () => {
      expect(Money.fromMajor(0.125, 'USD', 'half-up').minor).toBe(13);
      expect(Money.fromMajor(0.129, 'USD', 'down').minor).toBe(12);
    });

  });

  describe('parse', () => {
    it('accepts amount then code', () => {
      expect(Money.parse('12.34 EUR').equals(Money.ofMinor(1234, 'EUR'))).toBe(true);
    });

    it('accepts code then amount, case-insensitively', () => {
      expect(Money.parse('gbp 5').equals(Money.ofMinor(500, 'GBP'))).toBe(true);
    });

    it('rejects input it cannot read', () => {
      expect(() => Money.parse('twelve dollars')).toThrow(SyntaxError);
      expect(() => Money.parse('EUR 5 USD')).toThrow(SyntaxError);
    });
  });

  describe('arithmetic', () => {
    it('adds and subtracts in the same currency', () => {
      const a = Money.ofMinor(1050, 'EUR');
      const b = Money.ofMinor(275, 'EUR');
      expect(a.add(b).minor).toBe(1325);
      expect(a.subtract(b).minor).toBe(775);
      expect(b.subtract(a).isNegative()).toBe(true);
    });

    it('refuses to mix currencies', () => {
      expect(() => Money.ofMinor(1, 'EUR').add(Money.ofMinor(1, 'USD'))).toThrow(CurrencyMismatchError);
    });

    it('multiplies with rounding', () => {
      expect(Money.ofMinor(999, 'USD').multiply(0.5).minor).toBe(500);
      expect(Money.ofMinor(999, 'USD').multiply(0.5, 'down').minor).toBe(499);
    });

    it('sums a list, giving zero for an empty list', () => {
      const items = [Money.ofMinor(100, 'CHF'), Money.ofMinor(250, 'CHF')];
      expect(Money.sum(items, 'CHF').minor).toBe(350);
      expect(Money.sum([], 'CHF').isZero()).toBe(true);
    });
  });

  describe('allocate', () => {
    it('never loses a minor unit', () => {
      const parts = Money.ofMinor(100, 'USD').allocate([1, 1, 1]);
      expect(parts.map((part) => part.minor)).toEqual([34, 33, 33]);
    });

    it('respects uneven ratios', () => {
      const parts = Money.ofMinor(1001, 'USD').allocate([3, 7]);
      expect(parts.map((part) => part.minor)).toEqual([301, 700]);
    });

    it('handles negative amounts', () => {
      const parts = Money.ofMinor(-100, 'USD').allocate([1, 1, 1]);
      expect(parts.map((part) => part.minor)).toEqual([-33, -33, -34]);
    });

    it('requires at least one ratio', () => {
      expect(() => Money.ofMinor(100, 'USD').allocate([])).toThrow(RangeError);
    });
  });

  describe('output', () => {
    it('formats with the currency digits', () => {
      expect(Money.ofMinor(123456, 'USD').format()).toBe('$1,234.56');
      expect(Money.ofMinor(1235, 'JPY').format()).toBe('¥1,235');
    });

    it('serialises minor units and code', () => {
      expect(JSON.stringify(Money.ofMinor(500, 'EUR'))).toBe('{"amount":500,"currency":"EUR"}');
    });
  });
});
EOF

cat > test/lib/money/currencies.test.ts <<'EOF'
import { describe, expect, it } from 'vitest';
import {
  ALL_CURRENCY_CODES,
  CURRENCIES,
  UnknownCurrencyError,
  currencyInfo,
  isCurrencyCode,
  minorUnitFactor,
  parseCurrencyCode,
} from '../../../src/lib/money';

describe('currency table', () => {
  it('keys every entry by its own code', () => {
    for (const [key, info] of Object.entries(CURRENCIES)) {
      expect(info.code).toBe(key);
    }
  });

  it('knows zero- and three-digit currencies', () => {
    expect(currencyInfo('JPY').minorUnits).toBe(0);
    expect(currencyInfo('KWD').minorUnits).toBe(3);
    expect(minorUnitFactor('USD')).toBe(100);
  });

  it('lists codes alphabetically', () => {
    expect([...ALL_CURRENCY_CODES].sort()).toEqual(ALL_CURRENCY_CODES);
  });

  it('guards exact codes only', () => {
    expect(isCurrencyCode('EUR')).toBe(true);
    expect(isCurrencyCode('eur')).toBe(false);
    expect(isCurrencyCode('toString')).toBe(false);
  });

  it('parses loose input', () => {
    expect(parseCurrencyCode(' eur ')).toBe('EUR');
    expect(() => parseCurrencyCode('XYZ')).toThrow(UnknownCurrencyError);
  });
});
EOF

cat > config/jobs.json <<'EOF'
[
  { "name": "purge-drafts", "module": "purge-drafts", "cron": "30 2 * * *" },
  { "name": "refresh-rates", "module": "refresh-rates", "cron": "15 * * * *" }
]
EOF

commit "2026-03-02T15:40:00+00:00" "Add vitest; cover Money and the currency table"

# --- F3: exchange rate providers ----------------------------------------------
mkdir -p src/rates

cat > src/rates/rate-snapshot.ts <<'EOF'
import type { CurrencyCode } from '../lib/money';

export interface RateSnapshotData {
  base: CurrencyCode;
  quote: CurrencyCode;
  /** Units of `quote` per one unit of `base`. Always positive. */
  rate: number;
  /** When the source published the rate (not when we fetched it). */
  asOf: Date;
  /** Identifier of the provider that produced the rate, e.g. "central-bank". */
  source: string;
}

/**
 * A single observed exchange rate. Snapshots are immutable: a newer rate is a
 * new snapshot, never an update to an old one, which keeps history queryable.
 */
export class RateSnapshot implements RateSnapshotData {
  readonly base: CurrencyCode;
  readonly quote: CurrencyCode;
  readonly rate: number;
  readonly asOf: Date;
  readonly source: string;

  constructor(data: RateSnapshotData) {
    if (!Number.isFinite(data.rate) || data.rate <= 0) {
      throw new RangeError(
        `Exchange rate ${data.base}/${data.quote} must be a positive number, got ${data.rate}`,
      );
    }
    if (Number.isNaN(data.asOf.getTime())) {
      throw new RangeError(`Exchange rate ${data.base}/${data.quote} has an invalid timestamp`);
    }
    this.base = data.base;
    this.quote = data.quote;
    this.rate = data.rate;
    this.asOf = new Date(data.asOf.getTime());
    this.source = data.source;
  }

  /** The trivial 1:1 rate between a currency and itself. */
  static identity(currency: CurrencyCode, asOf: Date = new Date()): RateSnapshot {
    return new RateSnapshot({ base: currency, quote: currency, rate: 1, asOf, source: 'identity' });
  }

  /** "EUR/USD" */
  get pair(): string {
    return `${this.base}/${this.quote}`;
  }

  /** The same observation expressed the other way round (quote to base). */
  invert(): RateSnapshot {
    return new RateSnapshot({
      base: this.quote,
      quote: this.base,
      rate: 1 / this.rate,
      asOf: this.asOf,
      source: this.source,
    });
  }
}
EOF

cat > src/rates/rate-provider.ts <<'EOF'
import type { CurrencyCode } from '../lib/money';
import type { RateSnapshot } from './rate-snapshot';

/**
 * A source of exchange rates. Implementations may call a remote API, read
 * the database, or return fixed values in tests; callers should not care.
 */
export interface RateProvider {
  /** Stable identifier stored alongside every rate this provider produces. */
  readonly id: string;

  /**
   * Latest rate for converting one unit of `base` into `quote`.
   * Rejects with RateUnavailableError when the pair cannot be served.
   */
  getRate(base: CurrencyCode, quote: CurrencyCode): Promise<RateSnapshot>;

  /** Every rate the provider currently publishes, relative to its own base. */
  getAll(): Promise<RateSnapshot[]>;
}

export class RateUnavailableError extends Error {
  constructor(
    readonly base: CurrencyCode,
    readonly quote: CurrencyCode,
    readonly providerId: string,
    options?: { cause?: unknown },
  ) {
    super(`No ${base}/${quote} rate available from ${providerId}`, options);
    this.name = 'RateUnavailableError';
  }
}
EOF

cat > src/rates/base-http-provider.ts <<'EOF'
import pRetry, { AbortError } from 'p-retry';
import type { CurrencyCode } from '../lib/money';
import { RateUnavailableError, type RateProvider } from './rate-provider';
import { RateSnapshot } from './rate-snapshot';

export interface HttpProviderOptions {
  /** Origin plus path prefix, without a trailing slash. */
  baseUrl: string;
  /** Per-attempt timeout. Default 5 seconds. */
  timeoutMs?: number;
  /** Retries after the first attempt for network errors and 5xx responses. Default 3. */
  retries?: number;
  /** Delay before the first retry; doubles each time. Default 250 ms. */
  minRetryDelayMs?: number;
  /** Injectable for tests. Defaults to the global fetch. */
  fetchImpl?: typeof fetch;
}

/**
 * Shared plumbing for providers that read rates over HTTP: timeouts, retry
 * with exponential backoff, and direct/inverse pair lookup. Subclasses only
 * describe where the feed lives and how to parse it.
 *
 * Client errors (4xx) are not retried: asking again will not fix them.
 */
export abstract class BaseHttpProvider implements RateProvider {
  abstract readonly id: string;

  protected readonly baseUrl: string;
  protected readonly timeoutMs: number;
  protected readonly retries: number;
  protected readonly minRetryDelayMs: number;
  private readonly fetchImpl: typeof fetch;

  constructor(options: HttpProviderOptions) {
    this.baseUrl = options.baseUrl.replace(/\/+$/, '');
    this.timeoutMs = options.timeoutMs ?? 5_000;
    this.retries = options.retries ?? 3;
    this.minRetryDelayMs = options.minRetryDelayMs ?? 250;
    this.fetchImpl = options.fetchImpl ?? fetch;
  }

  /** Path of the feed relative to `baseUrl`, starting with "/". */
  protected abstract path(): string;

  /** Turns the raw response body into snapshots. Throw on malformed input. */
  protected abstract parse(body: string, fetchedAt: Date): RateSnapshot[];

  async getAll(): Promise<RateSnapshot[]> {
    const body = await this.fetchWithRetry(`${this.baseUrl}${this.path()}`);
    return this.parse(body, new Date());
  }

  async getRate(base: CurrencyCode, quote: CurrencyCode): Promise<RateSnapshot> {
    if (base === quote) return RateSnapshot.identity(base);
    const all = await this.loadAllFor(base, quote);
    return this.pick(all, base, quote);
  }

  /** Like getAll, but failures surface as RateUnavailableError for the requested pair. */
  protected async loadAllFor(base: CurrencyCode, quote: CurrencyCode): Promise<RateSnapshot[]> {
    try {
      return await this.getAll();
    } catch (error) {
      throw new RateUnavailableError(base, quote, this.id, { cause: error });
    }
  }

  /** Finds base/quote directly, or inverts quote/base when only that is published. */
  protected pick(all: readonly RateSnapshot[], base: CurrencyCode, quote: CurrencyCode): RateSnapshot {
    const direct = all.find((snapshot) => snapshot.base === base && snapshot.quote === quote);
    if (direct) return direct;
    const inverse = all.find((snapshot) => snapshot.base === quote && snapshot.quote === base);
    if (inverse) return inverse.invert();
    throw new RateUnavailableError(base, quote, this.id);
  }

  private fetchWithRetry(url: string): Promise<string> {
    return pRetry(
      async () => {
        const controller = new AbortController();
        const timer = setTimeout(() => controller.abort(), this.timeoutMs);
        try {
          const response = await this.fetchImpl(url, {
            signal: controller.signal,
            headers: { accept: 'application/json' },
          });
          if (response.status >= 400 && response.status < 500) {
            throw new AbortError(`${this.id}: HTTP ${response.status} for ${url}`);
          }
          if (!response.ok) {
            throw new Error(`${this.id}: HTTP ${response.status} for ${url}`);
          }
          return await response.text();
        } finally {
          clearTimeout(timer);
        }
      },
      { retries: this.retries, minTimeout: this.minRetryDelayMs, factor: 2 },
    );
  }
}
EOF

cat > src/rates/central-bank-provider.ts <<'EOF'
import { isCurrencyCode, type CurrencyCode } from '../lib/money';
import { BaseHttpProvider, type HttpProviderOptions } from './base-http-provider';
import { RateSnapshot } from './rate-snapshot';

/** Body of GET /reference-rates/latest.json */
interface ReferenceRatesResponse {
  base: string;
  /** Publication date, YYYY-MM-DD. */
  date: string;
  /** Units of each currency per one EUR. */
  rates: Record<string, number>;
}

export const CENTRAL_BANK_BASE_URL = 'https://rates.centralbank.example/v1';

/**
 * Daily reference rates published by the central bank, all quoted against
 * EUR. Pairs that do not involve EUR are derived by crossing the two EUR legs.
 * Rates are published once per working day around 16:00 CET; entries for
 * currencies Ledgerly does not support are ignored.
 */
export class CentralBankProvider extends BaseHttpProvider {
  readonly id = 'central-bank';

  static readonly REFERENCE_CURRENCY: CurrencyCode = 'EUR';

  constructor(options: Partial<HttpProviderOptions> = {}) {
    super({ baseUrl: CENTRAL_BANK_BASE_URL, ...options });
  }

  protected path(): string {
    return '/reference-rates/latest.json';
  }

  protected parse(body: string): RateSnapshot[] {
    const data = JSON.parse(body) as Partial<ReferenceRatesResponse>;
    const reference = CentralBankProvider.REFERENCE_CURRENCY;
    if (data.base !== reference || typeof data.date !== 'string' || typeof data.rates !== 'object') {
      throw new Error(`${this.id}: unexpected response shape`);
    }
    const asOf = new Date(`${data.date}T15:00:00Z`);
    const snapshots: RateSnapshot[] = [];
    for (const [code, rate] of Object.entries(data.rates ?? {})) {
      if (!isCurrencyCode(code) || code === reference) continue;
      snapshots.push(new RateSnapshot({ base: reference, quote: code, rate, asOf, source: this.id }));
    }
    return snapshots;
  }

  override async getRate(base: CurrencyCode, quote: CurrencyCode): Promise<RateSnapshot> {
    if (base === quote) return RateSnapshot.identity(base);
    const all = await this.loadAllFor(base, quote);
    const reference = CentralBankProvider.REFERENCE_CURRENCY;
    if (base === reference || quote === reference) {
      return this.pick(all, base, quote);
    }
    const baseLeg = this.pick(all, reference, base);
    const quoteLeg = this.pick(all, reference, quote);
    return new RateSnapshot({
      base,
      quote,
      rate: baseLeg.rate / quoteLeg.rate,
      asOf: baseLeg.asOf < quoteLeg.asOf ? baseLeg.asOf : quoteLeg.asOf,
      source: `${this.id}:cross`,
    });
  }
}
EOF

cat > package.json <<'EOF'
{
  "name": "ledgerly",
  "version": "0.4.0",
  "private": true,
  "description": "Small invoicing app for freelancers and small studios",
  "type": "module",
  "scripts": {
    "build": "tsc -p tsconfig.json",
    "lint": "eslint src --ext .ts,.tsx",
    "typecheck": "tsc -p tsconfig.json --noEmit",
    "start": "node dist/server.js",
    "worker": "node dist/worker.js",
    "test": "vitest run",
    "test:watch": "vitest"
  },
  "dependencies": {
    "p-retry": "^6.2.0",
    "pg": "^8.11.3",
    "react": "^18.2.0",
    "react-dom": "^18.2.0"
  },
  "devDependencies": {
    "@types/node": "^20.11.0",
    "@types/pg": "^8.10.9",
    "@types/react": "^18.2.48",
    "@types/react-dom": "^18.2.18",
    "@typescript-eslint/eslint-plugin": "^6.19.0",
    "@typescript-eslint/parser": "^6.19.0",
    "eslint": "^8.56.0",
    "typescript": "^5.3.3",
    "vitest": "^1.6.0"
  }
}
EOF

cat > package-lock.json <<'EOF'
{
  "name": "ledgerly",
  "version": "0.4.0",
  "lockfileVersion": 3,
  "requires": true,
  "packages": {
    "": {
      "name": "ledgerly",
      "version": "0.4.0",
      "dependencies": {
        "p-retry": "^6.2.0",
        "pg": "^8.11.3",
        "react": "^18.2.0",
        "react-dom": "^18.2.0"
      },
      "devDependencies": {
        "@types/node": "^20.11.0",
        "@types/pg": "^8.10.9",
        "@types/react": "^18.2.48",
        "@types/react-dom": "^18.2.18",
        "@typescript-eslint/eslint-plugin": "^6.19.0",
        "@typescript-eslint/parser": "^6.19.0",
        "eslint": "^8.56.0",
        "typescript": "^5.3.3",
        "vitest": "^1.6.0"
      }
    },
    "node_modules/@types/retry": {
      "version": "0.12.2",
      "resolved": "https://registry.npmjs.org/@types/retry/-/retry-0.12.2.tgz"
    },
    "node_modules/@vitest/runner": {
      "version": "1.6.0",
      "resolved": "https://registry.npmjs.org/@vitest/runner/-/runner-1.6.0.tgz",
      "dev": true
    },
    "node_modules/eslint": {
      "version": "8.56.0",
      "resolved": "https://registry.npmjs.org/eslint/-/eslint-8.56.0.tgz",
      "dev": true
    },
    "node_modules/is-network-error": {
      "version": "1.1.0",
      "resolved": "https://registry.npmjs.org/is-network-error/-/is-network-error-1.1.0.tgz"
    },
    "node_modules/p-retry": {
      "version": "6.2.0",
      "resolved": "https://registry.npmjs.org/p-retry/-/p-retry-6.2.0.tgz"
    },
    "node_modules/pg": {
      "version": "8.11.3",
      "resolved": "https://registry.npmjs.org/pg/-/pg-8.11.3.tgz"
    },
    "node_modules/react": {
      "version": "18.2.0",
      "resolved": "https://registry.npmjs.org/react/-/react-18.2.0.tgz"
    },
    "node_modules/react-dom": {
      "version": "18.2.0",
      "resolved": "https://registry.npmjs.org/react-dom/-/react-dom-18.2.0.tgz"
    },
    "node_modules/retry": {
      "version": "0.13.1",
      "resolved": "https://registry.npmjs.org/retry/-/retry-0.13.1.tgz"
    },
    "node_modules/tinypool": {
      "version": "0.8.4",
      "resolved": "https://registry.npmjs.org/tinypool/-/tinypool-0.8.4.tgz",
      "dev": true
    },
    "node_modules/typescript": {
      "version": "5.3.3",
      "resolved": "https://registry.npmjs.org/typescript/-/typescript-5.3.3.tgz",
      "dev": true
    },
    "node_modules/vitest": {
      "version": "1.6.0",
      "resolved": "https://registry.npmjs.org/vitest/-/vitest-1.6.0.tgz",
      "dev": true
    }
  }
}
EOF

commit "2026-03-03T10:05:00+00:00" "Exchange rate providers: central bank reference feed with retries"

# --- F4: converter, invoice totals in Money, customer preferred currency ------
cat > src/lib/money/cached-rate-converter.ts <<'EOF'
import type { RateProvider } from '../../rates/rate-provider';
import { RateSnapshot } from '../../rates/rate-snapshot';
import { currencyInfo, type CurrencyCode } from './currencies';
import { Money } from './money';
import { round, type RoundingMode } from './rounding';

export interface CachedRateConverterOptions {
  /** How long a fetched rate is reused before asking the provider again. Default 15 minutes. */
  ttlMs?: number;
  /** Clock in epoch milliseconds, injectable for tests. */
  now?: () => number;
  /** Rounding applied to the converted minor-unit amount. Default half-even. */
  rounding?: RoundingMode;
}

interface CacheEntry {
  snapshot: RateSnapshot;
  expiresAt: number;
}

export const DEFAULT_RATE_TTL_MS = 15 * 60 * 1000;

/**
 * Converts Money between currencies using a RateProvider, keeping each rate
 * in memory for `ttlMs`. Concurrent requests for the same pair share a single
 * provider call, and failed lookups are never cached.
 *
 * The cache is per instance and per process: create one converter at
 * startup and hand it to whatever needs conversions.
 */
export class CachedRateConverter {
  private readonly cache = new Map<string, CacheEntry>();
  private readonly inflight = new Map<string, Promise<RateSnapshot>>();
  private readonly ttlMs: number;
  private readonly now: () => number;
  private readonly rounding: RoundingMode;

  constructor(
    private readonly provider: RateProvider,
    options: CachedRateConverterOptions = {},
  ) {
    this.ttlMs = options.ttlMs ?? DEFAULT_RATE_TTL_MS;
    this.now = options.now ?? Date.now;
    this.rounding = options.rounding ?? 'half-even';
    if (this.ttlMs < 0) throw new RangeError('ttlMs must be zero or positive');
  }

  async convert(amount: Money, target: CurrencyCode): Promise<Money> {
    if (amount.currency === target) return amount;
    const snapshot = await this.rateFor(amount.currency, target);
    return applyRate(amount, snapshot, this.rounding);
  }

  /** Cached rate for base/quote, fetching it from the provider if needed. */
  async rateFor(base: CurrencyCode, quote: CurrencyCode): Promise<RateSnapshot> {
    if (base === quote) return RateSnapshot.identity(base, new Date(this.now()));
    const key = `${base}/${quote}`;
    const cached = this.cache.get(key);
    if (cached && cached.expiresAt > this.now()) return cached.snapshot;

    const pending = this.inflight.get(key);
    if (pending) return pending;

    const request = this.provider
      .getRate(base, quote)
      .then((snapshot) => {
        this.cache.set(key, { snapshot, expiresAt: this.now() + this.ttlMs });
        return snapshot;
      })
      .finally(() => {
        this.inflight.delete(key);
      });
    this.inflight.set(key, request);
    return request;
  }
}

/**
 * Applies a rate to an amount, accounting for currencies with different
 * minor units (USD cents to JPY yen, for example).
 */
export function applyRate(amount: Money, snapshot: RateSnapshot, mode: RoundingMode = 'half-even'): Money {
  if (snapshot.base !== amount.currency) {
    throw new RangeError(`Rate ${snapshot.pair} cannot convert an amount in ${amount.currency}`);
  }
  const digitShift = currencyInfo(snapshot.quote).minorUnits - currencyInfo(amount.currency).minorUnits;
  const converted = amount.minor * snapshot.rate * 10 ** digitShift;
  return Money.ofMinor(round(converted, mode), snapshot.quote);
}
EOF

cat > src/lib/money/index.ts <<'EOF'
/**
 * Public surface of the money library. Import from 'src/lib/money' rather
 * than from individual files so internals can move freely.
 */
export { Money, CurrencyMismatchError, type MoneyJSON } from './money';
export {
  ALL_CURRENCY_CODES,
  CURRENCIES,
  UnknownCurrencyError,
  currencyInfo,
  isCurrencyCode,
  minorUnitFactor,
  parseCurrencyCode,
  type CurrencyCode,
  type CurrencyInfo,
} from './currencies';
export { round, roundDown, roundHalfEven, roundHalfUp, type RoundingMode } from './rounding';
export {
  CachedRateConverter,
  DEFAULT_RATE_TTL_MS,
  applyRate,
  type CachedRateConverterOptions,
} from './cached-rate-converter';
EOF

cat > src/customers/customer.ts <<'EOF'
import { parseCurrencyCode, type CurrencyCode } from '../lib/money';

/**
 * Customers are the parties Ledgerly bills. A customer owns zero or more
 * invoices; see src/invoices/invoice.ts.
 */
export interface Customer {
  id: number;
  name: string;
  /** VAT / tax registration number, if the customer supplied one. */
  taxId: string | null;
  /** ISO 3166-1 alpha-2 country code, upper case. */
  country: string;
  /**
   * Currency the customer prefers to see totals in. Display only: invoices
   * are still billed in their own currency. Null means no preference.
   */
  preferredCurrency: CurrencyCode | null;
  createdAt: Date;
}

/** Shape of a row in the `customers` table. */
export interface CustomerRow {
  id: number;
  name: string;
  tax_id: string | null;
  country: string;
  preferred_currency: string | null;
  created_at: Date;
}

export function customerFromRow(row: CustomerRow): Customer {
  return {
    id: row.id,
    name: row.name,
    taxId: row.tax_id,
    country: row.country.toUpperCase(),
    preferredCurrency: row.preferred_currency ? parseCurrencyCode(row.preferred_currency) : null,
    createdAt: row.created_at,
  };
}

/** Name shown in admin tables, e.g. "Acme GmbH (DE123456789)". */
export function displayName(customer: Customer): string {
  return customer.taxId ? `${customer.name} (${customer.taxId})` : customer.name;
}
EOF

cat > src/invoices/invoice.ts <<'EOF'
import type { Customer } from '../customers/customer';
import { Money, parseCurrencyCode, type CurrencyCode } from '../lib/money';

export type InvoiceStatus = 'draft' | 'sent' | 'paid' | 'void';

/** One billable line on an invoice. Prices are in major units of the invoice currency. */
export interface InvoiceLine {
  description: string;
  quantity: number;
  unitPrice: number;
}

export interface Invoice {
  id: number;
  customerId: Customer['id'];
  /** Human-facing invoice number, unique across the account, e.g. "INV-2026-0042". */
  number: string;
  status: InvoiceStatus;
  /** Currency every line on this invoice is priced and billed in. */
  currency: CurrencyCode;
  /** ISO dates (YYYY-MM-DD); null while the invoice is a draft. */
  issuedOn: string | null;
  dueOn: string | null;
  lines: InvoiceLine[];
}

/** Shape of a row in the `invoices` table. */
export interface InvoiceRow {
  id: number;
  customer_id: number;
  number: string;
  status: InvoiceStatus;
  currency: string;
  issued_on: string | null;
  due_on: string | null;
}

/** Shape of a row in the `invoice_lines` table. NUMERIC columns arrive as strings. */
export interface InvoiceLineRow {
  invoice_id: number;
  description: string;
  quantity: string;
  unit_price: string;
  position: number;
}

export function invoiceFromRow(row: InvoiceRow, lineRows: readonly InvoiceLineRow[]): Invoice {
  return {
    id: row.id,
    customerId: row.customer_id,
    number: row.number,
    status: row.status,
    currency: parseCurrencyCode(row.currency),
    issuedOn: row.issued_on,
    dueOn: row.due_on,
    lines: [...lineRows]
      .sort((a, b) => a.position - b.position)
      .map((line) => ({
        description: line.description,
        quantity: Number(line.quantity),
        unitPrice: Number(line.unit_price),
      })),
  };
}

/** quantity x unit price, rounded to the minor unit of `currency`. */
export function lineAmount(line: InvoiceLine, currency: CurrencyCode): Money {
  return Money.fromMajor(line.quantity * line.unitPrice, currency);
}

/**
 * Invoice total in the invoice currency. Each line is rounded before
 * summing, matching what is printed on the invoice line by line.
 */
export function totalOf(lines: readonly InvoiceLine[], currency: CurrencyCode): Money {
  return Money.sum(
    lines.map((line) => lineAmount(line, currency)),
    currency,
  );
}

/** A sent invoice whose due date is before `today` (YYYY-MM-DD). */
export function isOverdue(invoice: Invoice, today: string): boolean {
  return invoice.status === 'sent' && invoice.dueOn !== null && invoice.dueOn < today;
}
EOF

cat > src/invoices/invoice-service.ts <<'EOF'
import type { Db } from '../db/client';
import { customerFromRow, type Customer, type CustomerRow } from '../customers/customer';
import { Money, type CachedRateConverter, type CurrencyCode } from '../lib/money';
import {
  invoiceFromRow,
  totalOf,
  type Invoice,
  type InvoiceLineRow,
  type InvoiceRow,
} from './invoice';

export interface InvoiceSummary {
  invoice: Invoice;
  customer: Customer;
  /** Total in the invoice's own currency. This is the amount actually billed. */
  total: Money;
  /**
   * Total expressed in the customer's preferred currency, for display only.
   * Equal to `total` when the customer has no preference or it matches.
   */
  displayTotal: Money;
}

/**
 * Read-side operations on invoices, plus draft cleanup for the purge job.
 *
 * The converter is optional so callers that never convert (the purge-drafts
 * job) do not need a rate provider. Without one, summaries show totals in the
 * invoice currency only and balances cannot be converted.
 */
export class InvoiceService {
  constructor(
    private readonly db: Db,
    private readonly converter?: CachedRateConverter,
  ) {}

  async findById(id: number): Promise<Invoice | null> {
    const [row] = await this.db.query<InvoiceRow>('SELECT * FROM invoices WHERE id = $1', [id]);
    if (!row) return null;
    const lines = await this.db.query<InvoiceLineRow>(
      'SELECT * FROM invoice_lines WHERE invoice_id = $1',
      [id],
    );
    return invoiceFromRow(row, lines);
  }

  async listForCustomer(customerId: number): Promise<Invoice[]> {
    const rows = await this.db.query<InvoiceRow>(
      'SELECT * FROM invoices WHERE customer_id = $1 ORDER BY created_at DESC',
      [customerId],
    );
    return this.withLines(rows);
  }

  async summarize(id: number): Promise<InvoiceSummary | null> {
    const invoice = await this.findById(id);
    if (!invoice) return null;
    return this.toSummary(invoice);
  }

  async listRecentSummaries(limit = 50): Promise<InvoiceSummary[]> {
    const rows = await this.db.query<InvoiceRow>(
      'SELECT * FROM invoices ORDER BY created_at DESC LIMIT $1',
      [limit],
    );
    const invoices = await this.withLines(rows);
    return Promise.all(invoices.map((invoice) => this.toSummary(invoice)));
  }

  /**
   * Amount the customer still owes, converted into `currency`. Only sent
   * invoices count: drafts have not been billed yet and void invoices never
   * will be.
   */
  async outstandingBalance(customerId: number, currency: CurrencyCode): Promise<Money> {
    const invoices = await this.listForCustomer(customerId);
    let balance = Money.zero(currency);
    for (const invoice of invoices) {
      if (invoice.status !== 'sent') continue;
      balance = balance.add(await this.convertTo(totalOf(invoice.lines, invoice.currency), currency));
    }
    return balance;
  }

  /** Removes drafts nobody has touched for `days` days. Returns how many were removed. */
  async deleteDraftsOlderThan(days: number): Promise<number> {
    const rows = await this.db.query<{ id: number }>(
      `DELETE FROM invoices
        WHERE status = 'draft' AND created_at < now() - ($1 || ' days')::interval
        RETURNING id`,
      [days],
    );
    return rows.length;
  }

  private async toSummary(invoice: Invoice): Promise<InvoiceSummary> {
    const [customerRow] = await this.db.query<CustomerRow>(
      'SELECT * FROM customers WHERE id = $1',
      [invoice.customerId],
    );
    if (!customerRow) {
      throw new Error(`Invoice ${invoice.number} references missing customer ${invoice.customerId}`);
    }
    const customer = customerFromRow(customerRow);
    const total = totalOf(invoice.lines, invoice.currency);
    const preferred = customer.preferredCurrency ?? invoice.currency;
    const displayTotal = this.converter ? await this.convertTo(total, preferred) : total;
    return { invoice, customer, total, displayTotal };
  }

  private async convertTo(amount: Money, currency: CurrencyCode): Promise<Money> {
    if (amount.currency === currency) return amount;
    if (!this.converter) {
      throw new Error(
        `InvoiceService was created without a rate converter; cannot convert ${amount.currency} to ${currency}`,
      );
    }
    return this.converter.convert(amount, currency);
  }

  private async withLines(rows: readonly InvoiceRow[]): Promise<Invoice[]> {
    if (rows.length === 0) return [];
    const lines = await this.db.query<InvoiceLineRow>(
      'SELECT * FROM invoice_lines WHERE invoice_id = ANY($1)',
      [rows.map((row) => row.id)],
    );
    return rows.map((row) => invoiceFromRow(row, lines.filter((line) => line.invoice_id === row.id)));
  }
}
EOF

cat > src/admin/pages/invoices-page.tsx <<'EOF'
import { displayName } from '../../customers/customer';
import { isOverdue } from '../../invoices/invoice';
import type { InvoiceSummary } from '../../invoices/invoice-service';
import { formatAmount } from '../../lib/format';
import { AdminLayout } from '../layout';

export interface InvoicesPageProps {
  summaries: InvoiceSummary[];
  /** Overrides "today" for overdue highlighting; YYYY-MM-DD. */
  today?: string;
}

export function InvoicesPage({ summaries, today = new Date().toISOString().slice(0, 10) }: InvoicesPageProps) {
  return (
    <AdminLayout title="Invoices">
      <table className="data-table">
        <thead>
          <tr>
            <th>Number</th>
            <th>Customer</th>
            <th>Status</th>
            <th>Due</th>
            <th>Currency</th>
            <th className="num">Total</th>
          </tr>
        </thead>
        <tbody>
          {summaries.map(({ invoice, customer, total, displayTotal }) => (
            <tr key={invoice.id} className={isOverdue(invoice, today) ? 'overdue' : undefined}>
              <td>
                <a href={`/api/invoices/${invoice.id}`}>{invoice.number}</a>
              </td>
              <td>{displayName(customer)}</td>
              <td>{invoice.status}</td>
              <td>{invoice.dueOn ?? '—'}</td>
              <td>{invoice.currency}</td>
              <td className="num">
                {formatAmount(total)}
                {!displayTotal.equals(total) && (
                  <span className="converted" title={`Shown in ${customer.name}'s preferred currency`}>
                    {' '}
                    ≈ {formatAmount(displayTotal)}
                  </span>
                )}
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </AdminLayout>
  );
}
EOF

cat > src/routes.ts <<'EOF'
import type { Db } from './db/client';
import { app } from './app';
import { renderPage } from './admin/render';
import { CustomersPage } from './admin/pages/customers-page';
import { InvoicesPage } from './admin/pages/invoices-page';
import { customerFromRow, type CustomerRow } from './customers/customer';
import { searchCustomers } from './customers/customer-search';
import { InvoiceService } from './invoices/invoice-service';
import { CachedRateConverter, parseCurrencyCode } from './lib/money';

export type HttpMethod = 'GET' | 'POST' | 'PUT' | 'DELETE';

/** Everything a handler receives for one request. */
export interface RouteContext {
  db: Db;
  params: Record<string, string>;
  query: URLSearchParams;
  body: unknown;
}

export interface RouteDefinition {
  method: HttpMethod;
  /** Express-style pattern; `:name` segments populate `params`. First match wins. */
  path: string;
  /** Return a string to send HTML, anything else is sent as JSON; null means 404. */
  handler: (ctx: RouteContext) => Promise<unknown>;
}

async function listCustomers(db: Db) {
  const rows = await db.query<CustomerRow>('SELECT * FROM customers ORDER BY lower(name)');
  return rows.map(customerFromRow);
}

/**
 * The converter server.ts puts on app.locals at startup. Handlers must not
 * build their own: the rate cache only helps if it is shared.
 */
function rateConverter(): CachedRateConverter {
  const converter = app.locals.converter;
  if (!(converter instanceof CachedRateConverter)) {
    throw new Error('app.locals.converter is not set; start the app through startServer()');
  }
  return converter;
}

async function customerRows(db: Db) {
  const service = new InvoiceService(db, rateConverter());
  const customers = await listCustomers(db);
  return Promise.all(
    customers.map(async (customer) => ({
      customer,
      outstanding: await service.outstandingBalance(customer.id, customer.preferredCurrency ?? 'USD'),
    })),
  );
}

export const routes: RouteDefinition[] = [
  { method: 'GET', path: '/api/health', handler: async () => ({ ok: true, startedAt: app.locals.startedAt ?? null }) },

  // Customers
  { method: 'GET', path: '/api/customers', handler: ({ db }) => listCustomers(db) },
  {
    // Must stay above /api/customers/:id so "search" is not read as an id.
    method: 'GET',
    path: '/api/customers/search',
    handler: ({ db, query }) =>
      searchCustomers(db, query.get('q') ?? '', {
        limit: query.has('limit') ? Number(query.get('limit')) : undefined,
        country: query.get('country') ?? undefined,
      }),
  },
  {
    method: 'GET',
    path: '/api/customers/:id',
    handler: async ({ db, params }) => {
      const [row] = await db.query<CustomerRow>('SELECT * FROM customers WHERE id = $1', [
        Number(params.id),
      ]);
      return row ? customerFromRow(row) : null;
    },
  },
  {
    method: 'GET',
    path: '/api/customers/:id/invoices',
    handler: ({ db, params }) => new InvoiceService(db).listForCustomer(Number(params.id)),
  },
  {
    // ?currency=EUR converts the balance; defaults to USD, the historical billing currency.
    method: 'GET',
    path: '/api/customers/:id/balance',
    handler: async ({ db, params, query }) => ({
      balance: await new InvoiceService(db, rateConverter()).outstandingBalance(
        Number(params.id),
        parseCurrencyCode(query.get('currency') ?? 'USD'),
      ),
    }),
  },

  // Invoices
  {
    method: 'GET',
    path: '/api/invoices/:id',
    handler: ({ db, params }) => new InvoiceService(db, rateConverter()).summarize(Number(params.id)),
  },

  // Admin pages
  {
    method: 'GET',
    path: '/admin/customers',
    handler: renderPage(CustomersPage, async ({ db }) => ({ rows: await customerRows(db) })),
  },
  {
    method: 'GET',
    path: '/admin/invoices',
    handler: renderPage(InvoicesPage, async ({ db }) => ({
      summaries: await new InvoiceService(db, rateConverter()).listRecentSummaries(),
    })),
  },
];
EOF

cat > test/lib/money/cached-rate-converter.test.ts <<'EOF'
import { describe, expect, it, vi } from 'vitest';
import { CachedRateConverter, Money, applyRate, type CurrencyCode } from '../../../src/lib/money';
import type { RateProvider } from '../../../src/rates/rate-provider';
import { RateSnapshot } from '../../../src/rates/rate-snapshot';

const AS_OF = new Date('2026-03-02T15:00:00Z');

function fakeProvider(rates: Record<string, number>) {
  const getRate = vi.fn(async (base: CurrencyCode, quote: CurrencyCode): Promise<RateSnapshot> => {
    const rate = rates[`${base}/${quote}`];
    if (rate === undefined) throw new Error(`no ${base}/${quote} rate`);
    return new RateSnapshot({ base, quote, rate, asOf: AS_OF, source: 'fake' });
  });
  const getAll = vi.fn(async (): Promise<RateSnapshot[]> => []);
  return { id: 'fake', getRate, getAll } satisfies RateProvider;
}

describe('CachedRateConverter', () => {
  it('returns same-currency amounts untouched without asking the provider', async () => {
    const provider = fakeProvider({});
    const converter = new CachedRateConverter(provider);
    const amount = Money.ofMinor(1234, 'USD');
    expect(await converter.convert(amount, 'USD')).toBe(amount);
    expect(provider.getRate).not.toHaveBeenCalled();
  });

  it('converts with the provider rate', async () => {
    const converter = new CachedRateConverter(fakeProvider({ 'USD/EUR': 0.92 }));
    const converted = await converter.convert(Money.ofMinor(10_000, 'USD'), 'EUR');
    expect(converted.equals(Money.ofMinor(9_200, 'EUR'))).toBe(true);
  });

  it('accounts for different minor units', async () => {
    const converter = new CachedRateConverter(fakeProvider({ 'USD/JPY': 149.5 }));
    const converted = await converter.convert(Money.ofMinor(1234, 'USD'), 'JPY');
    expect(converted.equals(Money.ofMinor(1845, 'JPY'))).toBe(true);
  });

  it('reuses a rate until the TTL expires', async () => {
    let clock = 1_000_000;
    const provider = fakeProvider({ 'USD/EUR': 0.92 });
    const converter = new CachedRateConverter(provider, { ttlMs: 60_000, now: () => clock });

    await converter.convert(Money.ofMinor(100, 'USD'), 'EUR');
    clock += 59_999;
    await converter.convert(Money.ofMinor(200, 'USD'), 'EUR');
    expect(provider.getRate).toHaveBeenCalledTimes(1);

    clock += 2;
    await converter.convert(Money.ofMinor(300, 'USD'), 'EUR');
    expect(provider.getRate).toHaveBeenCalledTimes(2);
  });

  it('shares one provider call between concurrent requests', async () => {
    const provider = fakeProvider({ 'GBP/EUR': 1.17 });
    const converter = new CachedRateConverter(provider);
    await Promise.all([
      converter.convert(Money.ofMinor(100, 'GBP'), 'EUR'),
      converter.convert(Money.ofMinor(200, 'GBP'), 'EUR'),
      converter.convert(Money.ofMinor(300, 'GBP'), 'EUR'),
    ]);
    expect(provider.getRate).toHaveBeenCalledTimes(1);
  });

  it('does not cache failed lookups', async () => {
    const provider = fakeProvider({ 'USD/EUR': 0.92 });
    provider.getRate.mockRejectedValueOnce(new Error('feed down'));
    const converter = new CachedRateConverter(provider);

    await expect(converter.convert(Money.ofMinor(100, 'USD'), 'EUR')).rejects.toThrow('feed down');
    await expect(converter.convert(Money.ofMinor(100, 'USD'), 'EUR')).resolves.toEqual(
      Money.ofMinor(92, 'EUR'),
    );
  });
});

describe('applyRate', () => {
  it('refuses a rate for a different base currency', () => {
    const snapshot = new RateSnapshot({ base: 'EUR', quote: 'USD', rate: 1.08, asOf: AS_OF, source: 'fake' });
    expect(() => applyRate(Money.ofMinor(100, 'GBP'), snapshot)).toThrow(RangeError);
  });
});
EOF

cat > src/lib/format.ts <<'EOF'
import type { Money } from './money';

/**
 * Formats an amount for admin tables: thousands separators, the number of
 * decimals the currency uses, then the ISO code, e.g. "1,234.50 USD" or
 * "1,235 JPY". Credits keep their minus sign.
 */
export function formatAmount(m: Money): string {
  const digits = m.minorUnits;
  const number = new Intl.NumberFormat('en-US', {
    minimumFractionDigits: digits,
    maximumFractionDigits: digits,
  }).format(m.toMajor());
  return `${number} ${m.currency}`;
}
EOF

cat > src/admin/pages/customers-page.tsx <<'EOF'
import { displayName, type Customer } from '../../customers/customer';
import { formatAmount } from '../../lib/format';
import type { Money } from '../../lib/money';
import { AdminLayout } from '../layout';

export interface CustomerListRow {
  customer: Customer;
  /** Sum of sent, unpaid invoices, in the customer's preferred currency. */
  outstanding: Money;
}

export interface CustomersPageProps {
  rows: CustomerListRow[];
}

export function CustomersPage({ rows }: CustomersPageProps) {
  return (
    <AdminLayout title="Customers">
      {rows.length === 0 ? (
        <p className="empty">No customers yet.</p>
      ) : (
        <table className="data-table">
          <thead>
            <tr>
              <th>Name</th>
              <th>Country</th>
              <th>Customer since</th>
              <th className="num">Outstanding</th>
            </tr>
          </thead>
          <tbody>
            {rows.map(({ customer, outstanding }) => (
              <tr key={customer.id}>
                <td>{displayName(customer)}</td>
                <td>{customer.country}</td>
                <td>{customer.createdAt.toISOString().slice(0, 10)}</td>
                <td className="num">{formatAmount(outstanding)}</td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
    </AdminLayout>
  );
}
EOF

commit "2026-03-04T11:30:00+00:00" "Convert invoice totals to the customer's preferred currency"

# --- F5: currency settings page -----------------------------------------------
mkdir -p src/settings test/settings

cat > src/db/migrations/005_create_currency_settings.sql <<'EOF'
-- Single-row table holding account-wide currency preferences.
CREATE TABLE currency_settings (
  id                SMALLINT    PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  enabled           CHAR(3)[]   NOT NULL DEFAULT ARRAY['USD']::CHAR(3)[],
  default_currency  CHAR(3)     NOT NULL DEFAULT 'USD',
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  CHECK (default_currency = ANY (enabled))
);

INSERT INTO currency_settings (id) VALUES (1);
EOF

cat > src/settings/currency-settings.ts <<'EOF'
import type { Db } from '../db/client';
import { isCurrencyCode, type CurrencyCode } from '../lib/money';

/**
 * Account-wide currency preferences, edited on the Currencies admin page.
 *
 * `enabled` restricts which currencies can be chosen for new invoices and as
 * a preferred currency on a customer; `defaultCurrency` is preselected for
 * new invoices and must itself be enabled.
 */
export interface CurrencySettings {
  enabled: CurrencyCode[];
  defaultCurrency: CurrencyCode;
  /** Null until the settings are saved for the first time. */
  updatedAt: Date | null;
}

export type CurrencySettingsField = 'enabled' | 'defaultCurrency';

export const DEFAULT_CURRENCY_SETTINGS: Readonly<CurrencySettings> = {
  enabled: ['USD'],
  defaultCurrency: 'USD',
  updatedAt: null,
};

/** Keeps the settings form and the invoice currency picker manageable. */
export const MAX_ENABLED_CURRENCIES = 12;

export class CurrencySettingsError extends Error {
  constructor(
    readonly field: CurrencySettingsField,
    message: string,
  ) {
    super(message);
    this.name = 'CurrencySettingsError';
  }
}

interface CurrencySettingsRow {
  enabled: string[];
  default_currency: string;
  updated_at: Date;
}

function normaliseCode(value: unknown): string {
  return typeof value === 'string' ? value.trim().toUpperCase() : '';
}

/**
 * Validates untrusted input (a parsed form post or a JSON body). A single
 * checked box arrives as a string, several as an array; both are accepted.
 * Duplicates are dropped and the result is sorted.
 */
export function validateCurrencySettings(input: unknown): Pick<CurrencySettings, 'enabled' | 'defaultCurrency'> {
  if (typeof input !== 'object' || input === null) {
    throw new CurrencySettingsError('enabled', 'Settings payload is missing');
  }
  const { enabled: rawEnabled, defaultCurrency: rawDefault } = input as Record<string, unknown>;
  const list: unknown[] = Array.isArray(rawEnabled) ? rawEnabled : rawEnabled === undefined ? [] : [rawEnabled];

  const enabled: CurrencyCode[] = [];
  for (const value of list) {
    const code = normaliseCode(value);
    if (!isCurrencyCode(code)) {
      throw new CurrencySettingsError('enabled', `"${String(value)}" is not a supported currency`);
    }
    if (!enabled.includes(code)) enabled.push(code);
  }
  if (enabled.length === 0) {
    throw new CurrencySettingsError('enabled', 'Enable at least one currency');
  }
  if (enabled.length > MAX_ENABLED_CURRENCIES) {
    throw new CurrencySettingsError('enabled', `Enable at most ${MAX_ENABLED_CURRENCIES} currencies`);
  }

  const defaultCurrency = normaliseCode(rawDefault);
  if (!isCurrencyCode(defaultCurrency)) {
    throw new CurrencySettingsError('defaultCurrency', 'Choose a default currency');
  }
  if (!enabled.includes(defaultCurrency)) {
    throw new CurrencySettingsError('defaultCurrency', `${defaultCurrency} must be enabled to be the default`);
  }

  return { enabled: enabled.sort(), defaultCurrency };
}

/** Loads and saves the single currency_settings row. */
export class CurrencySettingsStore {
  constructor(private readonly db: Db) {}

  async load(): Promise<CurrencySettings> {
    const [row] = await this.db.query<CurrencySettingsRow>(
      'SELECT enabled, default_currency, updated_at FROM currency_settings WHERE id = 1',
    );
    if (!row) {
      return { ...DEFAULT_CURRENCY_SETTINGS, enabled: [...DEFAULT_CURRENCY_SETTINGS.enabled] };
    }
    const enabled = row.enabled.map((code) => code.trim()).filter(isCurrencyCode);
    const defaultCode = row.default_currency.trim();
    return {
      enabled,
      defaultCurrency: isCurrencyCode(defaultCode) ? defaultCode : DEFAULT_CURRENCY_SETTINGS.defaultCurrency,
      updatedAt: row.updated_at,
    };
  }

  /** Validates and persists; throws CurrencySettingsError on invalid input. */
  async save(input: unknown): Promise<CurrencySettings> {
    const valid = validateCurrencySettings(input);
    const [row] = await this.db.query<CurrencySettingsRow>(
      `INSERT INTO currency_settings (id, enabled, default_currency, updated_at)
       VALUES (1, $1, $2, now())
       ON CONFLICT (id) DO UPDATE
         SET enabled = EXCLUDED.enabled,
             default_currency = EXCLUDED.default_currency,
             updated_at = now()
       RETURNING enabled, default_currency, updated_at`,
      [valid.enabled, valid.defaultCurrency],
    );
    return { ...valid, updatedAt: row?.updated_at ?? new Date() };
  }
}
EOF

cat > src/admin/pages/currency-settings-page.tsx <<'EOF'
import { ALL_CURRENCY_CODES, currencyInfo } from '../../lib/money';
import type { CurrencySettings, CurrencySettingsField } from '../../settings/currency-settings';
import { AdminLayout } from '../layout';

export interface CurrencySettingsPageProps {
  settings: CurrencySettings;
  /** Validation messages from a rejected save, keyed by form field. */
  errors?: Partial<Record<CurrencySettingsField, string>>;
  /** True right after a successful save. */
  saved?: boolean;
}

/**
 * Admin page for choosing which currencies are available and which one new
 * invoices default to. Posts back to /admin/currencies.
 */
export function CurrencySettingsPage({ settings, errors = {}, saved = false }: CurrencySettingsPageProps) {
  const enabled = new Set(settings.enabled);
  return (
    <AdminLayout title="Currencies">
      {saved && <p className="flash flash-success">Currency settings saved.</p>}

      <form method="post" action="/admin/currencies" className="settings-form">
        <fieldset aria-invalid={errors.enabled ? true : undefined}>
          <legend>Enabled currencies</legend>
          <p className="hint">
            Only enabled currencies can be used on new invoices or picked as the preferred currency of a
            customer. Existing invoices keep their currency.
          </p>
          {errors.enabled && <p className="field-error">{errors.enabled}</p>}
          <ul className="checkbox-grid">
            {ALL_CURRENCY_CODES.map((code) => (
              <li key={code}>
                <label>
                  <input type="checkbox" name="enabled" value={code} defaultChecked={enabled.has(code)} />
                  <span className="code">{code}</span> {currencyInfo(code).name}
                </label>
              </li>
            ))}
          </ul>
        </fieldset>

        <div className="field" aria-invalid={errors.defaultCurrency ? true : undefined}>
          <label htmlFor="defaultCurrency">Default currency for new invoices</label>
          {errors.defaultCurrency && <p className="field-error">{errors.defaultCurrency}</p>}
          <select id="defaultCurrency" name="defaultCurrency" defaultValue={settings.defaultCurrency}>
            {ALL_CURRENCY_CODES.map((code) => (
              <option key={code} value={code}>
                {code} ({currencyInfo(code).symbol})
              </option>
            ))}
          </select>
        </div>

        <p className="meta">
          {settings.updatedAt
            ? `Last changed ${settings.updatedAt.toISOString().slice(0, 16).replace('T', ' ')} UTC`
            : 'Using built-in defaults.'}
        </p>
        <button type="submit">Save</button>
      </form>
    </AdminLayout>
  );
}
EOF

cat > src/routes.ts <<'EOF'
import type { Db } from './db/client';
import { app } from './app';
import { renderPage } from './admin/render';
import { CurrencySettingsPage } from './admin/pages/currency-settings-page';
import { CustomersPage } from './admin/pages/customers-page';
import { InvoicesPage } from './admin/pages/invoices-page';
import { customerFromRow, type CustomerRow } from './customers/customer';
import { searchCustomers } from './customers/customer-search';
import { InvoiceService } from './invoices/invoice-service';
import { CachedRateConverter, parseCurrencyCode } from './lib/money';
import { CurrencySettingsError, CurrencySettingsStore } from './settings/currency-settings';

export type HttpMethod = 'GET' | 'POST' | 'PUT' | 'DELETE';

/** Everything a handler receives for one request. */
export interface RouteContext {
  db: Db;
  params: Record<string, string>;
  query: URLSearchParams;
  body: unknown;
}

export interface RouteDefinition {
  method: HttpMethod;
  /** Express-style pattern; `:name` segments populate `params`. First match wins. */
  path: string;
  /** Return a string to send HTML, anything else is sent as JSON; null means 404. */
  handler: (ctx: RouteContext) => Promise<unknown>;
}

async function listCustomers(db: Db) {
  const rows = await db.query<CustomerRow>('SELECT * FROM customers ORDER BY lower(name)');
  return rows.map(customerFromRow);
}

/**
 * The converter server.ts puts on app.locals at startup. Handlers must not
 * build their own: the rate cache only helps if it is shared.
 */
function rateConverter(): CachedRateConverter {
  const converter = app.locals.converter;
  if (!(converter instanceof CachedRateConverter)) {
    throw new Error('app.locals.converter is not set; start the app through startServer()');
  }
  return converter;
}

async function customerRows(db: Db) {
  const service = new InvoiceService(db, rateConverter());
  const customers = await listCustomers(db);
  return Promise.all(
    customers.map(async (customer) => ({
      customer,
      outstanding: await service.outstandingBalance(customer.id, customer.preferredCurrency ?? 'USD'),
    })),
  );
}

/** POST /admin/currencies: save, then re-render the form with a flash or field errors. */
async function saveCurrencySettings(ctx: RouteContext): Promise<string> {
  const store = new CurrencySettingsStore(ctx.db);
  try {
    const settings = await store.save(ctx.body);
    return renderPage(CurrencySettingsPage, async () => ({ settings, saved: true }))(ctx);
  } catch (error) {
    if (!(error instanceof CurrencySettingsError)) throw error;
    const settings = await store.load();
    return renderPage(CurrencySettingsPage, async () => ({
      settings,
      errors: { [error.field]: error.message },
    }))(ctx);
  }
}

export const routes: RouteDefinition[] = [
  { method: 'GET', path: '/api/health', handler: async () => ({ ok: true, startedAt: app.locals.startedAt ?? null }) },

  // Customers
  { method: 'GET', path: '/api/customers', handler: ({ db }) => listCustomers(db) },
  {
    // Must stay above /api/customers/:id so "search" is not read as an id.
    method: 'GET',
    path: '/api/customers/search',
    handler: ({ db, query }) =>
      searchCustomers(db, query.get('q') ?? '', {
        limit: query.has('limit') ? Number(query.get('limit')) : undefined,
        country: query.get('country') ?? undefined,
      }),
  },
  {
    method: 'GET',
    path: '/api/customers/:id',
    handler: async ({ db, params }) => {
      const [row] = await db.query<CustomerRow>('SELECT * FROM customers WHERE id = $1', [
        Number(params.id),
      ]);
      return row ? customerFromRow(row) : null;
    },
  },
  {
    method: 'GET',
    path: '/api/customers/:id/invoices',
    handler: ({ db, params }) => new InvoiceService(db).listForCustomer(Number(params.id)),
  },
  {
    // ?currency=EUR converts the balance; defaults to USD, the historical billing currency.
    method: 'GET',
    path: '/api/customers/:id/balance',
    handler: async ({ db, params, query }) => ({
      balance: await new InvoiceService(db, rateConverter()).outstandingBalance(
        Number(params.id),
        parseCurrencyCode(query.get('currency') ?? 'USD'),
      ),
    }),
  },

  // Invoices
  {
    method: 'GET',
    path: '/api/invoices/:id',
    handler: ({ db, params }) => new InvoiceService(db, rateConverter()).summarize(Number(params.id)),
  },

  // Settings
  {
    method: 'GET',
    path: '/api/settings/currencies',
    handler: ({ db }) => new CurrencySettingsStore(db).load(),
  },

  // Admin pages
  {
    method: 'GET',
    path: '/admin/customers',
    handler: renderPage(CustomersPage, async ({ db }) => ({ rows: await customerRows(db) })),
  },
  {
    method: 'GET',
    path: '/admin/invoices',
    handler: renderPage(InvoicesPage, async ({ db }) => ({
      summaries: await new InvoiceService(db, rateConverter()).listRecentSummaries(),
    })),
  },
  {
    method: 'GET',
    path: '/admin/currencies',
    handler: renderPage(CurrencySettingsPage, async ({ db }) => ({
      settings: await new CurrencySettingsStore(db).load(),
    })),
  },
  { method: 'POST', path: '/admin/currencies', handler: saveCurrencySettings },
];
EOF

cat > test/settings/currency-settings.test.ts <<'EOF'
import { describe, expect, it } from 'vitest';
import { CurrencySettingsError, validateCurrencySettings } from '../../src/settings/currency-settings';

function fieldOf(fn: () => unknown): string | undefined {
  try {
    fn();
  } catch (error) {
    if (error instanceof CurrencySettingsError) return error.field;
    throw error;
  }
  return undefined;
}

describe('validateCurrencySettings', () => {
  it('accepts a form post with several checked boxes', () => {
    const result = validateCurrencySettings({ enabled: ['usd', 'EUR', 'EUR'], defaultCurrency: 'eur' });
    expect(result).toEqual({ enabled: ['EUR', 'USD'], defaultCurrency: 'EUR' });
  });

  it('accepts a single checked box sent as a string', () => {
    expect(validateCurrencySettings({ enabled: 'GBP', defaultCurrency: 'GBP' }).enabled).toEqual(['GBP']);
  });

  it('requires at least one enabled currency', () => {
    expect(fieldOf(() => validateCurrencySettings({ defaultCurrency: 'USD' }))).toBe('enabled');
  });

  it('rejects unsupported codes', () => {
    expect(fieldOf(() => validateCurrencySettings({ enabled: ['USD', 'XXX'], defaultCurrency: 'USD' }))).toBe(
      'enabled',
    );
  });

  it('requires the default to be one of the enabled currencies', () => {
    expect(fieldOf(() => validateCurrencySettings({ enabled: ['USD'], defaultCurrency: 'EUR' }))).toBe(
      'defaultCurrency',
    );
  });
});
EOF

cat > test/lib/money/rounding.test.ts <<'EOF'
import { describe, expect, it } from 'vitest';
import { round, roundHalfEven, roundHalfUp } from '../../../src/lib/money';

describe('roundHalfEven', () => {
  it.each([
    [0.5, 0],
    [1.5, 2],
    [2.5, 2],
    [3.5, 4],
    [-0.5, 0],
    [-1.5, -2],
    [-2.5, -2],
    [2.4999, 2],
    [2.5001, 3],
    [12.500000000000002, 12],
  ])('rounds %d to %d', (input, expected) => {
    expect(roundHalfEven(input)).toBe(expected);
  });
});

describe('roundHalfUp', () => {
  it.each([
    [2.5, 3],
    [-2.5, -3],
    [2.4, 2],
    [-0.2, 0],
  ])('rounds %d to %d', (input, expected) => {
    expect(roundHalfUp(input)).toBe(expected);
  });
});

describe('round', () => {
  it('defaults to half-even', () => {
    expect(round(2.5)).toBe(2);
    expect(round(2.5, 'half-up')).toBe(3);
  });

  it('refuses non-finite input', () => {
    expect(() => round(Number.NaN)).toThrow(RangeError);
    expect(() => round(Number.POSITIVE_INFINITY)).toThrow(RangeError);
  });
});
EOF

commit "2026-03-05T14:20:00+00:00" "Currency settings page and store"

# --- F6: persist rates, hourly refresh job ------------------------------------
mkdir -p test/rates test/jobs

cat > src/db/migrations/003_create_exchange_rates.sql <<'EOF'
-- One row per published rate. Rows are never updated in place except to
-- correct a rate the source re-published for the same timestamp.
CREATE TABLE exchange_rates (
  id              BIGSERIAL      PRIMARY KEY,
  base_currency   CHAR(3)        NOT NULL,
  quote_currency  CHAR(3)        NOT NULL,
  rate            NUMERIC(18, 8) NOT NULL CHECK (rate > 0),
  as_of           TIMESTAMPTZ    NOT NULL,
  source          TEXT           NOT NULL,
  fetched_at      TIMESTAMPTZ    NOT NULL DEFAULT now(),
  UNIQUE (base_currency, quote_currency, as_of, source)
);

CREATE INDEX exchange_rates_pair_idx
  ON exchange_rates (base_currency, quote_currency, as_of DESC);
EOF

cat > src/rates/rate-repository.ts <<'EOF'
import type { Db } from '../db/client';
import { parseCurrencyCode, type CurrencyCode } from '../lib/money';
import { RateSnapshot } from './rate-snapshot';

/** Row shape of the exchange_rates table (003_create_exchange_rates.sql). */
export interface ExchangeRateRow {
  base_currency: string;
  quote_currency: string;
  /** NUMERIC arrives from pg as a string. */
  rate: string;
  as_of: Date;
  source: string;
}

export interface RateHistoryQuery {
  /** Only rates published at or after this instant. */
  since?: Date;
  /** Maximum rows, newest first. Clamped to 1..1000. Default 90. */
  limit?: number;
}

export interface CurrencyPair {
  base: CurrencyCode;
  quote: CurrencyCode;
}

const DEFAULT_HISTORY_LIMIT = 90;
const MAX_HISTORY_LIMIT = 1000;

export function snapshotFromRow(row: ExchangeRateRow): RateSnapshot {
  return new RateSnapshot({
    base: parseCurrencyCode(row.base_currency),
    quote: parseCurrencyCode(row.quote_currency),
    rate: Number(row.rate),
    asOf: row.as_of,
    source: row.source,
  });
}

/** Stores and queries historical exchange rates. */
export class RateRepository {
  constructor(private readonly db: Db) {}

  /**
   * Upserts snapshots. Fetching the same publication twice is harmless: the
   * unique key matches and only the rate and fetched_at are refreshed.
   * Returns the number of rows written.
   */
  async save(snapshots: readonly RateSnapshot[]): Promise<number> {
    let written = 0;
    for (const snapshot of snapshots) {
      const rows = await this.db.query<{ id: number }>(
        `INSERT INTO exchange_rates (base_currency, quote_currency, rate, as_of, source)
         VALUES ($1, $2, $3, $4, $5)
         ON CONFLICT (base_currency, quote_currency, as_of, source)
         DO UPDATE SET rate = EXCLUDED.rate, fetched_at = now()
         RETURNING id`,
        [snapshot.base, snapshot.quote, snapshot.rate, snapshot.asOf, snapshot.source],
      );
      written += rows.length;
    }
    return written;
  }

  /** Rates for one pair, newest first. */
  async history(base: CurrencyCode, quote: CurrencyCode, query: RateHistoryQuery = {}): Promise<RateSnapshot[]> {
    const limit = Math.min(Math.max(Math.trunc(query.limit ?? DEFAULT_HISTORY_LIMIT), 1), MAX_HISTORY_LIMIT);
    const since = query.since ?? new Date(0);
    const rows = await this.db.query<ExchangeRateRow>(
      `SELECT base_currency, quote_currency, rate, as_of, source
         FROM exchange_rates
        WHERE base_currency = $1 AND quote_currency = $2 AND as_of >= $3
        ORDER BY as_of DESC
        LIMIT $4`,
      [base, quote, since, limit],
    );
    return rows.map(snapshotFromRow);
  }

  /** Every pair with at least one stored rate, alphabetically. */
  async knownPairs(): Promise<CurrencyPair[]> {
    const rows = await this.db.query<{ base_currency: string; quote_currency: string }>(
      'SELECT DISTINCT base_currency, quote_currency FROM exchange_rates ORDER BY 1, 2',
    );
    return rows.map((row) => ({
      base: parseCurrencyCode(row.base_currency),
      quote: parseCurrencyCode(row.quote_currency),
    }));
  }

  /** Deletes rates published before `cutoff`. Returns how many were removed. */
  async deleteOlderThan(cutoff: Date): Promise<number> {
    const rows = await this.db.query<{ id: number }>(
      'DELETE FROM exchange_rates WHERE as_of < $1 RETURNING id',
      [cutoff],
    );
    return rows.length;
  }
}
EOF

cat > src/jobs/refresh-rates.ts <<'EOF'
import { CentralBankProvider } from '../rates/central-bank-provider';
import type { RateProvider } from '../rates/rate-provider';
import { RateRepository } from '../rates/rate-repository';
import type { JobContext } from './job';

/** Stored rates older than this are pruned on every run. */
export const RATE_RETENTION_DAYS = 400;

const DAY_MS = 86_400_000;

/**
 * Fetches every rate the provider publishes and stores it. The central bank
 * publishes once per working day, so most hourly runs just re-confirm the
 * rates already stored; the upsert makes that cheap.
 */
export function createRefreshRatesJob(provider: RateProvider = new CentralBankProvider()) {
  return async function refreshRates({ db, now, log }: JobContext): Promise<void> {
    const repository = new RateRepository(db);
    const snapshots = await provider.getAll();
    const saved = await repository.save(snapshots);
    const pruned = await repository.deleteOlderThan(new Date(now.getTime() - RATE_RETENTION_DAYS * DAY_MS));
    log(`refresh-rates: stored ${saved} rate(s) from ${provider.id}, pruned ${pruned}`);
  };
}

export const refreshRates = createRefreshRatesJob();

export default refreshRates;
EOF

cat > test/rates/central-bank-provider.test.ts <<'EOF'
import { describe, expect, it, vi } from 'vitest';
import { CentralBankProvider } from '../../src/rates/central-bank-provider';
import { RateUnavailableError } from '../../src/rates/rate-provider';

const FEED = JSON.stringify({
  base: 'EUR',
  date: '2026-03-02',
  rates: { USD: 1.0842, GBP: 0.8551, JPY: 162.31, XAU: 0.00041 },
});

function respondWith(body: string, status = 200) {
  return vi.fn(async () => new Response(body, { status }));
}

describe('CentralBankProvider', () => {
  it('parses supported currencies and ignores the rest', async () => {
    const provider = new CentralBankProvider({ fetchImpl: respondWith(FEED), retries: 0 });
    const all = await provider.getAll();
    expect(all.map((snapshot) => snapshot.quote).sort()).toEqual(['GBP', 'JPY', 'USD']);
    expect(all.every((snapshot) => snapshot.base === 'EUR' && snapshot.source === 'central-bank')).toBe(true);
    expect(all[0]?.asOf.toISOString()).toBe('2026-03-02T15:00:00.000Z');
  });

  it('serves EUR legs directly', async () => {
    const provider = new CentralBankProvider({ fetchImpl: respondWith(FEED), retries: 0 });
    expect((await provider.getRate('EUR', 'USD')).rate).toBe(1.0842);
  });

  it('inverts when EUR is the quote currency', async () => {
    const provider = new CentralBankProvider({ fetchImpl: respondWith(FEED), retries: 0 });
    expect((await provider.getRate('USD', 'EUR')).rate).toBeCloseTo(1 / 1.0842, 10);
  });

  it('does not retry client errors', async () => {
    const fetchImpl = respondWith('not found', 404);
    const provider = new CentralBankProvider({ fetchImpl, retries: 3, minRetryDelayMs: 0 });
    await expect(provider.getRate('EUR', 'USD')).rejects.toBeInstanceOf(RateUnavailableError);
    expect(fetchImpl).toHaveBeenCalledTimes(1);
  });

  it('retries server errors', async () => {
    const fetchImpl = vi
      .fn(async () => new Response(FEED, { status: 200 }))
      .mockResolvedValueOnce(new Response('unavailable', { status: 503 }));
    const provider = new CentralBankProvider({ fetchImpl, retries: 2, minRetryDelayMs: 0 });
    expect((await provider.getRate('EUR', 'GBP')).rate).toBe(0.8551);
    expect(fetchImpl).toHaveBeenCalledTimes(2);
  });
});
EOF

cat > test/jobs/refresh-rates.test.ts <<'EOF'
import { describe, expect, it, vi } from 'vitest';
import type { Db } from '../../src/db/client';
import { RATE_RETENTION_DAYS, createRefreshRatesJob } from '../../src/jobs/refresh-rates';
import { RateSnapshot } from '../../src/rates/rate-snapshot';

const AS_OF = new Date('2026-03-06T15:00:00Z');

describe('refresh-rates job', () => {
  it('stores every published rate and prunes old ones', async () => {
    const snapshots = [
      new RateSnapshot({ base: 'EUR', quote: 'USD', rate: 1.0842, asOf: AS_OF, source: 'fake' }),
      new RateSnapshot({ base: 'EUR', quote: 'GBP', rate: 0.8551, asOf: AS_OF, source: 'fake' }),
    ];
    const provider = { id: 'fake', getAll: vi.fn(async () => snapshots), getRate: vi.fn() };

    const queries: Array<{ sql: string; params: readonly unknown[] }> = [];
    const db: Db = {
      async query<T>(sql: string, params: readonly unknown[] = []): Promise<T[]> {
        queries.push({ sql, params });
        return (sql.startsWith('INSERT') ? [{ id: queries.length }] : [{ id: 1 }, { id: 2 }, { id: 3 }]) as T[];
      },
    };
    const log = vi.fn();
    const now = new Date('2026-03-06T16:15:00Z');

    await createRefreshRatesJob(provider)({ db, now, log });

    expect(queries.filter((q) => q.sql.startsWith('INSERT'))).toHaveLength(2);
    const prune = queries.find((q) => q.sql.startsWith('DELETE'));
    expect(prune?.params[0]).toEqual(new Date(now.getTime() - RATE_RETENTION_DAYS * 86_400_000));
    expect(log).toHaveBeenCalledWith('refresh-rates: stored 2 rate(s) from fake, pruned 3');
  });
});
EOF

cat > src/server.ts <<'EOF'
import { createServer, type IncomingMessage, type ServerResponse } from 'node:http';
import { app } from './app';
import { createDb, type Db } from './db/client';
import { CachedRateConverter } from './lib/money';
import { CentralBankProvider } from './rates/central-bank-provider';
import { routes, type RouteContext, type RouteDefinition } from './routes';

interface Match {
  route: RouteDefinition;
  params: Record<string, string>;
}

/** Finds the first route whose method and path pattern match. */
export function matchRoute(method: string, pathname: string): Match | null {
  const actual = pathname.split('/');
  for (const route of routes) {
    if (route.method !== method) continue;
    const pattern = route.path.split('/');
    if (pattern.length !== actual.length) continue;
    const params: Record<string, string> = {};
    const matched = pattern.every((segment, i) => {
      const value = actual[i] ?? '';
      if (segment.startsWith(':')) {
        params[segment.slice(1)] = decodeURIComponent(value);
        return true;
      }
      return segment === value;
    });
    if (matched) return { route, params };
  }
  return null;
}

/** Repeated form fields (checkbox groups) become arrays. */
function formToObject(raw: string): Record<string, string | string[]> {
  const out: Record<string, string | string[]> = {};
  for (const [key, value] of new URLSearchParams(raw)) {
    const existing = out[key];
    out[key] = existing === undefined ? value : Array.isArray(existing) ? [...existing, value] : [existing, value];
  }
  return out;
}

async function readBody(req: IncomingMessage): Promise<unknown> {
  const chunks: Buffer[] = [];
  for await (const chunk of req) chunks.push(chunk as Buffer);
  if (chunks.length === 0) return undefined;
  const raw = Buffer.concat(chunks).toString('utf8');
  const type = req.headers['content-type'] ?? '';
  if (type.includes('application/json')) return JSON.parse(raw);
  if (type.includes('application/x-www-form-urlencoded')) return formToObject(raw);
  return raw;
}

function send(res: ServerResponse, status: number, payload: unknown): void {
  if (typeof payload === 'string') {
    res.writeHead(status, { 'content-type': 'text/html; charset=utf-8' });
    res.end(`<!doctype html>${payload}`);
    return;
  }
  res.writeHead(status, { 'content-type': 'application/json' });
  res.end(JSON.stringify(payload ?? null));
}

export function startServer(db: Db, port = Number(process.env.PORT ?? 3000)) {
  app.locals.startedAt = new Date();
  // One converter per process, so every request shares the same rate cache.
  app.locals.converter = new CachedRateConverter(new CentralBankProvider());
  const server = createServer(async (req, res) => {
    const url = new URL(req.url ?? '/', 'http://localhost');
    const match = matchRoute(req.method ?? 'GET', url.pathname);
    if (!match) return send(res, 404, { error: 'not_found' });
    try {
      const ctx: RouteContext = {
        db,
        params: match.params,
        query: url.searchParams,
        body: await readBody(req),
      };
      const result = await match.route.handler(ctx);
      send(res, result === null ? 404 : 200, result);
    } catch (error) {
      console.error(error);
      send(res, 500, { error: 'internal_error' });
    }
  });
  server.listen(port);
  return server;
}

if (import.meta.url === `file://${process.argv[1]}`) {
  startServer(createDb(process.env.DATABASE_URL ?? 'postgres://localhost/ledgerly'));
}
EOF

commit "2026-03-06T09:50:00+00:00" "Store exchange rates and refresh them hourly"

# --- F7: rate history page ------------------------------------------------------
cat > src/admin/pages/rate-history-page.tsx <<'EOF'
import type { Db } from '../../db/client';
import { isCurrencyCode } from '../../lib/money';
import { RateRepository, type CurrencyPair } from '../../rates/rate-repository';
import type { RateSnapshot } from '../../rates/rate-snapshot';
import { AdminLayout } from '../layout';

export interface RateHistoryPageProps {
  /** Pair being shown, or null when no rates are stored yet. */
  pair: CurrencyPair | null;
  pairs: CurrencyPair[];
  /** Newest first. */
  history: RateSnapshot[];
  days: number;
}

export const RATE_HISTORY_DAYS = [7, 30, 90, 365] as const;

const DAY_MS = 86_400_000;

/** Builds page props from ?base=EUR&quote=USD&days=30, defaulting to the first stored pair. */
export async function loadRateHistoryProps(
  db: Db,
  query: URLSearchParams,
  now: Date = new Date(),
): Promise<RateHistoryPageProps> {
  const repository = new RateRepository(db);
  const pairs = await repository.knownPairs();
  const base = query.get('base') ?? '';
  const quote = query.get('quote') ?? '';
  const requested = isCurrencyCode(base) && isCurrencyCode(quote) ? { base, quote } : null;
  const pair = requested ?? pairs[0] ?? null;
  const requestedDays = Number(query.get('days') ?? 30);
  const days = (RATE_HISTORY_DAYS as readonly number[]).includes(requestedDays) ? requestedDays : 30;
  const history = pair
    ? await repository.history(pair.base, pair.quote, {
        since: new Date(now.getTime() - days * DAY_MS),
        limit: days * 2,
      })
    : [];
  return { pair, pairs, history, days };
}

function historyHref(pair: CurrencyPair, days: number): string {
  return `/admin/currencies/rates?base=${pair.base}&quote=${pair.quote}&days=${days}`;
}

function percentChange(current: RateSnapshot, previous: RateSnapshot | undefined): string {
  if (!previous) return '—';
  const change = ((current.rate - previous.rate) / previous.rate) * 100;
  return `${change >= 0 ? '+' : ''}${change.toFixed(2)}%`;
}

/** Read-only table of stored exchange rates for one currency pair. */
export function RateHistoryPage({ pair, pairs, history, days }: RateHistoryPageProps) {
  return (
    <AdminLayout title="Rate history">
      <p>
        <a href="/admin/currencies">&larr; Back to currencies</a>
      </p>

      {pairs.length === 0 || !pair ? (
        <p className="empty">No exchange rates have been stored yet. They appear after the first hourly refresh.</p>
      ) : (
        <>
          <nav className="pill-list" aria-label="Currency pairs">
            {pairs.map((candidate) => {
              const active = candidate.base === pair.base && candidate.quote === pair.quote;
              return (
                <a
                  key={`${candidate.base}/${candidate.quote}`}
                  href={historyHref(candidate, days)}
                  aria-current={active ? 'page' : undefined}
                >
                  {candidate.base}/{candidate.quote}
                </a>
              );
            })}
          </nav>

          <nav className="pill-list" aria-label="Range">
            {RATE_HISTORY_DAYS.map((range) => (
              <a key={range} href={historyHref(pair, range)} aria-current={range === days ? 'page' : undefined}>
                {range} days
              </a>
            ))}
          </nav>

          {history.length === 0 ? (
            <p className="empty">
              No {pair.base}/{pair.quote} rates in the last {days} days.
            </p>
          ) : (
            <table className="data-table">
              <thead>
                <tr>
                  <th>Published</th>
                  <th className="num">
                    {pair.quote} per {pair.base}
                  </th>
                  <th className="num">Change</th>
                  <th>Source</th>
                </tr>
              </thead>
              <tbody>
                {history.map((snapshot, i) => (
                  <tr key={`${snapshot.source}-${snapshot.asOf.toISOString()}`}>
                    <td>{snapshot.asOf.toISOString().slice(0, 10)}</td>
                    <td className="num">{snapshot.rate.toFixed(6)}</td>
                    <td className="num">{percentChange(snapshot, history[i + 1])}</td>
                    <td>{snapshot.source}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          )}
        </>
      )}
    </AdminLayout>
  );
}
EOF

cat > src/admin/pages/currency-settings-page.tsx <<'EOF'
import { ALL_CURRENCY_CODES, currencyInfo } from '../../lib/money';
import type { CurrencySettings, CurrencySettingsField } from '../../settings/currency-settings';
import { AdminLayout } from '../layout';

export interface CurrencySettingsPageProps {
  settings: CurrencySettings;
  /** Validation messages from a rejected save, keyed by form field. */
  errors?: Partial<Record<CurrencySettingsField, string>>;
  /** True right after a successful save. */
  saved?: boolean;
}

/**
 * Admin page for choosing which currencies are available and which one new
 * invoices default to. Posts back to /admin/currencies.
 */
export function CurrencySettingsPage({ settings, errors = {}, saved = false }: CurrencySettingsPageProps) {
  const enabled = new Set(settings.enabled);
  return (
    <AdminLayout title="Currencies">
      {saved && <p className="flash flash-success">Currency settings saved.</p>}

      <form method="post" action="/admin/currencies" className="settings-form">
        <fieldset aria-invalid={errors.enabled ? true : undefined}>
          <legend>Enabled currencies</legend>
          <p className="hint">
            Only enabled currencies can be used on new invoices or picked as the preferred currency of a
            customer. Existing invoices keep their currency.
          </p>
          {errors.enabled && <p className="field-error">{errors.enabled}</p>}
          <ul className="checkbox-grid">
            {ALL_CURRENCY_CODES.map((code) => (
              <li key={code}>
                <label>
                  <input type="checkbox" name="enabled" value={code} defaultChecked={enabled.has(code)} />
                  <span className="code">{code}</span> {currencyInfo(code).name}
                </label>
              </li>
            ))}
          </ul>
        </fieldset>

        <div className="field" aria-invalid={errors.defaultCurrency ? true : undefined}>
          <label htmlFor="defaultCurrency">Default currency for new invoices</label>
          {errors.defaultCurrency && <p className="field-error">{errors.defaultCurrency}</p>}
          <select id="defaultCurrency" name="defaultCurrency" defaultValue={settings.defaultCurrency}>
            {ALL_CURRENCY_CODES.map((code) => (
              <option key={code} value={code}>
                {code} ({currencyInfo(code).symbol})
              </option>
            ))}
          </select>
        </div>

        <p className="meta">
          {settings.updatedAt
            ? `Last changed ${settings.updatedAt.toISOString().slice(0, 16).replace('T', ' ')} UTC`
            : 'Using built-in defaults.'}
        </p>
        <button type="submit">Save</button>
      </form>

      <section className="related">
        <h2>Exchange rates</h2>
        <p>
          Rates are refreshed hourly from the central bank reference feed and used to show totals in each
          customer&apos;s preferred currency. <a href="/admin/currencies/rates">Rate history</a>
        </p>
      </section>
    </AdminLayout>
  );
}
EOF

cat > src/routes.ts <<'EOF'
import type { Db } from './db/client';
import { app } from './app';
import { renderPage } from './admin/render';
import { CurrencySettingsPage } from './admin/pages/currency-settings-page';
import { CustomersPage } from './admin/pages/customers-page';
import { InvoicesPage } from './admin/pages/invoices-page';
import { RateHistoryPage, loadRateHistoryProps } from './admin/pages/rate-history-page';
import { customerFromRow, type CustomerRow } from './customers/customer';
import { searchCustomers } from './customers/customer-search';
import { InvoiceService } from './invoices/invoice-service';
import { CachedRateConverter, parseCurrencyCode } from './lib/money';
import { CurrencySettingsError, CurrencySettingsStore } from './settings/currency-settings';

export type HttpMethod = 'GET' | 'POST' | 'PUT' | 'DELETE';

/** Everything a handler receives for one request. */
export interface RouteContext {
  db: Db;
  params: Record<string, string>;
  query: URLSearchParams;
  body: unknown;
}

export interface RouteDefinition {
  method: HttpMethod;
  /** Express-style pattern; `:name` segments populate `params`. First match wins. */
  path: string;
  /** Return a string to send HTML, anything else is sent as JSON; null means 404. */
  handler: (ctx: RouteContext) => Promise<unknown>;
}

async function listCustomers(db: Db) {
  const rows = await db.query<CustomerRow>('SELECT * FROM customers ORDER BY lower(name)');
  return rows.map(customerFromRow);
}

/**
 * The converter server.ts puts on app.locals at startup. Handlers must not
 * build their own: the rate cache only helps if it is shared.
 */
function rateConverter(): CachedRateConverter {
  const converter = app.locals.converter;
  if (!(converter instanceof CachedRateConverter)) {
    throw new Error('app.locals.converter is not set; start the app through startServer()');
  }
  return converter;
}

async function customerRows(db: Db) {
  const service = new InvoiceService(db, rateConverter());
  const customers = await listCustomers(db);
  return Promise.all(
    customers.map(async (customer) => ({
      customer,
      outstanding: await service.outstandingBalance(customer.id, customer.preferredCurrency ?? 'USD'),
    })),
  );
}

/** POST /admin/currencies: save, then re-render the form with a flash or field errors. */
async function saveCurrencySettings(ctx: RouteContext): Promise<string> {
  const store = new CurrencySettingsStore(ctx.db);
  try {
    const settings = await store.save(ctx.body);
    return renderPage(CurrencySettingsPage, async () => ({ settings, saved: true }))(ctx);
  } catch (error) {
    if (!(error instanceof CurrencySettingsError)) throw error;
    const settings = await store.load();
    return renderPage(CurrencySettingsPage, async () => ({
      settings,
      errors: { [error.field]: error.message },
    }))(ctx);
  }
}

export const routes: RouteDefinition[] = [
  { method: 'GET', path: '/api/health', handler: async () => ({ ok: true, startedAt: app.locals.startedAt ?? null }) },

  // Customers
  { method: 'GET', path: '/api/customers', handler: ({ db }) => listCustomers(db) },
  {
    // Must stay above /api/customers/:id so "search" is not read as an id.
    method: 'GET',
    path: '/api/customers/search',
    handler: ({ db, query }) =>
      searchCustomers(db, query.get('q') ?? '', {
        limit: query.has('limit') ? Number(query.get('limit')) : undefined,
        country: query.get('country') ?? undefined,
      }),
  },
  {
    method: 'GET',
    path: '/api/customers/:id',
    handler: async ({ db, params }) => {
      const [row] = await db.query<CustomerRow>('SELECT * FROM customers WHERE id = $1', [
        Number(params.id),
      ]);
      return row ? customerFromRow(row) : null;
    },
  },
  {
    method: 'GET',
    path: '/api/customers/:id/invoices',
    handler: ({ db, params }) => new InvoiceService(db).listForCustomer(Number(params.id)),
  },
  {
    // ?currency=EUR converts the balance; defaults to USD, the historical billing currency.
    method: 'GET',
    path: '/api/customers/:id/balance',
    handler: async ({ db, params, query }) => ({
      balance: await new InvoiceService(db, rateConverter()).outstandingBalance(
        Number(params.id),
        parseCurrencyCode(query.get('currency') ?? 'USD'),
      ),
    }),
  },

  // Invoices
  {
    method: 'GET',
    path: '/api/invoices/:id',
    handler: ({ db, params }) => new InvoiceService(db, rateConverter()).summarize(Number(params.id)),
  },

  // Settings
  {
    method: 'GET',
    path: '/api/settings/currencies',
    handler: ({ db }) => new CurrencySettingsStore(db).load(),
  },

  // Admin pages
  {
    method: 'GET',
    path: '/admin/customers',
    handler: renderPage(CustomersPage, async ({ db }) => ({ rows: await customerRows(db) })),
  },
  {
    method: 'GET',
    path: '/admin/invoices',
    handler: renderPage(InvoicesPage, async ({ db }) => ({
      summaries: await new InvoiceService(db, rateConverter()).listRecentSummaries(),
    })),
  },
  {
    method: 'GET',
    path: '/admin/currencies',
    handler: renderPage(CurrencySettingsPage, async ({ db }) => ({
      settings: await new CurrencySettingsStore(db).load(),
    })),
  },
  { method: 'POST', path: '/admin/currencies', handler: saveCurrencySettings },
  {
    method: 'GET',
    path: '/admin/currencies/rates',
    handler: renderPage(RateHistoryPage, ({ db, query }) => loadRateHistoryProps(db, query)),
  },
];
EOF

commit "2026-03-09T13:10:00+00:00" "Rate history page, linked from currency settings"

# --- F8: more tests -----------------------------------------------------------
mkdir -p test/invoices

cat > test/invoices/invoice.test.ts <<'EOF'
import { describe, expect, it } from 'vitest';
import { UnknownCurrencyError } from '../../src/lib/money';
import {
  invoiceFromRow,
  lineAmount,
  totalOf,
  type InvoiceLineRow,
  type InvoiceRow,
} from '../../src/invoices/invoice';

const ROW: InvoiceRow = {
  id: 7,
  customer_id: 3,
  number: 'INV-2026-0007',
  status: 'sent',
  currency: 'EUR',
  issued_on: '2026-02-01',
  due_on: '2026-03-01',
};

const LINES: InvoiceLineRow[] = [
  { invoice_id: 7, description: 'Second', quantity: '1.000', unit_price: '0.99', position: 2 },
  { invoice_id: 7, description: 'First', quantity: '2.000', unit_price: '12.50', position: 1 },
];

describe('invoiceFromRow', () => {
  it('orders lines by position and parses numeric columns', () => {
    const invoice = invoiceFromRow(ROW, LINES);
    expect(invoice.lines.map((line) => line.description)).toEqual(['First', 'Second']);
    expect(invoice.lines[0]).toEqual({ description: 'First', quantity: 2, unitPrice: 12.5 });
    expect(invoice.currency).toBe('EUR');
  });

  it('refuses an unknown currency code', () => {
    expect(() => invoiceFromRow({ ...ROW, currency: 'XXX' }, [])).toThrow(UnknownCurrencyError);
  });
});

describe('totalOf', () => {
  it('returns Money in the invoice currency', () => {
    const total = totalOf(invoiceFromRow(ROW, LINES).lines, 'EUR');
    expect(total.currency).toBe('EUR');
    expect(total.minor).toBe(2599);
  });

  it('respects zero-decimal currencies', () => {
    const total = totalOf([{ description: 'Consulting', quantity: 3, unitPrice: 1200 }], 'JPY');
    expect(total.minor).toBe(3600);
    expect(total.format()).toBe('¥3,600');
  });

  it('is zero for an invoice without lines', () => {
    expect(totalOf([], 'USD').isZero()).toBe(true);
  });

  it('rounds each line to the minor unit', () => {
    expect(lineAmount({ description: 'Hosting', quantity: 12, unitPrice: 9.99 }, 'USD').minor).toBe(11988);
  });
});
EOF

cat > test/invoices/invoice-service.test.ts <<'EOF'
import { describe, expect, it } from 'vitest';
import type { CustomerRow } from '../../src/customers/customer';
import type { Db } from '../../src/db/client';
import type { InvoiceLineRow, InvoiceRow } from '../../src/invoices/invoice';
import { InvoiceService } from '../../src/invoices/invoice-service';
import { CachedRateConverter, Money, type CurrencyCode } from '../../src/lib/money';
import type { RateProvider } from '../../src/rates/rate-provider';
import { RateSnapshot } from '../../src/rates/rate-snapshot';

const customers: CustomerRow[] = [
  { id: 1, name: 'Acme GmbH', tax_id: 'DE123456789', country: 'de', preferred_currency: 'EUR', created_at: new Date('2025-11-01T00:00:00Z') },
  { id: 2, name: 'Blue Fern Studio', tax_id: null, country: 'US', preferred_currency: null, created_at: new Date('2025-12-01T00:00:00Z') },
];

const invoices: InvoiceRow[] = [
  { id: 10, customer_id: 1, number: 'INV-2026-0010', status: 'sent', currency: 'USD', issued_on: '2026-02-01', due_on: '2026-03-01' },
  { id: 11, customer_id: 1, number: 'INV-2026-0011', status: 'draft', currency: 'USD', issued_on: null, due_on: null },
  { id: 12, customer_id: 1, number: 'INV-2026-0012', status: 'sent', currency: 'EUR', issued_on: '2026-02-10', due_on: '2026-03-10' },
  { id: 13, customer_id: 2, number: 'INV-2026-0013', status: 'paid', currency: 'USD', issued_on: '2026-01-05', due_on: '2026-02-05' },
];

const lines: InvoiceLineRow[] = [
  { invoice_id: 10, description: 'Design retainer', quantity: '1', unit_price: '1200.00', position: 1 },
  { invoice_id: 10, description: 'Stock photography', quantity: '3', unit_price: '15.50', position: 2 },
  { invoice_id: 11, description: 'Workshop', quantity: '1', unit_price: '800.00', position: 1 },
  { invoice_id: 12, description: 'Hosting (EU region)', quantity: '12', unit_price: '9.99', position: 1 },
  { invoice_id: 13, description: 'Logo refresh', quantity: '1', unit_price: '450.00', position: 1 },
];

/** Answers the handful of queries InvoiceService issues from the fixtures above. */
const db: Db = {
  async query<T>(sql: string, params: readonly unknown[] = []): Promise<T[]> {
    const [first] = params;
    if (sql.startsWith('SELECT * FROM invoices WHERE id')) return invoices.filter((r) => r.id === first) as T[];
    if (sql.startsWith('SELECT * FROM invoices WHERE customer_id')) {
      return invoices.filter((r) => r.customer_id === first) as T[];
    }
    if (sql.startsWith('SELECT * FROM invoice_lines WHERE invoice_id = $1')) {
      return lines.filter((r) => r.invoice_id === first) as T[];
    }
    if (sql.startsWith('SELECT * FROM invoice_lines WHERE invoice_id = ANY')) {
      const ids = first as number[];
      return lines.filter((r) => ids.includes(r.invoice_id)) as T[];
    }
    if (sql.startsWith('SELECT * FROM customers WHERE id')) return customers.filter((r) => r.id === first) as T[];
    throw new Error(`unexpected query: ${sql}`);
  },
};

const provider: RateProvider = {
  id: 'fixed',
  async getRate(base: CurrencyCode, quote: CurrencyCode) {
    if (base === 'USD' && quote === 'EUR') {
      return new RateSnapshot({ base, quote, rate: 0.9, asOf: new Date('2026-03-01T15:00:00Z'), source: 'fixed' });
    }
    throw new Error(`no ${base}/${quote}`);
  },
  async getAll() {
    return [];
  },
};

describe('InvoiceService', () => {
  const service = new InvoiceService(db, new CachedRateConverter(provider));

  it('totals invoices in their own currency', async () => {
    const summary = await service.summarize(10);
    expect(summary?.total.equals(Money.ofMinor(124_650, 'USD'))).toBe(true);
  });

  it("converts the display total into the customer's preferred currency", async () => {
    const summary = await service.summarize(10);
    expect(summary?.displayTotal.equals(Money.ofMinor(112_185, 'EUR'))).toBe(true);
  });

  it('shows the invoice currency when the customer has no preference', async () => {
    const summary = await service.summarize(13);
    expect(summary?.displayTotal).toBe(summary?.total);
  });

  it('sums only sent invoices into the outstanding balance, converting as needed', async () => {
    const balance = await service.outstandingBalance(1, 'EUR');
    expect(balance.equals(Money.ofMinor(112_185 + 11_988, 'EUR'))).toBe(true);
  });

  it('skips conversion entirely without a converter', async () => {
    const plain = new InvoiceService(db);
    const summary = await plain.summarize(10);
    expect(summary?.displayTotal.currency).toBe('USD');
    await expect(plain.outstandingBalance(1, 'EUR')).rejects.toThrow('without a rate converter');
  });
});
EOF

commit "2026-03-10T10:00:00+00:00" "Tests for invoice totals and the invoice service"

# --- F9: review feedback --------------------------------------------------------
cat > src/lib/money/money.ts <<'EOF'
import { currencyInfo, minorUnitFactor, parseCurrencyCode, type CurrencyCode } from './currencies';
import { round, type RoundingMode } from './rounding';

/**
 * Thrown when an operation combines amounts in different currencies.
 * Converting between currencies is deliberately not this module's job.
 */
export class CurrencyMismatchError extends Error {
  constructor(
    readonly left: CurrencyCode,
    readonly right: CurrencyCode,
  ) {
    super(`Cannot combine ${left} with ${right} without converting first`);
    this.name = 'CurrencyMismatchError';
  }
}

/** Serialised form used in API responses. `amount` is in minor units. */
export interface MoneyJSON {
  amount: number;
  currency: CurrencyCode;
}

/**
 * An immutable amount of money in a single currency.
 *
 * The amount is an integer number of minor units (cents, pence, yen). Never
 * build Money from a float amount of major units except through `fromMajor`,
 * which applies an explicit rounding mode.
 */
export class Money {
  private constructor(
    /** Integer amount in the currency's minor unit. */
    readonly minor: number,
    readonly currency: CurrencyCode,
  ) {}

  static ofMinor(minor: number, currency: CurrencyCode): Money {
    if (!Number.isSafeInteger(minor)) {
      throw new RangeError(`Money amount must be a safe integer of minor units, got ${minor}`);
    }
    // Normalise -0 so equals() and JSON output never disagree.
    return new Money(minor === 0 ? 0 : minor, currency);
  }

  static fromMajor(major: number, currency: CurrencyCode, mode: RoundingMode = 'half-even'): Money {
    if (!Number.isFinite(major)) {
      throw new RangeError(`Cannot create ${currency} money from ${major}`);
    }
    return Money.ofMinor(round(major * minorUnitFactor(currency), mode), currency);
  }

  static zero(currency: CurrencyCode): Money {
    return new Money(0, currency);
  }

  /** Parses "12.34 EUR" or "EUR 12.34" (code is case-insensitive). */
  static parse(input: string): Money {
    const match = /^\s*(?:([A-Za-z]{3})\s+)?(-?\d+(?:\.\d+)?)(?:\s+([A-Za-z]{3}))?\s*$/.exec(input);
    const code = match?.[1] ?? match?.[3];
    if (!match || !code || (match[1] && match[3])) {
      throw new SyntaxError(`Cannot parse money value: "${input}"`);
    }
    const currency = parseCurrencyCode(code);
    const digits = currencyInfo(currency).minorUnits;
    const [, fraction = ''] = (match[2] ?? '').split('.');
    if (fraction.length > digits) {
      throw new RangeError(`${currency} allows at most ${digits} decimal places: "${input}"`);
    }
    return Money.fromMajor(Number(match[2]), currency);
  }

  /** Sums amounts that must all be in `currency`; an empty list gives zero. */
  static sum(amounts: readonly Money[], currency: CurrencyCode): Money {
    return amounts.reduce((total, amount) => total.add(amount), Money.zero(currency));
  }

  /** Digits after the decimal separator for this amount's currency. */
  get minorUnits(): number {
    return currencyInfo(this.currency).minorUnits;
  }

  toMajor(): number {
    return this.minor / minorUnitFactor(this.currency);
  }

  add(other: Money): Money {
    this.assertSameCurrency(other);
    return Money.ofMinor(this.minor + other.minor, this.currency);
  }

  subtract(other: Money): Money {
    this.assertSameCurrency(other);
    return Money.ofMinor(this.minor - other.minor, this.currency);
  }

  multiply(factor: number, mode: RoundingMode = 'half-even'): Money {
    if (!Number.isFinite(factor)) {
      throw new RangeError(`Cannot multiply money by ${factor}`);
    }
    return Money.ofMinor(round(this.minor * factor, mode), this.currency);
  }

  negate(): Money {
    return Money.ofMinor(-this.minor, this.currency);
  }

  isZero(): boolean {
    return this.minor === 0;
  }

  isNegative(): boolean {
    return this.minor < 0;
  }

  isPositive(): boolean {
    return this.minor > 0;
  }

  equals(other: Money): boolean {
    return this.currency === other.currency && this.minor === other.minor;
  }

  compare(other: Money): -1 | 0 | 1 {
    this.assertSameCurrency(other);
    return this.minor < other.minor ? -1 : this.minor > other.minor ? 1 : 0;
  }

  /**
   * Splits the amount according to `ratios` without losing or inventing a
   * single minor unit. Leftover units go to the first parts with a non-zero
   * ratio, one each; a zero-weight part always receives exactly zero.
   *
   *   Money.ofMinor(100, 'USD').allocate([1, 1, 1]) // 34, 33, 33 cents
   */
  allocate(ratios: readonly number[]): Money[] {
    if (ratios.length === 0) {
      throw new RangeError('allocate() needs at least one ratio');
    }
    if (ratios.some((ratio) => !Number.isFinite(ratio) || ratio < 0)) {
      throw new RangeError('allocate() ratios must be finite and non-negative');
    }
    const totalRatio = ratios.reduce((sum, ratio) => sum + ratio, 0);
    if (!(totalRatio > 0)) {
      throw new RangeError('allocate() ratios must sum to a positive number');
    }
    const parts = ratios.map((ratio) => Math.floor((this.minor * ratio) / totalRatio));
    const eligible = ratios.flatMap((ratio, index) => (ratio > 0 ? [index] : []));
    let remainder = this.minor - parts.reduce((sum, part) => sum + part, 0);
    for (let i = 0; remainder > 0; i = (i + 1) % eligible.length) {
      const index = eligible[i] ?? 0;
      parts[index] = (parts[index] ?? 0) + 1;
      remainder -= 1;
    }
    return parts.map((part) => Money.ofMinor(part, this.currency));
  }

  /** Locale-aware display string, e.g. "$1,234.56" or "¥1,235". */
  format(locale = 'en-US'): string {
    return new Intl.NumberFormat(locale, {
      style: 'currency',
      currency: this.currency,
      minimumFractionDigits: this.minorUnits,
      maximumFractionDigits: this.minorUnits,
    }).format(this.toMajor());
  }

  /** Unambiguous, locale-independent form: "1234.56 USD". */
  toString(): string {
    return `${this.toMajor().toFixed(this.minorUnits)} ${this.currency}`;
  }

  toJSON(): MoneyJSON {
    return { amount: this.minor, currency: this.currency };
  }

  private assertSameCurrency(other: Money): void {
    if (other.currency !== this.currency) {
      throw new CurrencyMismatchError(this.currency, other.currency);
    }
  }
}
EOF

cat > test/lib/money/money.test.ts <<'EOF'
import { describe, expect, it } from 'vitest';
import { CurrencyMismatchError, Money } from '../../../src/lib/money';

describe('Money', () => {
  describe('construction', () => {
    it('stores amounts as integer minor units', () => {
      const amount = Money.ofMinor(1234, 'USD');
      expect(amount.minor).toBe(1234);
      expect(amount.toMajor()).toBe(12.34);
    });

    it('rejects fractional minor units', () => {
      expect(() => Money.ofMinor(12.5, 'USD')).toThrow(RangeError);
    });

    it('converts major units using the minor-unit digits of the currency', () => {
      expect(Money.fromMajor(12.34, 'USD').minor).toBe(1234);
      expect(Money.fromMajor(1234, 'JPY').minor).toBe(1234);
      expect(Money.fromMajor(1.234, 'KWD').minor).toBe(1234);
    });

    it('rejects non-finite major amounts', () => {
      expect(() => Money.fromMajor(Number.NaN, 'USD')).toThrow(RangeError);
    });

    it('rounds half to even by default', () => {
      expect(Money.fromMajor(0.125, 'USD').minor).toBe(12);
      expect(Money.fromMajor(0.135, 'USD').minor).toBe(14);
    });

    it('supports explicit rounding modes', () => {
      expect(Money.fromMajor(0.125, 'USD', 'half-up').minor).toBe(13);
      expect(Money.fromMajor(0.129, 'USD', 'down').minor).toBe(12);
    });

  });

  describe('parse', () => {
    it('accepts amount then code', () => {
      expect(Money.parse('12.34 EUR').equals(Money.ofMinor(1234, 'EUR'))).toBe(true);
    });

    it('accepts code then amount, case-insensitively', () => {
      expect(Money.parse('gbp 5').equals(Money.ofMinor(500, 'GBP'))).toBe(true);
    });

    it('rejects input it cannot read', () => {
      expect(() => Money.parse('twelve dollars')).toThrow(SyntaxError);
      expect(() => Money.parse('EUR 5 USD')).toThrow(SyntaxError);
    });
  });

  describe('arithmetic', () => {
    it('adds and subtracts in the same currency', () => {
      const a = Money.ofMinor(1050, 'EUR');
      const b = Money.ofMinor(275, 'EUR');
      expect(a.add(b).minor).toBe(1325);
      expect(a.subtract(b).minor).toBe(775);
      expect(b.subtract(a).isNegative()).toBe(true);
    });

    it('refuses to mix currencies', () => {
      expect(() => Money.ofMinor(1, 'EUR').add(Money.ofMinor(1, 'USD'))).toThrow(CurrencyMismatchError);
    });

    it('multiplies with rounding', () => {
      expect(Money.ofMinor(999, 'USD').multiply(0.5).minor).toBe(500);
      expect(Money.ofMinor(999, 'USD').multiply(0.5, 'down').minor).toBe(499);
    });

    it('sums a list, giving zero for an empty list', () => {
      const items = [Money.ofMinor(100, 'CHF'), Money.ofMinor(250, 'CHF')];
      expect(Money.sum(items, 'CHF').minor).toBe(350);
      expect(Money.sum([], 'CHF').isZero()).toBe(true);
    });
  });

  describe('allocate', () => {
    it('never loses a minor unit', () => {
      const parts = Money.ofMinor(100, 'USD').allocate([1, 1, 1]);
      expect(parts.map((part) => part.minor)).toEqual([34, 33, 33]);
    });

    it('respects uneven ratios', () => {
      const parts = Money.ofMinor(1001, 'USD').allocate([3, 7]);
      expect(parts.map((part) => part.minor)).toEqual([301, 700]);
    });

    it('handles negative amounts', () => {
      const parts = Money.ofMinor(-100, 'USD').allocate([1, 1, 1]);
      expect(parts.map((part) => part.minor)).toEqual([-33, -33, -34]);
    });

    it('never gives leftover units to zero-weight parts', () => {
      const parts = Money.ofMinor(101, 'USD').allocate([0, 1, 1]);
      expect(parts.map((part) => part.minor)).toEqual([0, 51, 50]);
    });

    it('rejects empty and negative ratios', () => {
      expect(() => Money.ofMinor(100, 'USD').allocate([])).toThrow(RangeError);
      expect(() => Money.ofMinor(100, 'USD').allocate([2, -1])).toThrow(RangeError);
    });
  });

  describe('output', () => {
    it('formats with the currency digits', () => {
      expect(Money.ofMinor(123456, 'USD').format()).toBe('$1,234.56');
      expect(Money.ofMinor(1235, 'JPY').format()).toBe('¥1,235');
    });

    it('serialises minor units and code', () => {
      expect(JSON.stringify(Money.ofMinor(500, 'EUR'))).toBe('{"amount":500,"currency":"EUR"}');
    });
  });
});
EOF

cat > src/rates/central-bank-provider.ts <<'EOF'
import { isCurrencyCode, type CurrencyCode } from '../lib/money';
import { BaseHttpProvider, type HttpProviderOptions } from './base-http-provider';
import { RateSnapshot } from './rate-snapshot';

/** Body of GET /reference-rates/latest.json */
interface ReferenceRatesResponse {
  base: string;
  /** Publication date, YYYY-MM-DD. */
  date: string;
  /** Units of each currency per one EUR. */
  rates: Record<string, unknown>;
}

export const CENTRAL_BANK_BASE_URL = 'https://rates.centralbank.example/v1';

/**
 * Daily reference rates published by the central bank, all quoted against
 * EUR. Pairs that do not involve EUR are derived by crossing the two EUR legs.
 * Rates are published once per working day around 16:00 CET; entries for
 * currencies Ledgerly does not support are ignored.
 */
export class CentralBankProvider extends BaseHttpProvider {
  readonly id = 'central-bank';

  static readonly REFERENCE_CURRENCY: CurrencyCode = 'EUR';

  constructor(options: Partial<HttpProviderOptions> = {}) {
    super({ baseUrl: CENTRAL_BANK_BASE_URL, ...options });
  }

  protected path(): string {
    return '/reference-rates/latest.json';
  }

  protected parse(body: string): RateSnapshot[] {
    const data = JSON.parse(body) as Partial<ReferenceRatesResponse>;
    const reference = CentralBankProvider.REFERENCE_CURRENCY;
    if (data.base !== reference || typeof data.date !== 'string' || typeof data.rates !== 'object') {
      throw new Error(`${this.id}: unexpected response shape`);
    }
    const asOf = new Date(`${data.date}T15:00:00Z`);
    const snapshots: RateSnapshot[] = [];
    for (const [code, rate] of Object.entries(data.rates ?? {})) {
      if (!isCurrencyCode(code) || code === reference) continue;
      // The feed occasionally publishes 0 or null for a suspended currency.
      // Skip that entry instead of failing the whole batch.
      if (typeof rate !== 'number' || !(rate > 0)) continue;
      snapshots.push(new RateSnapshot({ base: reference, quote: code, rate, asOf, source: this.id }));
    }
    return snapshots;
  }

  override async getRate(base: CurrencyCode, quote: CurrencyCode): Promise<RateSnapshot> {
    if (base === quote) return RateSnapshot.identity(base);
    const all = await this.loadAllFor(base, quote);
    const reference = CentralBankProvider.REFERENCE_CURRENCY;
    if (base === reference || quote === reference) {
      return this.pick(all, base, quote);
    }
    // Both legs are "per one EUR": 1 base = (1 / baseLeg) EUR = (quoteLeg / baseLeg) quote.
    const baseLeg = this.pick(all, reference, base);
    const quoteLeg = this.pick(all, reference, quote);
    return new RateSnapshot({
      base,
      quote,
      rate: quoteLeg.rate / baseLeg.rate,
      asOf: baseLeg.asOf < quoteLeg.asOf ? baseLeg.asOf : quoteLeg.asOf,
      source: `${this.id}:cross`,
    });
  }
}
EOF

cat > test/rates/central-bank-provider.test.ts <<'EOF'
import { describe, expect, it, vi } from 'vitest';
import { CentralBankProvider } from '../../src/rates/central-bank-provider';
import { RateUnavailableError } from '../../src/rates/rate-provider';

const FEED = JSON.stringify({
  base: 'EUR',
  date: '2026-03-02',
  rates: { USD: 1.0842, GBP: 0.8551, JPY: 162.31, XAU: 0.00041, ISK: 0 },
});

function respondWith(body: string, status = 200) {
  return vi.fn(async () => new Response(body, { status }));
}

describe('CentralBankProvider', () => {
  it('parses supported currencies and ignores the rest', async () => {
    const provider = new CentralBankProvider({ fetchImpl: respondWith(FEED), retries: 0 });
    const all = await provider.getAll();
    expect(all.map((snapshot) => snapshot.quote).sort()).toEqual(['GBP', 'JPY', 'USD']);
    expect(all.every((snapshot) => snapshot.base === 'EUR' && snapshot.source === 'central-bank')).toBe(true);
    expect(all[0]?.asOf.toISOString()).toBe('2026-03-02T15:00:00.000Z');
  });

  it('skips entries with a non-positive rate instead of failing the batch', async () => {
    const provider = new CentralBankProvider({ fetchImpl: respondWith(FEED), retries: 0 });
    const all = await provider.getAll();
    expect(all.some((snapshot) => snapshot.quote === 'ISK')).toBe(false);
  });

  it('serves EUR legs directly', async () => {
    const provider = new CentralBankProvider({ fetchImpl: respondWith(FEED), retries: 0 });
    expect((await provider.getRate('EUR', 'USD')).rate).toBe(1.0842);
  });

  it('inverts when EUR is the quote currency', async () => {
    const provider = new CentralBankProvider({ fetchImpl: respondWith(FEED), retries: 0 });
    expect((await provider.getRate('USD', 'EUR')).rate).toBeCloseTo(1 / 1.0842, 10);
  });

  it('crosses two EUR legs for pairs without EUR', async () => {
    const provider = new CentralBankProvider({ fetchImpl: respondWith(FEED), retries: 0 });
    const snapshot = await provider.getRate('USD', 'GBP');
    expect(snapshot.rate).toBeCloseTo(0.8551 / 1.0842, 10);
    expect(snapshot.source).toBe('central-bank:cross');
  });

  it('does not retry client errors', async () => {
    const fetchImpl = respondWith('not found', 404);
    const provider = new CentralBankProvider({ fetchImpl, retries: 3, minRetryDelayMs: 0 });
    await expect(provider.getRate('EUR', 'USD')).rejects.toBeInstanceOf(RateUnavailableError);
    expect(fetchImpl).toHaveBeenCalledTimes(1);
  });

  it('retries server errors', async () => {
    const fetchImpl = vi
      .fn(async () => new Response(FEED, { status: 200 }))
      .mockResolvedValueOnce(new Response('unavailable', { status: 503 }));
    const provider = new CentralBankProvider({ fetchImpl, retries: 2, minRetryDelayMs: 0 });
    expect((await provider.getRate('EUR', 'GBP')).rate).toBe(0.8551);
    expect(fetchImpl).toHaveBeenCalledTimes(2);
  });
});
EOF

cat > src/invoices/invoice-service.ts <<'EOF'
import type { Db } from '../db/client';
import { customerFromRow, type Customer, type CustomerRow } from '../customers/customer';
import { Money, type CachedRateConverter, type CurrencyCode } from '../lib/money';
import { RateUnavailableError } from '../rates/rate-provider';
import {
  invoiceFromRow,
  totalOf,
  type Invoice,
  type InvoiceLineRow,
  type InvoiceRow,
} from './invoice';

export interface InvoiceSummary {
  invoice: Invoice;
  customer: Customer;
  /** Total in the invoice's own currency. This is the amount actually billed. */
  total: Money;
  /**
   * Total expressed in the customer's preferred currency, for display only.
   * Equal to `total` when the customer has no preference, it matches, or no
   * rate is currently available.
   */
  displayTotal: Money;
}

/**
 * Read-side operations on invoices, plus draft cleanup for the purge job.
 *
 * The converter is optional so callers that never convert (the purge-drafts
 * job) do not need a rate provider. Without one, summaries show totals in the
 * invoice currency only and balances cannot be converted.
 */
export class InvoiceService {
  constructor(
    private readonly db: Db,
    private readonly converter?: CachedRateConverter,
  ) {}

  async findById(id: number): Promise<Invoice | null> {
    const [row] = await this.db.query<InvoiceRow>('SELECT * FROM invoices WHERE id = $1', [id]);
    if (!row) return null;
    const lines = await this.db.query<InvoiceLineRow>(
      'SELECT * FROM invoice_lines WHERE invoice_id = $1',
      [id],
    );
    return invoiceFromRow(row, lines);
  }

  async listForCustomer(customerId: number): Promise<Invoice[]> {
    const rows = await this.db.query<InvoiceRow>(
      'SELECT * FROM invoices WHERE customer_id = $1 ORDER BY created_at DESC',
      [customerId],
    );
    return this.withLines(rows);
  }

  async summarize(id: number): Promise<InvoiceSummary | null> {
    const invoice = await this.findById(id);
    if (!invoice) return null;
    return this.toSummary(invoice);
  }

  async listRecentSummaries(limit = 50): Promise<InvoiceSummary[]> {
    const rows = await this.db.query<InvoiceRow>(
      'SELECT * FROM invoices ORDER BY created_at DESC LIMIT $1',
      [limit],
    );
    const invoices = await this.withLines(rows);
    return Promise.all(invoices.map((invoice) => this.toSummary(invoice)));
  }

  /**
   * Amount the customer still owes, converted into `currency`. Only sent
   * invoices count: drafts have not been billed yet and void invoices never
   * will be. Unlike display totals, a missing rate is an error here.
   */
  async outstandingBalance(customerId: number, currency: CurrencyCode): Promise<Money> {
    const invoices = await this.listForCustomer(customerId);
    let balance = Money.zero(currency);
    for (const invoice of invoices) {
      if (invoice.status !== 'sent') continue;
      balance = balance.add(await this.convertTo(totalOf(invoice.lines, invoice.currency), currency));
    }
    return balance;
  }

  /** Removes drafts nobody has touched for `days` days. Returns how many were removed. */
  async deleteDraftsOlderThan(days: number): Promise<number> {
    const rows = await this.db.query<{ id: number }>(
      `DELETE FROM invoices
        WHERE status = 'draft' AND created_at < now() - ($1 || ' days')::interval
        RETURNING id`,
      [days],
    );
    return rows.length;
  }

  private async toSummary(invoice: Invoice): Promise<InvoiceSummary> {
    const [customerRow] = await this.db.query<CustomerRow>(
      'SELECT * FROM customers WHERE id = $1',
      [invoice.customerId],
    );
    if (!customerRow) {
      throw new Error(`Invoice ${invoice.number} references missing customer ${invoice.customerId}`);
    }
    const customer = customerFromRow(customerRow);
    const total = totalOf(invoice.lines, invoice.currency);
    return { invoice, customer, total, displayTotal: await this.displayTotalFor(total, customer) };
  }

  /**
   * Display conversion is best effort: if the rate feed is down, show the
   * invoice currency rather than failing the whole page.
   */
  private async displayTotalFor(total: Money, customer: Customer): Promise<Money> {
    const target = customer.preferredCurrency ?? total.currency;
    if (!this.converter || target === total.currency) return total;
    try {
      return await this.converter.convert(total, target);
    } catch (error) {
      if (error instanceof RateUnavailableError) return total;
      throw error;
    }
  }

  private async convertTo(amount: Money, currency: CurrencyCode): Promise<Money> {
    if (amount.currency === currency) return amount;
    if (!this.converter) {
      throw new Error(
        `InvoiceService was created without a rate converter; cannot convert ${amount.currency} to ${currency}`,
      );
    }
    return this.converter.convert(amount, currency);
  }

  private async withLines(rows: readonly InvoiceRow[]): Promise<Invoice[]> {
    if (rows.length === 0) return [];
    const lines = await this.db.query<InvoiceLineRow>(
      'SELECT * FROM invoice_lines WHERE invoice_id = ANY($1)',
      [rows.map((row) => row.id)],
    );
    return rows.map((row) => invoiceFromRow(row, lines.filter((line) => line.invoice_id === row.id)));
  }
}
EOF

commit "2026-03-11T16:45:00+00:00" "fix review feedback"

git checkout -q feature/multi-currency
