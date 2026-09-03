#!/usr/bin/env node
/**
 * 종목명을 검색해 첫 번째 결과의 종목명과 현재가를 가져온다.
 *
 * 사용법:
 *   node scripts/stock-price.js --query 삼성전자 [--url <검색 페이지 URL>] [--headed] [--json]
 *
 * URL을 생략하면 다음 파이낸스를 사용한다. STOCK_SEARCH_URL 환경변수로도 지정할 수 있다.
 */
const { chromium } = require('@playwright/test');
const { findChromium } = require('../lib/chromium');

const DEFAULT_URL = 'https://finance.daum.net/';

const SELECTORS = {
  searchBox: '//*[@id="boxSearchbar"]',
  searchButton: '//*[@id="btnSearchStock"]',
  stockName: '//*[@id="boxContents"]/div[2]/div/table/tbody/tr[1]/td[2]/a',
  stockPrice: '//*[@id="boxContents"]/div[2]/div/table/tbody/tr[1]/td[3]/span',
};

function parseArgs(argv) {
  const args = { headed: false, json: false, timeout: 30000 };
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === '--headed') args.headed = true;
    else if (arg === '--json') args.json = true;
    else if (arg === '--url') args.url = argv[++i];
    else if (arg === '--query') args.query = argv[++i];
    else if (arg === '--timeout') args.timeout = Number(argv[++i]);
    else throw new Error(`알 수 없는 인자: ${arg}`);
  }
  args.url = args.url || process.env.STOCK_SEARCH_URL || DEFAULT_URL;
  if (!args.query) throw new Error('--query <종목명> 이 필요합니다.');
  return args;
}

/** 검색창이 컨테이너일 수도 있으므로, 실제 입력 가능한 요소를 찾는다. */
async function resolveSearchInput(page) {
  const box = page.locator(SELECTORS.searchBox);
  const tag = await box.evaluate((el) => el.tagName.toLowerCase());
  if (tag === 'input' || tag === 'textarea') return box;
  return box.locator('input:not([type="hidden"]), textarea').first();
}

async function fetchStock({ url, query, headed, timeout }) {
  const executablePath = findChromium();
  const browser = await chromium.launch({
    headless: !headed,
    ...(executablePath ? { executablePath } : {}),
  });
  try {
    const page = await browser.newPage();
    page.setDefaultTimeout(timeout);
    await page.goto(url, { waitUntil: 'domcontentloaded' });

    const input = await resolveSearchInput(page);
    await input.fill(query);
    await page.locator(SELECTORS.searchButton).click();

    const nameLocator = page.locator(SELECTORS.stockName);
    const priceLocator = page.locator(SELECTORS.stockPrice);
    await nameLocator.waitFor({ state: 'visible' });

    const name = (await nameLocator.innerText()).trim();
    const price = (await priceLocator.innerText()).trim();
    return { query, name, price };
  } finally {
    await browser.close();
  }
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const result = await fetchStock(args);
  if (args.json) {
    console.log(JSON.stringify(result, null, 2));
  } else {
    console.log(`종목명: ${result.name}`);
    console.log(`현재가: ${result.price}`);
  }
}

if (require.main === module) {
  main().catch((err) => {
    console.error(`오류: ${err.message}`);
    process.exit(1);
  });
}

module.exports = { DEFAULT_URL, SELECTORS, fetchStock };
