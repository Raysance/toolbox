import { test } from 'node:test';
import assert from 'node:assert/strict';
import { detectProvider, normalizeSecret, providerForHost, providers, unsupportedAddress } from '../src/providers.ts';

test('recognizes QQ, Gmail and the ordinary SJTU domain', () => {
  assert.equal(detectProvider('  student@SJTU.EDU.CN '), 'sjtu');
  assert.equal(detectProvider('123456@qq.com'), 'qq');
  assert.equal(detectProvider('person@foxmail.com'), 'qq');
  assert.equal(detectProvider('person@gmail.com'), 'gmail');
  assert.equal(detectProvider('person@googlemail.com'), 'gmail');
});
test('does not route other school mail systems or lookalike domains into these servers', () => {
  for (const address of ['a@365.sjtu.edu.cn', 'a@alumni.sjtu.edu.cn', 'a@gmail.com.evil.com', 'a@qq.com@elsewhere.com', '@gmail.com', 'jaccount']) {
    assert.equal(detectProvider(address), 'custom', address);
  }
  assert.equal(unsupportedAddress('a@365.sjtu.edu.cn'), true);
  assert.equal(unsupportedAddress('a@sjtu.edu.cn'), false);
});
test('retains the provider for existing accounts configured by host', () => {
  assert.equal(providerForHost('MAIL.SJTU.EDU.CN'), 'sjtu');
  assert.equal(providerForHost('imap.gmail.com'), 'gmail');
  assert.equal(providerForHost('imap.qq.com'), 'qq');
  assert.equal(providerForHost('custom.example.com'), 'custom');
});
test('removes display spacing only from app passwords, preserving jAccount passwords exactly', () => {
  assert.equal(normalizeSecret('gmail', 'abcd efgh ijkl mnop'), 'abcdefghijklmnop');
  assert.equal(normalizeSecret('qq', ' abcdefghijklmnop\n'), 'abcdefghijklmnop');
  assert.equal(normalizeSecret('sjtu', ' a secret with spaces '), ' a secret with spaces ');
  assert.equal(normalizeSecret('custom', ' a secret with spaces '), ' a secret with spaces ');
});
test('presets use distinct official encrypted IMAP endpoints and credential types', () => {
  assert.equal(providers.sjtu.host, 'mail.sjtu.edu.cn');
  assert.equal(providers.sjtu.secretTitle, 'jAccount Password');
  assert.equal(new URL(providers.gmail.helpURL).host, 'myaccount.google.com');
  assert.equal(new Set([providers.qq.host, providers.gmail.host, providers.sjtu.host]).size, 3);
});
