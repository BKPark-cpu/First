const path = require('path');
const { test, expect } = require('@playwright/test');

const pageUrl = 'file://' + path.resolve(__dirname, '..', 'qr-code-generator.html');

test('QR code generator page loads', async ({ page }) => {
  await page.goto(pageUrl);
  await expect(page).toHaveTitle(/QR/i);
});
