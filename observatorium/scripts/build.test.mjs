// @trace spec:observatorium-dashboard, order:1782-bek5
import {test} from 'node:test';
import assert from 'node:assert/strict';
import {flutterCommand} from './build.mjs';

test('forge builds use the trusted sibling command while standalone builds retain pinned SDKs', () => {
  assert.equal(flutterCommand({TILLANDSIAS_PROJECT: 'tillandsias'}), 'flutter');
  assert.equal(flutterCommand({}), null);
  assert.equal(flutterCommand({TILLANDSIAS_PROJECT: 'tillandsias', FLUTTER: '/custom/flutter'}), '/custom/flutter');
});
