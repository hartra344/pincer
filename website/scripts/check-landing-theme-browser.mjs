// Actual rendered landing controls, against an owned Astro dev/preview server.
import { createRequire } from 'node:module';
import assert from 'node:assert/strict';
const { chromium } = createRequire(process.env.PINCER_PLAYWRIGHT_PACKAGE || import.meta.url)('playwright');
const base = process.env.PINCER_THEME_CHECK_URL || 'http://127.0.0.1:4327/';
const browser = await chromium.launch({ headless: true, ...(process.env.PINCER_THEME_BROWSER ? { executablePath: process.env.PINCER_THEME_BROWSER } : {}) });
const results = {};
try {
  const context = await browser.newContext({ colorScheme: 'dark' }), page = await context.newPage();
  await page.goto(base);
  await page.waitForFunction(() => document.querySelector('#theme-toggle:not([hidden]), select[aria-label="Theme"]'));
  await page.evaluate(() => localStorage.setItem('starlight-theme', 'light'));
  await page.reload();
  await page.waitForFunction(() => document.documentElement.dataset.theme === 'light');
  const select = page.getByRole('combobox', { name: 'Theme', exact: true });
  async function explicit(theme) {
    if (await select.count()) await select.selectOption(theme);
    else await page.locator('#theme-toggle').click();
    await page.waitForFunction(value => document.documentElement.dataset.theme === value, theme);
  }
  await explicit('dark');
  results.explicitDark = await page.evaluate(() => localStorage.getItem('starlight-theme') === 'dark');
  await page.evaluate(() => {
    window.__themeMediaChanged = false;
    matchMedia('(prefers-color-scheme: light)').addEventListener('change', () => { window.__themeMediaChanged = true; }, { once: true });
  });
  await page.emulateMedia({ colorScheme: 'light' });
  await page.waitForFunction(() => window.__themeMediaChanged === true);
  results.explicitUnaffectedBySystem = await page.evaluate(() => document.documentElement.dataset.theme === 'dark');
  await explicit('light');
  results.explicitLight = await page.evaluate(() => localStorage.getItem('starlight-theme') === 'light');
  results.autoChoiceAvailable = (await select.count()) === 1 && (await select.locator('option[value="auto"]').count()) === 1;
  if (results.autoChoiceAvailable) {
    await select.selectOption('auto');
    await page.waitForFunction(() => document.documentElement.dataset.theme === 'light');
    results.autoUsesStarlightPreference = await page.evaluate(() => localStorage.getItem('starlight-theme') === '');
    await page.emulateMedia({ colorScheme: 'dark' });
    await page.waitForFunction(() => document.documentElement.dataset.theme === 'dark');
    results.autoFollowsSystemChange = true;
    await page.reload();
    results.autoSurvivesReload = await select.inputValue() === 'auto';
  }
  await context.close();
  const unavailable = await browser.newContext({ colorScheme: 'light' });
  await unavailable.addInitScript(() => {
    const get = Storage.prototype.getItem, set = Storage.prototype.setItem;
    Storage.prototype.getItem = function(key) {
      if (key === 'starlight-theme') throw new Error('owned theme storage failure fixture');
      return get.call(this, key);
    };
    Storage.prototype.setItem = function(key, value) {
      if (key === 'starlight-theme') throw new Error('owned theme storage failure fixture');
      return set.call(this, key, value);
    };
  });
  const noStorage = await unavailable.newPage(), errors = [];
  noStorage.on('pageerror', error => errors.push(error.message));
  await noStorage.goto(base);
  await noStorage.waitForFunction(() => document.documentElement.dataset.theme === 'light');
  const unavailableSelect = noStorage.getByRole('combobox', { name: 'Theme', exact: true });
  if (await unavailableSelect.count()) await unavailableSelect.selectOption('dark');
  else await noStorage.locator('#theme-toggle').click();
  await noStorage.waitForFunction(() => document.documentElement.dataset.theme === 'dark');
  results.storageFailureStillAllowsExplicitChoice = errors.length === 0;
  await unavailable.close();
  console.log(JSON.stringify(results));
  assert(results.explicitDark && results.explicitLight && results.explicitUnaffectedBySystem && results.storageFailureStillAllowsExplicitChoice);
  if (!process.argv.includes('--ordinary')) {
    assert(results.autoChoiceAvailable, 'actual landing control must offer Auto after an explicit choice');
    assert(results.autoUsesStarlightPreference && results.autoFollowsSystemChange && results.autoSurvivesReload);
  }
} finally { await browser.close(); }
