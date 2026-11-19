# Budgify

Budgify is a responsive Flutter web app for personal finance, backed by a
TypeScript/Express API and PostgreSQL. All persisted records are private to the
signed-in account. Fresh accounts start empty; demo records are opt-in and
removable.

## Local prerequisites

- Flutter SDK (web support enabled)
- Node.js 20+ and npm
- PostgreSQL 15+

## Start the database and API

Create a local database and user (or use an existing PostgreSQL instance):

```sql
CREATE USER budgify WITH PASSWORD 'budgify';
CREATE DATABASE budgify OWNER budgify;
```

Copy `.env.example` to `.env` and set a unique `SESSION_SECRET` of at least 32
characters. Keep `.env` local; it is ignored by git.

```powershell
Set-Location services/api
npm install
npm run migrate
npm run dev
```

The API listens on `http://localhost:3000`; its health endpoint is
`GET /api/v1/health`.

## Start the Flutter web app

In another terminal:

```powershell
Set-Location services/web
flutter pub get
flutter run -d web-server --web-hostname localhost --web-port 5000
```

Open `http://localhost:5000`. To use another API URL, set
`API_BASE_URL` at build/run time, for example:

```powershell
flutter run -d web-server --web-hostname localhost --web-port 5000 --dart-define=API_BASE_URL=http://localhost:3000/api/v1
```

The API's `FRONTEND_ORIGIN` must exactly match the browser origin (default
`http://localhost:5000`) for credentialed CORS and CSRF checks.

## Verify the client

```powershell
Set-Location services/web
flutter analyze
flutter test
flutter build web
```

The API migration creates only schema; it does not seed financial records.
Registration creates a user's default income and expense categories. Use
**Try demo data** only when desired, and **Remove demo data** to undo it.

## API outline

All resource endpoints are under `/api/v1`. Authentication uses an opaque,
HttpOnly session cookie plus a CSRF token for state-changing requests.

| Method | Route | Purpose |
| --- | --- | --- |
| GET | `/health` | Health check |
| GET | `/auth/csrf` | Issue/refresh a CSRF token |
| POST | `/auth/register` | Register with email and password |
| POST | `/auth/login` | Sign in |
| POST | `/auth/logout` | Sign out |
| GET | `/auth/me` | Current account |
| GET | `/categories` | List this account's categories |
| GET, POST | `/transactions` | List (search/filter/sort/page) or create |
| PUT, DELETE | `/transactions/:id` | Update or remove an owned transaction |
| GET, POST | `/budgets` | List or create budgets |
| PUT, DELETE | `/budgets/:id` | Update or remove an owned budget |
| GET | `/reports?from=YYYY-MM-DD&to=YYYY-MM-DD` | Period totals, trends and category breakdown |
| POST, DELETE | `/demo-data` | Explicitly add or remove demo records |