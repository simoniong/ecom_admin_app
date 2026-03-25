# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Rails 8 e-commerce admin app for managing customer support tickets integrated with Gmail. Tickets flow through a state machine: New → Draft (agent-generated reply) → DraftConfirmed (human-approved) → Close (sent). Integrates with Shopify for order/customer data and 17Track for shipping tracking.

## Common Commands

```bash
# Setup
bin/setup                        # Install deps, prepare DB

# Development
bin/dev                          # Start dev server (Puma + Tailwind watcher)
bin/rails server                 # Start Rails server only

# Database
bin/rails db:create db:migrate   # Create and migrate DB
bin/rails db:test:prepare        # Prepare test DB

# Testing
bin/rails test                   # Run all unit/integration tests
bin/rails test:system            # Run system tests (Capybara + Selenium)
bin/rails test test/models/ticket_test.rb           # Run single test file
bin/rails test test/models/ticket_test.rb:42        # Run single test at line

# Linting & Security
bin/rubocop                      # RuboCop (omakase style)
bin/rubocop -a                   # Auto-fix offenses
bin/brakeman --no-pager          # Security static analysis
bin/bundler-audit                # Gem vulnerability scan
bin/importmap audit              # JS dependency audit
```

## Architecture

- **Rails 8.1** with Hotwire (Turbo + Stimulus), Importmap (no JS build step), Propshaft asset pipeline
- **PostgreSQL** — all table IDs must use UUIDs
- **Solid Queue** for background jobs (can run in-process via `SOLID_QUEUE_IN_PUMA=1`)
- **Solid Cache** and **Solid Cable** replace Redis for caching and Action Cable
- Production uses separate databases for primary, cache, queue, and cable
- **Tailwind CSS** via `tailwindcss-rails` gem
- **Kamal** for container deployment with Thruster HTTP accelerator

## Key Domain Concepts

- **Ticket state machine**: New → Draft → DraftConfirmed → Close
  - An external Agent uses the Ticket API to read New tickets and transition them to Draft (only transition the API allows)
  - DraftConfirmed is human-only; triggers timezone-aware scheduled email send (8am-10pm recipient local time)
  - Close happens automatically after email is sent
- **EmailAccount**: OAuth-bound Gmail account; syncs threads every 10 minutes
- **Order/Customer**: Mirrored from Shopify; fulfillment tracking via 17Track API (hourly refresh)

## Testing Requirements

- 95%+ coverage required — PRs will not be approved without it
- No mocks — tests must hit real database
- Must include both unit tests and feature (system) tests
- CI runs: Brakeman, bundler-audit, importmap audit, RuboCop, unit tests, system tests

## Style & Conventions

- RuboCop Omakase (Rails-oriented rules)
- Frontend: Tailwind + shadcn components, Turbo for SPA behavior, Stimulus for JS
- PRD and milestone docs are in Chinese (in `.plan/` directory)
