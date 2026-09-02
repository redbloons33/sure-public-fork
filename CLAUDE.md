# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

This repo is a **trimmed fork** focused on running the Sure web app with Docker. The mobile app,
Helm charts, external REST API (`/api/v1`), OAuth (Doorkeeper), CI workflows, and the automated test
suite have been removed. The in-app AI assistant (chat + `/mcp` endpoint) is kept.

## Common Development Commands

### Development Server
- `bin/dev` - Start development server (Rails, Sidekiq, Tailwind CSS watcher)
- `bin/rails server` - Start Rails server only
- `bin/rails console` - Open Rails console

### Linting & Security
- `bin/rubocop` - Run Ruby linter
- `bundle exec erb_lint ./app/**/*.erb` - Run ERB linter
- `bin/brakeman --no-pager` - Run security analysis

Run these before committing:

```bash
bin/rubocop -f github -a
bundle exec erb_lint ./app/**/*.erb -a
bin/brakeman --no-pager
```

### Database
- `bin/rails db:prepare` - Create and migrate database
- `bin/rails db:migrate` - Run pending migrations
- `bin/rails db:rollback` - Rollback last migration
- `bin/rails db:seed` - Load seed data

### Setup
- `bin/setup` - Initial project setup (installs dependencies, prepares database)

## Running with Docker

Four services in `compose.yml`: `web`, `worker` (Sidekiq), `db` (Postgres 16), `redis`. The `web`
and `worker` images build locally from `Dockerfile` (`image: sure-local:latest`). See
`docs/hosting/docker.md`.

```bash
cp .env.example .env   # set SECRET_KEY_BASE and POSTGRES_PASSWORD
docker compose up -d --build
```

## General Development Rules

### Authentication Context
- Use `Current.user` for the current user. Do NOT use `current_user`.
- Use `Current.family` for the current family. Do NOT use `current_family`.

### Development Guidelines
- Carefully read project conventions and guidelines before generating any code.
- Do not run `rails server` in your responses
- Do not run `touch tmp/restart.txt`
- Do not run `rails credentials`
- Do not automatically run migrations

## High-Level Architecture

### Application Modes
The codebase runs in two distinct modes:
- **Managed**: A team operates and manages servers for users (`Rails.application.config.app_mode = "managed"`)
- **Self Hosted**: Users host the codebase on their own infrastructure via Docker Compose
  (`Rails.application.config.app_mode = "self_hosted"`). This is the default here (`SELF_HOSTED=true`).

### Core Domain Model
The application is built around financial data management with these key relationships:
- **User** → has many **Accounts** → has many **Transactions**
- **Account** types: checking, savings, credit cards, investments, crypto, loans, properties
- **Transaction** → belongs to **Category**, can have **Tags** and **Rules**
- **Investment accounts** → have **Holdings** → track **Securities** via **Trades**

### Internal request/response
- Controllers serve HTML and JSON via Turbo for SPA-like interactions
- Turbo Frames for partial page updates; Jbuilder for the few JSON responses
- Rate limiting via Rack::Attack (admin endpoints + malicious-UA blocklist)
- Authenticated CSV/report export URLs use `ApiKey` (see `app/models/api_key.rb`,
  `Settings > API key`, and `reports_controller`)

### Sync & Import System
Two primary data ingestion methods:
1. **Provider integrations** (Plaid, SimpleFIN, SnapTrade, and others): account syncing
   - A `*Item` model manages each connection (e.g. `PlaidItem`, `SimplefinItem`)
   - `Sync` tracks sync operations
   - Background jobs handle data updates
2. **CSV Import**: Manual data import with mapping
   - `Import` manages import sessions
   - Supports transaction and balance imports
   - Custom field mapping with transformation rules

### Provider Integrations: Pending Transactions and FX (SimpleFIN/Plaid)

- Detection
  - SimpleFIN: pending via `pending: true` or `posted` blank/0 + `transacted_at`.
  - Plaid: pending via Plaid `pending: true` (stored at `extra["plaid"]["pending"]` for bank/credit transactions imported via `PlaidEntry::Processor`).
