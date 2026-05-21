# The Invisible Tax — Slides

Slidev deck for [Observability Summit NA 2026](https://observabilitysummitna26.sched.com/event/2HJUt/the-invisible-tax-how-data-format-conversions-drive-up-telemetry-pipeline-costs-cijo-thomas-joshua-macdonald-microsoft).

**Speakers:** Cijo Thomas · Joshua MacDonald (Microsoft)

## Live deck

https://cijothomas.github.io/pipeline-conversion-cost-slides/

## Run locally

Prerequisites: Node.js >= 20.19.

```bash
# 1. Install dependencies (only needed once, or after package.json changes)
npm install

# 2. Start the dev server
npm run slides
```

Then open http://localhost:3030 in your browser. The server hot-reloads on edits to `obssummit_slides.md`.

Presenter mode: http://localhost:3030/presenter

Other commands:

```bash
npm run build    # static SPA into dist/
npm run export   # export to PDF (requires Playwright: npx playwright install chromium)
```

## Source

Research, benchmarks, and analysis: [cijothomas/pipeline-conversion-cost](https://github.com/cijothomas/pipeline-conversion-cost)
