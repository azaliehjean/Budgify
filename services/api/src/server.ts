import { config } from 'dotenv';
import { createHmac, randomBytes, timingSafeEqual } from 'node:crypto';
import bcrypt from 'bcryptjs';
import cookieParser from 'cookie-parser';
import cors from 'cors';
import express, { NextFunction, Request, Response } from 'express';
import rateLimit from 'express-rate-limit';
import helmet from 'helmet';
import path from 'node:path';
import { Pool } from 'pg';
import { z } from 'zod';

config({ path: path.resolve(__dirname, '../../../.env') });

const app = express();
const pool = new Pool({ connectionString: process.env.DATABASE_URL });
const isProduction = process.env.NODE_ENV === 'production';
const sessionSecret = process.env.SESSION_SECRET ?? '';
if (isProduction && sessionSecret.length < 32) {
  throw new Error('SESSION_SECRET must contain at least 32 characters in production.');
}
const sessionCookie = 'budgify_session';
const csrfCookie = 'budgify_csrf';
const sessionMaxAge = 7 * 24 * 60 * 60 * 1000;

app.disable('x-powered-by');
app.use(helmet());
app.use(cors({
  origin: process.env.FRONTEND_ORIGIN ?? 'http://localhost:5000',
  credentials: true,
  allowedHeaders: ['Content-Type', 'X-CSRF-Token'],
}));
app.use(express.json({ limit: '32kb' }));
app.use(cookieParser());

type AuthRequest = Request & { userId?: string; csrf?: string };
const hash = (value: string) => createHmac('sha256', sessionSecret || 'local-development-only-secret').update(value).digest('hex');
const cleanUser = (row: { id: string; email: string }) => ({ id: row.id, email: row.email });

function fail(res: Response, status: number, message: string, details?: unknown) {
  return res.status(status).json({ error: { message, ...(details ? { details } : {}) } });
}

function validate<T>(schema: z.ZodType<T, z.ZodTypeDef, any>, input: unknown, res: Response): T | undefined {
  const parsed = schema.safeParse(input);
  if (!parsed.success) {
    fail(res, 400, 'Please check the submitted information.', parsed.error.flatten().fieldErrors);
    return undefined;
  }
  return parsed.data;
}

function safeEqual(a: string, b: string): boolean {
  const left = Buffer.from(a);
  const right = Buffer.from(b);
  return left.length === right.length && timingSafeEqual(left, right);
}

async function requireAuth(req: AuthRequest, res: Response, next: NextFunction) {
  const token = req.cookies[sessionCookie];
  if (!token || typeof token !== 'string') return fail(res, 401, 'Please sign in to continue.');
  try {
    const result = await pool.query(
      'SELECT user_id, csrf_token FROM sessions WHERE token_hash = $1 AND expires_at > now()',
      [hash(token)],
    );
    if (!result.rowCount) return fail(res, 401, 'Your session has expired. Please sign in again.');
    req.userId = result.rows[0].user_id as string;
    req.csrf = result.rows[0].csrf_token as string;
    next();
  } catch (error) {
    next(error);
  }
}

function requireCsrf(req: AuthRequest, res: Response, next: NextFunction) {
  const origin = req.get('origin');
  if (origin && origin !== (process.env.FRONTEND_ORIGIN ?? 'http://localhost:5000')) {
    return fail(res, 403, 'Request origin is not allowed.');
  }
  const header = req.get('x-csrf-token') ?? '';
  if (!req.csrf || !safeEqual(header, req.csrf)) return fail(res, 403, 'Invalid security token. Refresh and retry.');
  next();
}

const emailSchema = z.string().trim().email().max(254).transform((value) => value.toLowerCase());
const passwordSchema = z.string().min(10).max(128);
const authLimiter = rateLimit({ windowMs: 15 * 60 * 1000, limit: 10, standardHeaders: true, legacyHeaders: false });
const positiveAmount = z.union([z.number(), z.string()]).transform((v) => Number(v))
  .refine((v) => Number.isFinite(v) && v > 0 && v <= 9999999999.99, 'Amount must be positive.')
  .transform((v) => v.toFixed(2));
const idSchema = z.string().uuid();
const dateSchema = z.string().regex(/^\d{4}-\d{2}-\d{2}$/).refine((value) => {
  const parsed = new Date(`${value}T00:00:00.000Z`);
  return !Number.isNaN(parsed.getTime()) && parsed.toISOString().slice(0, 10) === value;
}, 'Enter a valid calendar date.');

