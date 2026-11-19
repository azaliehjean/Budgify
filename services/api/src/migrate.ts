import { config } from 'dotenv';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { Pool } from 'pg';

config({ path: path.resolve(__dirname, '../../../.env') });

async function main() {
  const pool = new Pool({ connectionString: process.env.DATABASE_URL });
  try {
    const sql = await readFile(path.join(__dirname, '../migrations/001_init.sql'), 'utf8');
    await pool.query(sql);
    console.log('Database migration applied.');
  } finally {
    await pool.end();
  }
}

main().catch((error: unknown) => {
  console.error('Migration failed:', error instanceof Error ? error.message : 'unknown error');
  process.exitCode = 1;
});
