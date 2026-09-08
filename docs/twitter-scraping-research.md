# Twitter/X scraping research for the StarIntel Nitter fork

Research date: 2026-09-08

This note records the collection approaches reviewed while designing the StarIntel fork. It is intentionally separate from scraper-observed evidence: these are implementation/design findings, not claims about collected targets.

## Current collection surfaces

### 1. Public syndication/embed surfaces

`tamnd/x-cli` demonstrates that X still exposes public syndication/embed surfaces that can answer some logged-out reads without an account. As of its 2026 documentation, these are useful for single posts, profiles, and a recent timeline window.

Why this matters for StarIntel:

- cheapest credential-free read path;
- useful fallback when GraphQL sessions are exhausted;
- less session/account state to manage;
- should be attempted before more expensive authenticated paths where coverage is sufficient.

Source: https://github.com/tamnd/x-cli

### 2. Guest GraphQL

Nitter's core design and current tools such as `x-cli` and Twikit use X's internal GraphQL/public-client surfaces. Guest access is narrower than it used to be, but it remains useful for a limited set of reads. `x-cli` documents guest-token activation and a small set of operations still available to guests in mid-2026. Twikit also ships a guest client.

Why this matters:

- good second tier after syndication;
- supports deeper timeline/profile reads than syndication in some cases;
- operation/query IDs and request feature flags are volatile and need active maintenance.

Sources:

- https://github.com/zedeus/nitter
- https://github.com/tamnd/x-cli
- https://github.com/d60/twikit

### 3. Session GraphQL

Some reads, especially search and deeper graph operations, increasingly require an authenticated browser/session context. Nitter already has OAuth/cookie session machinery and a rate-limit/session pool. `twscrape`, Twikit, Scweet, and `x-cli` all provide evidence that session-backed internal GraphQL remains a major 2026 collection method.

Important operational lesson: this surface is brittle. X changes query IDs, JavaScript bundle layouts, transaction-ID generation, feature flags, and bot challenges. Recent `twscrape` issues in July/August 2026 show failures caused by `x-client-transaction-id` generation and changed web bundles rather than simply expired credentials.

Sources:

- https://github.com/vladkens/twscrape
- https://github.com/d60/twikit
- https://github.com/Altimis/Scweet
- https://github.com/tamnd/x-cli

### 4. Passive browser-response capture

`mkubicek/xTap` takes a different approach: capture GraphQL responses already received while a human browses X, normalize them, deduplicate them, and write JSONL. This does not replace server-side collection, but it is a useful complementary ingest path and a strong design reference for provenance, JSONL archives, media manifests, and normalized output.

Source: https://github.com/mkubicek/xTap

### 5. HTML/RSS scraping of Nitter itself

People do consume Nitter HTML/RSS as a scraping/feed surface, but relying on public instances is fragile. Public RSS has repeatedly been disabled or blocked because of abuse and anti-bot challenges. For StarIntel, a self-hosted Nitter with an explicit machine API is preferable to scraping our own rendered HTML.

Sources:

- https://github.com/zedeus/nitter/issues/1353
- https://github.com/zedeus/nitter/discussions/1441

## Design conclusion

The StarIntel collector should evolve toward a tiered read architecture:

1. syndication/public surface when it satisfies the requested fields;
2. guest GraphQL when available;
3. managed session GraphQL for search/deeper reads;
4. optional passive browser-response ingest for evidence captured during human browsing;
5. browser automation only as a last-resort adapter because it is heavier and more brittle.

The machine API added by this fork is the normalization boundary: downstream StarIntel actors should consume stable JSON rather than couple themselves to Nitter HTML templates or X's changing raw GraphQL shapes.

## Features implemented in the first StarIntel fork pass

- opt-in machine-readable JSON API;
- optional API-key authentication;
- profiles, posts, replies, media, articles, conversations, and post search;
- cursor pagination;
- canonical `x.com` URLs;
- Snowflake IDs encoded as strings;
- normalized media URLs and video variants;
- article-preview serialization;
- collector/upstream/retrieval provenance metadata;
- capability discovery endpoint;
- integration coverage in the upstream test workflow.

The API design started from `yao177/nitter-plus`, which had already demonstrated a useful JSON route layer, then was ported onto current Nitter rather than merging its stale branch wholesale. Additional provenance/capabilities/article work is StarIntel-specific. Pipeline-oriented output choices were also informed by `x-cli` and `xTap`.

## Follow-up engineering targets

- pluggable tier/surface resolver with per-operation capability tables;
- syndication reader as the cheapest tier;
- explicit per-request surface provenance (`syndication`, `guest-graphql`, `session-graphql`);
- JSONL/NDJSON output for bulk actor pipelines;
- health/doctor endpoint that tests each configured collection surface independently;
- resilient query-ID / web-bundle refresh tooling with fixtures;
- rate-limit/session telemetry suitable for actor scheduling;
- optional browser-response ingest compatible with normalized StarIntel documents;
- deterministic media manifests and archival hooks;
- schema-versioned response fixtures for downstream actor conformance tests.