app.get('/api/v1/health', (_req, res) => res.json({ status: 'ok' }));
app.get('/api/v1/auth/csrf', async (req, res, next) => {
  try {
    const csrf = randomBytes(32).toString('hex');
    const token = req.cookies[sessionCookie] as string | undefined;
    const opts = { sameSite: 'lax' as const, secure: isProduction, path: '/' };
    if (token) {
      await pool.query('UPDATE sessions SET csrf_token = $1 WHERE token_hash = $2', [csrf, hash(token)]);
    }
    res.cookie(csrfCookie, csrf, { ...opts, httpOnly: false });
    res.json({ csrfToken: csrf });
  } catch (error) {
    next(error);
  }
});

app.post('/api/v1/auth/register', authLimiter, async (req, res, next) => {
  const input = validate(z.object({ email: emailSchema, password: passwordSchema }), req.body, res);
  if (!input) return;
  try {
    const passwordHash = await bcrypt.hash(input.password, 12);
    const client = await pool.connect();
    try {
      await client.query('BEGIN');
      const { rows } = await client.query(
        'INSERT INTO users(email, password_hash) VALUES($1,$2) RETURNING id,email',
        [input.email, passwordHash],
      );
      await client.query(
        `INSERT INTO categories(user_id,name,type) VALUES
         ($1,'Salary','income'),($1,'Other income','income'),
         ($1,'Food & dining','expense'),($1,'Transport','expense'),
         ($1,'Housing','expense'),($1,'Shopping','expense'),($1,'Other expense','expense')`,
        [rows[0].id],
      );
      await client.query('COMMIT');
      await createSession(res, rows[0]);
    } catch (error) {
      await client.query('ROLLBACK');
      if ((error as { code?: string }).code === '23505') return fail(res, 409, 'An account with this email already exists.');
      throw error;
    } finally {
      client.release();
    }
  } catch (error) { next(error); }
});

app.post('/api/v1/auth/login', authLimiter, async (req, res, next) => {
  const input = validate(z.object({ email: emailSchema, password: passwordSchema }), req.body, res);
  if (!input) return;
  try {
    const { rows } = await pool.query('SELECT id,email,password_hash FROM users WHERE email=$1', [input.email]);
    if (!rows.length || !(await bcrypt.compare(input.password, rows[0].password_hash))) {
      return fail(res, 401, 'Email or password is incorrect.');
    }
    await createSession(res, rows[0], 200);
  } catch (error) { next(error); }
});

async function createSession(res: Response, user: { id: string; email: string }, status = 201) {
  const token = randomBytes(32).toString('base64url');
  const csrf = randomBytes(32).toString('hex');
  await pool.query(
    'INSERT INTO sessions(token_hash,user_id,csrf_token,expires_at) VALUES($1,$2,$3,now()+interval \'7 days\')',
    [hash(token), user.id, csrf],
  );
  const common = { sameSite: 'lax' as const, secure: isProduction, path: '/' };
  res.cookie(sessionCookie, token, { ...common, httpOnly: true, maxAge: sessionMaxAge });
  res.cookie(csrfCookie, csrf, { ...common, httpOnly: false, maxAge: sessionMaxAge });
  res.status(status).json({ user: cleanUser(user), csrfToken: csrf });
}

app.post('/api/v1/auth/logout', requireAuth, requireCsrf, async (req: AuthRequest, res, next) => {
  try {
    await pool.query('DELETE FROM sessions WHERE token_hash=$1', [hash(req.cookies[sessionCookie] as string)]);
    const common = { sameSite: 'lax' as const, secure: isProduction, path: '/' };
    res.clearCookie(sessionCookie, { ...common, httpOnly: true });
    res.clearCookie(csrfCookie, common);
    res.status(204).end();
  } catch (error) { next(error); }
});

app.get('/api/v1/auth/me', requireAuth, async (req: AuthRequest, res, next) => {
  try {
    const { rows } = await pool.query('SELECT id,email FROM users WHERE id=$1', [req.userId]);
    if (!rows.length) return fail(res, 401, 'Please sign in to continue.');
    res.json({ user: cleanUser(rows[0]), csrfToken: req.csrf });
  } catch (error) { next(error); }
});

