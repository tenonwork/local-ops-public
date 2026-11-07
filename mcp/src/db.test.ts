// Unit tests for the tool error mapping. No database.
//
//   node --test mcp/src/

import { test } from 'node:test';
import assert from 'node:assert/strict';
import pg from 'pg';
import { CheckError, describe, isValidationError } from './db.ts';

function dbError(code: string, message: string, detail?: string): pg.DatabaseError {
  const err = new pg.DatabaseError(message, 0, 'error');
  err.code = code;
  err.detail = detail;
  return err;
}

test('check_violation and the unknown-component P0001 map to one validation error with the message intact', () => {
  const check = dbError('23514', 'dispatch type "x" is not active', 'd');
  const component = dbError('P0001', 'unknown component p/c');
  assert.ok(isValidationError(check) && isValidationError(component));
  assert.equal(describe(check), 'Validation error (23514): dispatch type "x" is not active\nDETAIL: d');
  assert.equal(describe(component), 'Validation error (P0001): unknown component p/c');
});

test('other errors keep their handling', () => {
  const other = dbError('P0001', 'session 1 is not active');
  assert.equal(isValidationError(other), false);
  assert.equal(describe(other), 'Postgres error P0001: session 1 is not active');
  assert.equal(describe(dbError('23505', 'duplicate key')), 'Postgres error 23505: duplicate key');
  assert.equal(describe(new CheckError('unknown project p')), 'unknown project p');
  assert.equal(isValidationError(new Error('unknown component p/c')), false);
});

test('the unknown-node P0001 and an ltree syntax error (42601) are validation errors', () => {
  const node = dbError('P0001', 'unknown node global.nope');
  const syntax = dbError('42601', 'ltree syntax error at character 8');
  assert.ok(isValidationError(node) && isValidationError(syntax));
  assert.equal(describe(node), 'Validation error (P0001): unknown node global.nope');
  assert.equal(describe(syntax), 'Validation error (42601): ltree syntax error at character 8');
  assert.equal(isValidationError(dbError('P0001', 'global-path sessions wait for release 2')), false);
});
