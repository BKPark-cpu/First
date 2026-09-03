const path = require('path');
const { test, expect } = require('@playwright/test');
const { fetchStock } = require('../scripts/stock-price');

// 실제 사이트 대신, 주어진 XPath와 같은 DOM 구조를 가진 픽스처로 스크립트 동작을 검증한다.
const fixtureUrl = 'file://' + path.resolve(__dirname, 'fixtures', 'stock-search.html');

test('검색 후 종목명과 현재가를 읽어온다', async () => {
  const result = await fetchStock({ url: fixtureUrl, query: '삼성전자', timeout: 10000 });
  expect(result).toEqual({ query: '삼성전자', name: '삼성전자', price: '71,900' });
});