- Storage: provider data on `Transaction#extra` (e.g., `extra["simplefin"]["pending"]`; FX uses `fx_from`, `fx_date`).
- UI: "Pending" badge when `transaction.pending?` is true; no badge if provider omits pendings.
- Configuration (default-on for pending)
  - SimpleFIN: `config/initializers/simplefin.rb` via `Rails.configuration.x.simplefin.*`.
  - Plaid: `config/initializers/plaid_config.rb` via `Rails.configuration.x.plaid.*`.
  - Pending transactions are fetched by default and handled via reconciliation/filtering.
  - Set `SIMPLEFIN_INCLUDE_PENDING=0` to disable pending fetching for SimpleFIN.
  - Set `PLAID_INCLUDE_PENDING=0` to disable pending fetching for Plaid.
  - Set `SIMPLEFIN_DEBUG_RAW=1` to enable raw payload debug logging.

Provider support notes:
- SimpleFIN: supports pending + FX metadata (stored under `extra["simplefin"]`).
- Plaid: supports pending when the upstream Plaid payload includes `pending: true` (stored under `extra["plaid"]`).
- Plaid investments: investment transactions currently do not store pending metadata.
- Lunchflow: does not currently store pending metadata.

### Background Processing
Sidekiq handles asynchronous tasks:
- Account syncing (`SyncJob`)
- Import processing (`ImportJob`)
- AI chat responses (`AssistantResponseJob`)
- Scheduled maintenance via sidekiq-cron

### Frontend Architecture
- **Hotwire Stack**: Turbo + Stimulus for reactive UI without heavy JavaScript
- **ViewComponents**: Reusable UI components in `app/components/`
- **Stimulus Controllers**: Handle interactivity, organized alongside components
- **Charts**: D3.js for financial visualizations (time series, donut, sankey)
- **Styling**: Tailwind CSS v4.x with custom design system
  - Design system defined in `app/assets/tailwind/maybe-design-system.css`
  - Always use functional tokens (e.g., `text-primary` not `text-white`)
  - Prefer semantic HTML elements over JS components
  - Use `icon` helper for icons, never `lucide_icon` directly
- **JS**: served via importmap (no bundler/npm). CSS via the `tailwindcss-rails` gem.
- **i18n**: All user-facing strings must use localization (i18n). Update locale files for each new or changed element.

### Internationalization (i18n) Guidelines
- **Key Organization**: Use hierarchical keys by feature: `accounts.index.title`, `transactions.form.amount_label`
- **Translation Helper**: Always use `t()` helper for user-facing strings
- **Interpolation**: Use for dynamic content: `t("users.greeting", name: user.name)`
- **Pluralization**: Use Rails pluralization: `t("transactions.count", count: @transactions.count)`
- **Locale Files**: Update `config/locales/en.yml` for new strings
- **Missing Translations**: Configure to raise errors in development for missing keys