const transactionInput = z.object({
  categoryId: idSchema.nullable().optional(),
  type: z.enum(['income', 'expense']),
  amount: positiveAmount,
  date: dateSchema,
  description: z.string().trim().max(240).default(''),
});
const transactionFilters = z.object({
  search: z.string().max(120).optional(),
  type: z.enum(['income', 'expense']).optional(),
  categoryId: idSchema.optional(),
  from: dateSchema.optional(),
  to: dateSchema.optional(),
  sort: z.enum(['date_desc', 'date_asc', 'amount_desc', 'amount_asc']).default('date_desc'),
  page: z.coerce.number().int().min(1).default(1),
  limit: z.coerce.number().int().min(1).max(100).default(50),
}).refine((value) => !value.from || !value.to || value.from <= value.to, {
  message: 'The start date must be on or before the end date.',
  path: ['from'],
});

app.get('/api/v1/categories', requireAuth, async (req: AuthRequest, res, next) => {
  try {
    const { rows } = await pool.query(
      'SELECT id,name,type FROM categories WHERE user_id=$1 ORDER BY type,name', [req.userId],
    );
    res.json({ items: rows });
  } catch (error) { next(error); }
});

app.get('/api/v1/transactions', requireAuth, async (req: AuthRequest, res, next) => {
  const filters = validate(transactionFilters, req.query, res);
  if (!filters) return;
  try {
    const values: unknown[] = [req.userId];
    const where = ['t.user_id=$1'];
    const add = (clause: string, value: unknown) => { values.push(value); where.push(clause.replace('?', `$${values.length}`)); };
    if (filters.search) add("t.description ILIKE '%' || ? || '%'", filters.search);
    if (filters.type) add('t.type = ?', filters.type);
    if (filters.categoryId) add('t.category_id = ?', filters.categoryId);
    if (filters.from) add('t.transaction_date >= ?::date', filters.from);
    if (filters.to) add('t.transaction_date <= ?::date', filters.to);
    const order = { date_desc: 't.transaction_date DESC', date_asc: 't.transaction_date ASC', amount_desc: 't.amount DESC', amount_asc: 't.amount ASC' }[filters.sort];
    values.push(filters.limit, (filters.page - 1) * filters.limit);
    const result = await pool.query(
      `SELECT t.id,t.category_id AS "categoryId",c.name AS "categoryName",t.type,t.amount::text,t.transaction_date::text AS date,t.description,t.is_demo AS "isDemo"
       FROM transactions t LEFT JOIN categories c ON c.user_id=t.user_id AND c.id=t.category_id
       WHERE ${where.join(' AND ')} ORDER BY ${order} LIMIT $${values.length - 1} OFFSET $${values.length}`,
      values,
    );
    res.json({ items: result.rows, page: filters.page, limit: filters.limit, hasMore: result.rows.length === filters.limit });
  } catch (error) { next(error); }
});

app.post('/api/v1/transactions', requireAuth, requireCsrf, async (req: AuthRequest, res, next) => {
  const input = validate(transactionInput, req.body, res);
  if (!input) return;
  try {
    const { rows } = await pool.query(
      `INSERT INTO transactions(user_id,category_id,type,amount,transaction_date,description)
       VALUES($1,$2,$3,$4,$5,$6) RETURNING id,category_id AS "categoryId",type,amount::text,transaction_date::text AS date,description,is_demo AS "isDemo"`,
      [req.userId, input.categoryId ?? null, input.type, input.amount, input.date, input.description],
    );
    res.status(201).json({ item: rows[0] });
  } catch (error) {
    if ((error as { code?: string }).code === '23503') return fail(res, 400, 'Choose a category belonging to your account.');
    next(error);
  }
});

app.put('/api/v1/transactions/:id', requireAuth, requireCsrf, async (req: AuthRequest, res, next) => {
  const id = validate(idSchema, req.params.id, res);
  const input = validate(transactionInput, req.body, res);
  if (!id || !input) return;
  try {
    const { rows } = await pool.query(
      `UPDATE transactions SET category_id=$3,type=$4,amount=$5,transaction_date=$6,description=$7,updated_at=now()
       WHERE id=$1 AND user_id=$2
       RETURNING id,category_id AS "categoryId",type,amount::text,transaction_date::text AS date,description,is_demo AS "isDemo"`,
      [id, req.userId, input.categoryId ?? null, input.type, input.amount, input.date, input.description],
    );
    if (!rows.length) return fail(res, 404, 'Transaction not found.');
    res.json({ item: rows[0] });
  } catch (error) {
    if ((error as { code?: string }).code === '23503') return fail(res, 400, 'Choose a category belonging to your account.');
    next(error);
  }
});

app.delete('/api/v1/transactions/:id', requireAuth, requireCsrf, async (req: AuthRequest, res, next) => {
  const id = validate(idSchema, req.params.id, res);
  if (!id) return;
  try {
    const { rowCount } = await pool.query('DELETE FROM transactions WHERE id=$1 AND user_id=$2', [id, req.userId]);
    if (!rowCount) return fail(res, 404, 'Transaction not found.');
    res.status(204).end();
  } catch (error) { next(error); }
});

