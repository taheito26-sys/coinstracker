param(
    [string]$RepoPath = 'D:\GitHUB\CoinsTracker',
    [switch]$DeployAfterPatch
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Write-Step([string]$Message) {
    Write-Host ""
    Write-Host "=== $Message ===" -ForegroundColor Cyan
}

Set-Location $RepoPath

Write-Step 'Write fixed backend/src/index.js'
@'
const DEFAULT_ASSETS = [
  { symbol: 'BTC', id: 'bitcoin', name: 'Bitcoin', binanceSymbol: 'BTCUSDT' },
  { symbol: 'ETH', id: 'ethereum', name: 'Ethereum', binanceSymbol: 'ETHUSDT' },
  { symbol: 'SOL', id: 'solana', name: 'Solana', binanceSymbol: 'SOLUSDT' },
  { symbol: 'XRP', id: 'ripple', name: 'XRP', binanceSymbol: 'XRPUSDT' },
  { symbol: 'BNB', id: 'binancecoin', name: 'BNB', binanceSymbol: 'BNBUSDT' },
  { symbol: 'USDT', id: 'tether', name: 'Tether', binanceSymbol: 'USDTUSDT' }
];

const DEFAULT_PREFS = {
  baseCurrency: 'USD',
  watchlist: ['BTC', 'ETH', 'SOL']
};

const JSON_HEADERS = {
  'content-type': 'application/json; charset=utf-8'
};

function corsHeaders(origin = '*') {
  return {
    'access-control-allow-origin': origin,
    'access-control-allow-methods': 'GET,POST,PUT,DELETE,OPTIONS',
    'access-control-allow-headers': 'Content-Type',
    'access-control-max-age': '86400'
  };
}

function json(data, status = 200, origin = '*') {
  return new Response(JSON.stringify(data, null, 2), {
    status,
    headers: {
      ...JSON_HEADERS,
      ...corsHeaders(origin)
    }
  });
}

function parseJson(text, fallback) {
  try {
    return text ? JSON.parse(text) : fallback;
  } catch {
    return fallback;
  }
}

async function readKV(env, key, fallback = null) {
  const raw = await env.APP_KV.get(key);
  return parseJson(raw, fallback);
}

async function writeKV(env, key, value) {
  await env.APP_KV.put(key, JSON.stringify(value));
}

function getOrigin(request) {
  return request.headers.get('Origin') || '*';
}

async function fetchCoinGeckoPrices(env) {
  const ids = DEFAULT_ASSETS.map((asset) => asset.id).join(',');
  const headers = { accept: 'application/json' };
  if (env.COINGECKO_DEMO_API_KEY) headers['x-cg-demo-api-key'] = env.COINGECKO_DEMO_API_KEY;

  const url = `https://api.coingecko.com/api/v3/simple/price?ids=${ids}&vs_currencies=usd&include_last_updated_at=true`;
  const response = await fetch(url, { headers });
  if (!response.ok) {
    const body = await response.text().catch(() => '');
    throw new Error(`CoinGecko failed, ${response.status}${body ? `, ${body.slice(0, 180)}` : ''}`);
  }

  const data = await response.json();
  const ts = Date.now();
  const prices = {};

  for (const asset of DEFAULT_ASSETS) {
    const entry = data[asset.id];
    if (!entry || typeof entry.usd !== 'number') continue;
    prices[asset.symbol] = {
      usd: entry.usd,
      updatedAt: entry.last_updated_at ? entry.last_updated_at * 1000 : ts
    };
  }

  if (Object.keys(prices).length < 5) {
    throw new Error('CoinGecko returned incomplete price data');
  }

  return { ts, provider: 'coingecko', prices };
}

async function fetchBinancePrices() {
  const response = await fetch('https://api.binance.com/api/v3/ticker/price');
  if (!response.ok) {
    const body = await response.text().catch(() => '');
    throw new Error(`Binance failed, ${response.status}${body ? `, ${body.slice(0, 180)}` : ''}`);
  }

  const all = await response.json();
  const map = new Map(all.map((item) => [item.symbol, item.price]));
  const ts = Date.now();
  const prices = {
    USDT: { usd: 1, updatedAt: ts }
  };

  for (const asset of DEFAULT_ASSETS.filter((asset) => asset.symbol !== 'USDT')) {
    const raw = map.get(asset.binanceSymbol);
    const usd = Number(raw);
    if (!Number.isFinite(usd) || usd <= 0) continue;
    prices[asset.symbol] = { usd, updatedAt: ts };
  }

  if (Object.keys(prices).length < 5) {
    throw new Error('Binance returned incomplete price data');
  }

  return { ts, provider: 'binance', prices };
}

async function fetchLatestPrices(env) {
  try {
    return await fetchCoinGeckoPrices(env);
  } catch (coinGeckoError) {
    const fallback = await fetchBinancePrices();
    return {
      ...fallback,
      fallbackReason: coinGeckoError instanceof Error ? coinGeckoError.message : 'CoinGecko failed'
    };
  }
}

async function persistPriceSnapshot(env, snapshot) {
  await writeKV(env, 'prices:latest', snapshot);
  const history = await readKV(env, 'prices:history', []);
  history.push(snapshot);
  const maxPoints = 288;
  if (history.length > maxPoints) history.splice(0, history.length - maxPoints);
  await writeKV(env, 'prices:history', history);
  return snapshot;
}

async function getOrBootstrapPrices(env) {
  const latest = await readKV(env, 'prices:latest', null);
  if (latest) return latest;
  const snapshot = await fetchLatestPrices(env);
  return persistPriceSnapshot(env, snapshot);
}

async function listTransactions(env) {
  return await readKV(env, 'transactions:list', []);
}

async function saveTransaction(env, transaction) {
  const items = await listTransactions(env);
  items.unshift(transaction);
  await writeKV(env, 'transactions:list', items.slice(0, 500));
  return transaction;
}

async function getPrefs(env) {
  return await readKV(env, 'prefs:tracking', DEFAULT_PREFS);
}

async function savePrefs(env, prefs) {
  const next = {
    baseCurrency: prefs?.baseCurrency || 'USD',
    watchlist: Array.isArray(prefs?.watchlist) ? prefs.watchlist : DEFAULT_PREFS.watchlist
  };
  await writeKV(env, 'prefs:tracking', next);
  return next;
}

function validateTransaction(input) {
  const type = String(input?.type || '').toLowerCase();
  const assetSymbol = String(input?.assetSymbol || '').toUpperCase();
  const qty = Number(input?.qty);
  const price = Number(input?.price);
  const note = typeof input?.note === 'string' ? input.note.trim() : '';
  if (!['buy', 'sell'].includes(type)) return { error: 'Transaction type must be buy or sell' };
  if (!DEFAULT_ASSETS.some((asset) => asset.symbol === assetSymbol)) return { error: 'Unsupported asset symbol' };
  if (!Number.isFinite(qty) || qty <= 0) return { error: 'Quantity must be a positive number' };
  if (!Number.isFinite(price) || price < 0) return { error: 'Price must be zero or a positive number' };
  return {
    value: {
      id: crypto.randomUUID(),
      timestamp: Date.now(),
      type,
      assetSymbol,
      qty,
      price,
      note
    }
  };
}

async function handleRequest(request, env) {
  const url = new URL(request.url);
  const path = url.pathname;
  const origin = getOrigin(request);

  if (request.method === 'OPTIONS') return new Response(null, { headers: corsHeaders(origin) });

  if (path === '/api/status' && request.method === 'GET') {
    const latest = await readKV(env, 'prices:latest', null);
    return json({
      ok: true,
      cacheReady: !!latest,
      provider: latest?.provider || null,
      fallbackReason: latest?.fallbackReason || null,
      lastUpdate: latest?.ts || null,
      ageMs: latest ? Date.now() - latest.ts : null
    }, 200, origin);
  }

  if (path === '/api/assets' && request.method === 'GET') return json({ items: DEFAULT_ASSETS }, 200, origin);

  if (path === '/api/prices' && request.method === 'GET') return json(await getOrBootstrapPrices(env), 200, origin);

  if (path === '/api/prices/history' && request.method === 'GET') {
    const asset = String(url.searchParams.get('asset') || '').toUpperCase();
    const limit = Math.max(1, Math.min(200, Number(url.searchParams.get('limit') || 50)));
    const history = await readKV(env, 'prices:history', []);
    const items = history.map((point) => {
      if (!asset) return point;
      const selected = point?.prices?.[asset];
      if (!selected) return null;
      return { ts: point.ts, provider: point.provider, prices: { [asset]: selected } };
    }).filter(Boolean).slice(-limit);
    return json({ items }, 200, origin);
  }

  if (path === '/api/transactions' && request.method === 'GET') return json({ items: await listTransactions(env) }, 200, origin);

  if (path === '/api/transactions' && request.method === 'POST') {
    const body = await request.json().catch(() => null);
    const validated = validateTransaction(body);
    if (validated.error) return json({ error: validated.error }, 400, origin);
    return json({ ok: true, item: await saveTransaction(env, validated.value) }, 201, origin);
  }

  if (path === '/api/tracking-preferences' && request.method === 'GET') return json(await getPrefs(env), 200, origin);

  if (path === '/api/tracking-preferences' && request.method === 'PUT') {
    const body = await request.json().catch(() => null);
    const prefs = await savePrefs(env, body || DEFAULT_PREFS);
    return json({ ok: true, ...prefs }, 200, origin);
  }

  return json({ error: 'Not found' }, 404, origin);
}

export default {
  async fetch(request, env) {
    try {
      return await handleRequest(request, env);
    } catch (error) {
      return json({ error: error instanceof Error ? error.message : 'Internal server error' }, 500, getOrigin(request));
    }
  },

  async scheduled(_event, env, ctx) {
    ctx.waitUntil((async () => {
      const snapshot = await fetchLatestPrices(env);
      await persistPriceSnapshot(env, snapshot);
    })());
  }
};
'@ | Set-Content -Path '.\backend\src\index.js' -Encoding UTF8

Write-Step 'Optional: save CoinGecko demo API key as a Worker secret'
Write-Host 'If you have a CoinGecko Demo API key, run this manually:' -ForegroundColor Yellow
Write-Host 'cd backend' -ForegroundColor Yellow
Write-Host 'npx wrangler secret put COINGECKO_DEMO_API_KEY' -ForegroundColor Yellow
Write-Host 'Then paste your key when prompted.' -ForegroundColor Yellow

if ($DeployAfterPatch.IsPresent) {
    Write-Step 'Deploy patched Worker'
    Push-Location '.\backend'
    try {
        npx wrangler deploy
    }
    finally {
        Pop-Location
    }

    Write-Step 'Warm and verify API'
    $status = Invoke-RestMethod 'https://coin-compass-api.taheito26.workers.dev/api/status'
    Write-Host ($status | ConvertTo-Json -Depth 5)

    $prices = Invoke-RestMethod 'https://coin-compass-api.taheito26.workers.dev/api/prices'
    Write-Host ($prices | ConvertTo-Json -Depth 6)
}
