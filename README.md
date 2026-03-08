# Coin Compass Cloudflare Starter

This repository is an uploadable starter that follows the same deployment shape you asked for:

- `frontend/index.html`, one static frontend file for Cloudflare Pages
- `backend/src/index.js`, one Cloudflare Worker backend for API and scheduled polling
- one GitHub Actions workflow for backend deploy
- one KV namespace for prices, history, transactions, and tracking preferences

## What this repo already does

- serves a responsive single-file frontend
- exposes these Worker endpoints:
  - `GET /api/status`
  - `GET /api/assets`
  - `GET /api/prices`
  - `GET /api/prices/history`
  - `GET /api/transactions`
  - `POST /api/transactions`
  - `GET /api/tracking-preferences`
  - `PUT /api/tracking-preferences`
- polls CoinGecko every 5 minutes from the Worker cron and stores a rolling history in KV
- persists transactions and settings in KV

This is a **real deployable scaffold**, not full feature parity with your current Vite app. That difference matters. If you want the full business logic from `coin-compass-calendar-fc6c3153`, you still need to port those features into this simpler architecture.

## Folder structure

```text
frontend/
  index.html
  _headers
backend/
  src/index.js
  package.json
  wrangler.jsonc
.github/workflows/
  deploy-backend.yml
wrangler.jsonc
README.md
```

## 1. Upload to GitHub

Create a new GitHub repo, then upload these files keeping the folder structure exactly as-is.

## 2. Create the KV namespace

Install Wrangler locally, then create one KV namespace from inside the `backend` folder:

```bash
npm install
npx wrangler kv namespace create APP_KV
```

Wrangler will print an ID. Copy that ID and replace this value in `backend/wrangler.jsonc`:

```json
"id": "REPLACE_WITH_KV_NAMESPACE_ID"
```

## 3. Deploy the Worker once manually

From `backend/`:

```bash
npx wrangler login
npx wrangler deploy
```

Copy the Worker URL, for example:

```text
https://coin-compass-api.<your-subdomain>.workers.dev
```

## 4. Wire frontend to backend

Open `frontend/index.html` and replace:

```js
const API_BASE = "https://REPLACE_WITH_YOUR_WORKER_URL";
```

with your real Worker URL.

Commit that change to GitHub.

## 5. Connect GitHub repo to Cloudflare Pages

In Cloudflare:

1. Go to **Workers & Pages**
2. Click **Create application**
3. Choose **Pages**
4. Choose **Import an existing Git repository**
5. Select your GitHub repo
6. Use these settings:
   - **Production branch**: `main`
   - **Build command**: leave empty
   - **Build output directory**: `frontend`
7. Save and deploy

## 6. Add GitHub secrets for backend deploy

In GitHub repo settings, add these Actions secrets:

- `CLOUDFLARE_API_TOKEN`
- `CLOUDFLARE_ACCOUNT_ID`

Then any push to `backend/**` on `main` will deploy the Worker automatically through `.github/workflows/deploy-backend.yml`.

## 7. Smoke test checklist

After deployment, verify these:

- Pages site loads successfully
- Worker URL responds on `/api/status`
- Pages frontend can read `/api/status`
- Prices appear after the first poll or after the first `/api/prices` call
- Adding a transaction saves it and it persists across refreshes
- Saving preferences persists watchlist values

## Local development

Backend only:

```bash
cd backend
npm install
npx wrangler dev
```

Frontend locally, simplest option:

- open `frontend/index.html` in a browser for layout testing, or
- serve the `frontend` folder with any static server

## Hard truth

This repo is the correct Cloudflare shape for what you asked, but it is **not yet the same product as your source repo**. It is the right deployment foundation. If you want exact feature parity, the next step is porting the business logic and UI flows from your current app into this single-file frontend plus Worker pattern.
