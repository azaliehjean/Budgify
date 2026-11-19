# Budgify Project Plan

**Status**: Approved
**Created**: 2026-11-19
**Mode**: Interactive

## 1. Project Overview

Budgify is a responsive personal finance web application built with Flutter for tracking income and expenses, managing budgets, and reviewing spending patterns. It will provide a secure, per-user account experience with a clean green-and-gray visual identity.

## 2. Goals & Requirements

- Support account registration, sign-in, and sign-out using secure cookie-based authentication.
- Provide create, read, update, and delete workflows for income and expense transactions.
- Let users categorize transactions and search, sort, and filter their transaction history.
- Support daily, weekly, and monthly budgets, with progress and remaining-budget indicators.
- Present reports and charts for income, expenses, and spending trends over selectable periods.
- Keep each user's records isolated and enforce ownership checks in the API.
- Validate inputs in both the user interface and API; provide clear loading, empty, success, and error states.
- Start each new account with no finance records. Offer optional demo data as an explicit, reversible choice.
- Work well on desktop and mobile layouts.

## 3. Architecture & Technology Stack

- **Frontend**: Flutter with Dart, targeting a responsive web application.
- **Backend**: TypeScript on Node.js with an Express REST API.
- **Database**: PostgreSQL, accessed through a typed data-access layer and versioned schema migrations.
- **Local development**: Run the frontend, API, and PostgreSQL locally. Keep configuration in environment variables and provide a non-secret example configuration for setup.
- **Application boundaries**: The browser calls the API for all persisted data. The API authenticates each request, validates payloads, applies user-scoped business rules, and reads or writes PostgreSQL records.
- **Deployment**: Local development is the first milestone. Cloud hosting and production infrastructure are intentionally deferred to a later deployment decision.

## 4. Data Model

- **User**: account identifier, normalized unique email, password hash, and creation/update timestamps.
- **Category**: owner, display name, transaction type (income or expense), and timestamps. Support suitable defaults while allowing users to manage their own categories.
- **Transaction**: owner, category, type, amount in a defined currency, transaction date, optional description, and timestamps.
- **Budget**: owner, category or overall scope, period type (daily, weekly, or monthly), amount, effective period, and timestamps.
- **Demo data**: optional sample transactions and budgets associated only with the requesting account; do not insert demo records by default.

Use database constraints and indexes for ownership references, unique account email, date-based transaction queries, and common user/category/period filters. Store monetary values as fixed-precision decimal values (not floating-point); use USD as the single account currency for the initial version.

## 5. API Design

Expose a versioned JSON REST API. Representative resource groups:

- **Authentication**: register, sign in, sign out, and retrieve the current account.
- **Transactions**: list with pagination, search, date/type/category filters and sorting; create, retrieve, update, and delete.
- **Categories**: list and manage the signed-in user's categories.
- **Budgets**: list and manage budgets, including period and category scope.
- **Reports**: return user-scoped totals and time-series/category breakdowns for selected date ranges.
- **Demo data**: provide an explicit opt-in action to create sample data, with a way to remove it without affecting non-demo records.

Validate request schemas, date ranges, supported period values, positive monetary amounts, and category ownership at the API boundary. Return consistent status codes and structured validation errors. Apply pagination to transaction lists and aggregate report data in the API/database rather than exposing another user's records.

## 6. Design System & UI

**UI Framework**: Flutter Material 3

- Use a responsive application shell with navigation for Overview, Transactions, Budgets, and Reports.
- Use a restrained green primary palette with neutral gray surfaces, accessible contrast, clear typography, and consistent spacing.
- The overview should summarize income, expenses, available balance, and active budget progress, with a recent-transactions view and report highlights.
- Provide focused forms for adding/editing transactions and budgets, with inline validation and confirmation for destructive actions.
- Include useful empty states for a new account, including clear next steps and an optional demo-data action.
- Make charts legible on small screens and provide text summaries or labels so key information is not conveyed by color alone.
- Ensure keyboard navigation, visible focus states, semantic labels, and responsive layouts across common viewport sizes.

## 7. Security & Privacy

- Store only salted password hashes using a modern password-hashing algorithm; never store or log plaintext passwords.
- Use opaque session identifiers in cookies configured `HttpOnly`, `SameSite`, and `Secure` in production. Keep local-development cookie settings appropriate to the local HTTP setup.
- Protect cookie-authenticated state-changing requests against CSRF, validate origins as appropriate, and use TLS in deployed environments.
- Enforce authentication and ownership checks on every user-data query and mutation; do not trust user identifiers supplied by the client.
- Validate and normalize all untrusted input, use parameterized database operations, and avoid returning sensitive account fields.
- Keep secrets out of source control and logs; apply sensible rate limits to authentication endpoints.

## 8. Validation & Testing

- Unit-test validation, budget-period calculations, monetary handling, and report aggregation.
- Integration-test authentication, cookie/session behavior, CRUD endpoints, validation failures, and cross-account isolation against PostgreSQL.
- Add frontend tests for key forms, filters, empty states, budget progress, and responsive navigation.
- Verify that the initial account is empty and that demo-data creation is opt-in and scoped to the current account.
- Run schema migrations and the test suite as part of local verification before considering a later deployment phase.

## 9. Delivery & Open Decisions

Deliver the local application first: establish the PostgreSQL schema and migrations, implement the API and authentication, build the responsive Flutter web client, then verify the complete user flows together.

Defer the cloud provider, hosting topology, production database service, domain, and deployment pipeline until the user is ready to plan deployment. Before that phase, confirm currency-selection requirements, whether categories are user-editable, and whether demo data should be generated in-app or supplied through a separate development-only mechanism.