### Multi-Currency Support
- All monetary values stored in base currency (user's primary currency)
- `Money` objects handle currency conversion and formatting
- Historical exchange rates for accurate reporting

### Security & Authentication
- Session-based auth for web users
- Optional OpenID Connect / OAuth / SAML SSO via OmniAuth (`config/initializers/omniauth.rb`, `auth.rb`)
- MFA (TOTP) support
- `ApiKey` (scoped, hashed) for authenticated report-export URLs
- `/mcp` endpoint for the external AI assistant is guarded by the `MCP_API_TOKEN` env var
- Strong parameters and CSRF protection throughout

### Testing
There is no automated test suite in this repo. Verify changes by booting the app
(`docker compose up --build` or `bin/dev`) and exercising the affected flow, and by running the
linters and `bin/brakeman`.

### Performance Considerations
- Database queries optimized with proper indexes
- N+1 queries prevented via includes/joins
- Background jobs for heavy operations
- Caching strategies for expensive calculations
- Turbo Frames for partial page updates

## Project Conventions

### Convention 1: Minimize Dependencies
- Push Rails to its limits before adding new dependencies
- Strong technical/business reason required for new dependencies
- Favor old and reliable over new and flashy

### Convention 2: Skinny Controllers, Fat Models
- Business logic in `app/models/` folder, avoid `app/services/`
- Use Rails concerns and POROs for organization
- Models should answer questions about themselves: `account.balance_series` not `AccountSeries.new(account).call`

### Convention 3: Hotwire-First Frontend
- **Native HTML preferred over JS components**
  - Use `<dialog>` for modals, `<details><summary>` for disclosures
- **Leverage Turbo frames** for page sections over client-side solutions
- **Query params for state** over localStorage/sessions
- **Server-side formatting** for currencies, numbers, dates
- **Always use `icon` helper** in `application_helper.rb`, NEVER `lucide_icon` directly

### Convention 4: Optimize for Simplicity
- Prioritize good OOP domain design over performance
- Focus performance only on critical/global areas (avoid N+1 queries, mindful of global layouts)

### Convention 5: Database vs ActiveRecord Validations
- Simple validations (null checks, unique indexes) in DB
- ActiveRecord validations for convenience in forms (prefer client-side when possible)
- Complex validations and business logic in ActiveRecord

## TailwindCSS Design System

### Design System Rules
- **Always reference `app/assets/tailwind/maybe-design-system.css`** for primitives and tokens
- **Use functional tokens** defined in design system:
  - `text-primary` instead of `text-white`
  - `bg-container` instead of `bg-white`
  - `border border-primary` instead of `border border-gray-200`
- **NEVER create new styles** in design system files without permission
- **Always generate semantic HTML**

## Component Architecture

### ViewComponent vs Partials Decision Making

**Use ViewComponents when:**
- Element has complex logic or styling patterns
- Element will be reused across multiple views/contexts
- Element needs structured styling with variants/sizes
- Element requires interactive behavior or Stimulus controllers
- Element has configurable slots or complex APIs
- Element needs accessibility features or ARIA support

**Use Partials when:**
- Element is primarily static HTML with minimal logic
- Element is used in only one or few specific contexts
- Element is simple template content
- Element doesn't need variants, sizes, or complex configuration
- Element is more about content organization than reusable functionality

**Component Guidelines:**
- Prefer components over partials when available
- Keep domain logic OUT of view templates
- Logic belongs in component files, not template files

### Stimulus Controller Guidelines

**Declarative Actions (Required):**
```erb
<!-- GOOD: Declarative - HTML declares what happens -->
<div data-controller="toggle">
  <button data-action="click->toggle#toggle" data-toggle-target="button">
    <%= t("components.transaction_details.show_details") %>
  </button>
  <div data-toggle-target="content" class="hidden">
    <p><%= t("components.transaction_details.amount_label") %>: <%= @transaction.amount %></p>
    <p><%= t("components.transaction_details.date_label") %>: <%= @transaction.date %></p>
    <p><%= t("components.transaction_details.category_label") %>: <%= @transaction.category.name %></p>
  </div>
</div>
```

**Example locale file structure (config/locales/en.yml):**
```yaml
en:
  components:
    transaction_details:
      show_details: "Show Details"
      hide_details: "Hide Details"
      amount_label: "Amount"
      date_label: "Date"
      category_label: "Category"
```

**i18n Best Practices:**
- Organize keys by feature/component: `components.transaction_details.show_details`
- Use descriptive key names that indicate purpose: `show_details` not `button`
- Group related translations together in the same namespace
- Use interpolation for dynamic content: `t("users.welcome", name: user.name)`
- Always update locale files when adding new user-facing strings

**Controller Best Practices:**
- Keep controllers lightweight and simple (< 7 targets)
- Use private methods and expose clear public API
- Single responsibility or highly related responsibilities
- Component controllers stay in component directory, global controllers in `app/javascript/controllers/`
- Pass data via `data-*-value` attributes, not inline JavaScript
