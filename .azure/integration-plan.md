# Integration hand-off

- **Backend:** `services/api`
  - Run: `npm run dev` (working directory `services/api`), port `3000`
  - Build: `npm run build`; health: `GET /api/v1/health`
  - Config: root `.env` (`DATABASE_URL`, `SESSION_SECRET`, `FRONTEND_ORIGIN`, `PORT`)
- **Frontend:** `services/web`
  - Flutter/Dart web client; run `flutter run -d web-server --web-hostname localhost --web-port 5000`
  - Build/verification: `flutter build web`, `flutter analyze`, `flutter test`
  - API seam: `lib/main.dart` (`Api` class); base URL is `API_BASE_URL` compile-time define, default `http://localhost:3000/api/v1`
  - Live API is wired directly; no mock client, mock datasets, duplicated local domain types, or mock-state switcher files exist.
- **Routes:** `GET /api/v1/health`; `GET /api/v1/auth/csrf`; `POST /api/v1/auth/register`; `POST /api/v1/auth/login`; `POST /api/v1/auth/logout`; `GET /api/v1/auth/me`; `GET /api/v1/categories`; `GET|POST /api/v1/transactions`; `PUT|DELETE /api/v1/transactions/:id`; `GET|POST /api/v1/budgets`; `PUT|DELETE /api/v1/budgets/:id`; `GET /api/v1/reports?from=YYYY-MM-DD&to=YYYY-MM-DD`; `POST|DELETE /api/v1/demo-data`.
- **Database:** PostgreSQL; migration `services/api/migrations/001_init.sql`; apply with `npm run migrate` from `services/api`; `DATABASE_URL`; **create schema only—NO seed data**.
- **Shared types:** no shared package; API response models are consumed in `services/web/lib/main.dart`.
- **Services:** Essential — Flutter web client, Express REST API, PostgreSQL. Enhancement — explicitly opted-in demo data.
