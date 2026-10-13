import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import test from 'node:test';
import {swarmConstructorArgs} from '../tools/swarm_constructor_args.mjs';

const read = path => JSON.parse(readFileSync(new URL(path, import.meta.url), 'utf8'));
const oracle = read('../docs/oracle-v37/oracle-config.json');
const binding = read('../docs/swarm-bootstrap-v313/binding.json');
const recorded = read('../docs/swarm-bootstrap-v313/constructor-args.json');
const approved = [
  '0xa43e6f75ee006411f79ac1c84120606c2330de82',
  '0xce0e6a670aa75e161d02aca3c7f00b94ca428ccb',
  '0x5598aa9146215bc13eb26f2c692ad1461fd32982',
  '0x5f7bb59365ce557c26dbcaa4ee9d39a4b95b7127',
  '0x6f7261636c652e72657175657374406f7261636c652d31000000000000000000',
  '5391989333430298100116863486635657822062725418115979424500284366258177',
  '0x2fc5a57f2c5f7bc083ea8ac5016234f1a0b1c68a514e5d921956cc57948534ef',
  '0xc13efed8438aab53ea052a4507def2dc4ce9856765520dfa28c66daa59cfc11d',
  '0x00e69e4445c7ca7256338293f9f9cea439fd2beb1959d1d43ebec7b14493e2f6',
  '0xc0ae7511b06744cf7ccadc6b60ff9ff96cb7234cf32988850df33324861cc8df',
  '0x9c9d2fcb75c2c132c0ac0c42df3819a42347265e',
  '0x11ed7438974e96ecc962201e9c46422c7bf239d725876863fa25a56c734b20d3',
];

test('committed inputs regenerate exactly the twelve approved constructor words', () => {
  assert.deepEqual(swarmConstructorArgs(oracle, binding), approved);
  assert.deepEqual(recorded, {constructorArgs: approved});
  for (const word of recorded.constructorArgs) {
    assert.ok(BigInt(word) > 0n && BigInt(word) < (1n << 256n));
  }
});

test('binding and packed policy preserve unbound launch coordinates and heartbeat limits', () => {
  assert.deepEqual(binding, {
    factory: approved[10],
    registryLaunch: '0', registryIndex: 0,
    paramsLaunch: '0', paramsIndex: 0,
    heartbeatBps: 200, heartbeatCap: '1000000000000000000',
    gameConfigHash: approved[11],
  });
  const policy = BigInt(recorded.constructorArgs[5]);
  assert.equal(policy & ((1n << 32n) - 1n), 1n);
  assert.equal((policy >> 32n) & ((1n << 48n) - 1n), 26122900n);
  assert.equal((policy >> 80n) & ((1n << 48n) - 1n), 26122901n);
  assert.equal((policy >> 128n) & ((1n << 96n) - 1n), 500000000000000000n);
  assert.equal((policy >> 224n) & 65535n, 200n);
  assert.equal(policy >> 240n, 0n);
});