const budgetInput = z.object({
  categoryId: idSchema.nullable().optional(),
  period: z.enum(['daily', 'weekly', 'monthly']),
  amount: positiveAmount,
  startsOn: dateSchema,
});
app.get('/api/v1/budgets', requireAuth, async (req: AuthRequest, res, next) => {
  try {
    const { rows } = await pool.query(
      `SELECT b.id,b.category_id AS "categoryId",c.name AS "categoryName",b.period,b.amount::text,b.starts_on::text AS "startsOn",b.is_demo AS "isDemo",
        COALESCE(SUM(t.amount),0)::text AS spent
       FROM budgets b LEFT JOIN categories c ON c.user_id=b.user_id AND c.id=b.category_id
       LEFT JOIN transactions t ON t.user_id=b.user_id AND t.type='expense'
         AND (b.category_id IS NULL OR t.category_id=b.category_id)
         AND t.transaction_date >= GREATEST(
           b.starts_on,
           CASE b.period WHEN 'daily' THEN CURRENT_DATE
             WHEN 'weekly' THEN date_trunc('week',CURRENT_DATE)::date
             ELSE date_trunc('month',CURRENT_DATE)::date END
         )
         AND t.transaction_date <= CURRENT_DATE
       WHERE b.user_id=$1
       GROUP BY b.id,c.name ORDER BY b.starts_on DESC`, [req.userId],
    );
    res.json({ items: rows });
  } catch (error) { next(error); }
});
app.post('/api/v1/budgets', requireAuth, requireCsrf, async (req: AuthRequest, res, next) => {
  const input = validate(budgetInput, req.body, res);
  if (!input) return;
  try {
    if (input.categoryId) {
      const category = await pool.query(
        "SELECT 1 FROM categories WHERE id=$1 AND user_id=$2 AND type='expense'",
        [input.categoryId, req.userId],
      );
      if (!category.rowCount) return fail(res, 400, 'Choose an expense category belonging to your account.');
    }
    const { rows } = await pool.query(
      `INSERT INTO budgets(user_id,category_id,period,amount,starts_on) VALUES($1,$2,$3,$4,$5)
       RETURNING id,category_id AS "categoryId",period,amount::text,starts_on::text AS "startsOn"`,
      [req.userId, input.categoryId ?? null, input.period, input.amount, input.startsOn],
    );
    res.status(201).json({ item: rows[0] });
  } catch (error) {
    if ((error as { code?: string }).code === '23503') return fail(res, 400, 'Choose a category belonging to your account.');
    next(error);
  }
});
app.put('/api/v1/budgets/:id', requireAuth, requireCsrf, async (req: AuthRequest, res, next) => {
  const id = validate(idSchema, req.params.id, res);
  const input = validate(budgetInput, req.body, res);
  if (!id || !input) return;
  try {
    if (input.categoryId) {
      const category = await pool.query(
        "SELECT 1 FROM categories WHERE id=$1 AND user_id=$2 AND type='expense'",
        [input.categoryId, req.userId],
      );
      if (!category.rowCount) return fail(res, 400, 'Choose an expense category belonging to your account.');
    }
    const { rows } = await pool.query(
      `UPDATE budgets SET category_id=$3,period=$4,amount=$5,starts_on=$6,updated_at=now()
       WHERE id=$1 AND user_id=$2 RETURNING id,category_id AS "categoryId",period,amount::text,starts_on::text AS "startsOn"`,
      [id, req.userId, input.categoryId ?? null, input.period, input.amount, input.startsOn],
    );
    if (!rows.length) return fail(res, 404, 'Budget not found.');
    res.json({ item: rows[0] });
  } catch (error) {
    if ((error as { code?: string }).code === '23503') return fail(res, 400, 'Choose a category belonging to your account.');
    next(error);
  }
});
app.delete('/api/v1/budgets/:id', requireAuth, requireCsrf, async (req: AuthRequest, res, next) => {
  const id = validate(idSchema, req.params.id, res);
  if (!id) return;
  try {
    const { rowCount } = await pool.query('DELETE FROM budgets WHERE id=$1 AND user_id=$2', [id, req.userId]);
    if (!rowCount) return fail(res, 404, 'Budget not found.');
    res.status(204).end();
  } catch (error) { next(error); }
});

app.get('/api/v1/reports', requireAuth, async (req: AuthRequest, res, next) => {
  const range = validate(z.object({ from: dateSchema, to: dateSchema }).refine((x) => x.from <= x.to, 'Invalid date range.'), req.query, res);
  if (!range) return;
  try {
    const [totals, byCategory, timeline] = await Promise.all([
      pool.query(
        `SELECT type,COALESCE(SUM(amount),0)::text AS total FROM transactions
         WHERE user_id=$1 AND transaction_date BETWEEN $2 AND $3 GROUP BY type`, [req.userId, range.from, range.to],
      ),
      pool.query(
        `SELECT COALESCE(c.name,'Uncategorized') AS name,t.type,SUM(t.amount)::text AS total
         FROM transactions t LEFT JOIN categories c ON c.id=t.category_id AND c.user_id=t.user_id
         WHERE t.user_id=$1 AND t.transaction_date BETWEEN $2 AND $3 AND t.type='expense'
         GROUP BY c.name,t.type ORDER BY SUM(t.amount) DESC`, [req.userId, range.from, range.to],
      ),
      pool.query(
        `SELECT date_trunc('week',transaction_date)::date::text AS week,
          SUM(amount) FILTER (WHERE type='income')::text AS income,
          SUM(amount) FILTER (WHERE type='expense')::text AS expenses
         FROM transactions WHERE user_id=$1 AND transaction_date BETWEEN $2 AND $3
         GROUP BY 1 ORDER BY 1`, [req.userId, range.from, range.to],
      ),
    ]);
    res.json({ from: range.from, to: range.to, totals: totals.rows, byCategory: byCategory.rows, timeline: timeline.rows });
  } catch (error) { next(error); }
});

app.post('/api/v1/demo-data', requireAuth, requireCsrf, async (req: AuthRequest, res, next) => {
  try {
    const categories = await pool.query('SELECT id,name,type FROM categories WHERE user_id=$1', [req.userId]);
    const find = (name: string, type: string) => categories.rows.find((row) => row.name === name && row.type === type)?.id ?? null;
    const client = await pool.connect();
    try {
      await client.query('BEGIN');
      const samples: Array<[string | null, string, string, number, string]> = [
        [find('Salary', 'income'), 'income', '4200.00', 1, 'Monthly salary'],
        [find('Food & dining', 'expense'), 'expense', '84.50', 2, 'Groceries'],
        [find('Transport', 'expense'), 'expense', '32.00', 4, 'Transit pass'],
        [find('Housing', 'expense'), 'expense', '1250.00', 6, 'Rent'],
        [find('Other expense', 'expense'), 'expense', '48.75', 9, 'Dinner with friends'],
      ];
      for (const [categoryId, type, amount, daysAgo, description] of samples) {
        await client.query(
          `INSERT INTO transactions(user_id,category_id,type,amount,transaction_date,description,is_demo)
           VALUES($1,$2,$3,$4,CURRENT_DATE-$5::int,$6,true)`,
          [req.userId, categoryId, type, amount, daysAgo, description],
        );
      }
      await client.query(
        `INSERT INTO budgets(user_id,category_id,period,amount,starts_on,is_demo)
         VALUES($1,$2,'monthly',500,date_trunc('month',CURRENT_DATE)::date,true)`,
        [req.userId, find('Food & dining', 'expense')],
      );
      await client.query('COMMIT');
    } catch (error) { await client.query('ROLLBACK'); throw error; }
    finally { client.release(); }
    res.status(201).json({ message: 'Demo data added. You can remove it any time.' });
  } catch (error) { next(error); }
});
app.delete('/api/v1/demo-data', requireAuth, requireCsrf, async (req: AuthRequest, res, next) => {
  try {
    await pool.query('DELETE FROM transactions WHERE user_id=$1 AND is_demo=true', [req.userId]);
    await pool.query('DELETE FROM budgets WHERE user_id=$1 AND is_demo=true', [req.userId]);
    res.status(204).end();
  } catch (error) { next(error); }
});

app.use((_req, res) => fail(res, 404, 'Endpoint not found.'));
app.use((error: unknown, _req: Request, res: Response, _next: NextFunction) => {
  console.error('Request failed:', error instanceof Error ? error.message : 'unknown error');
  fail(res, 500, 'Something went wrong. Please try again.');
});

const port = Number(process.env.PORT ?? 3000);
const server = app.listen(port, () => console.log(`Budgify API listening on http://localhost:${port}`));
for (const signal of ['SIGINT', 'SIGTERM']) {
  process.on(signal, () => server.close(() => void pool.end()));
}
