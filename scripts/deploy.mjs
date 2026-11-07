// Deploy Ratify end to end on GenLayer Bradbury: the ERC-8183 escrow and its test dollar on GenLayer Chain (the
// EVM side, chain 4221), then the Ratify Intelligent Contract pointed at the escrow.
//   PCHG=<pw> node scripts/deploy.mjs
import solc from 'solc';
import { Wallet, JsonRpcProvider, ContractFactory } from 'ethers';
import fs from 'fs'; import os from 'os'; import path from 'path'; import url from 'url';
import { client, fees, EXPLORER } from './net.mjs';

const PW = process.env.PCHG || '';
if (!PW) { console.error('set PCHG'); process.exit(1); }
const ROOT = path.join(path.dirname(url.fileURLToPath(import.meta.url)), '..');
const KS = path.join(os.homedir(), '.genlayer', 'keystores');
export const CHAIN_RPC = 'https://rpc.testnet-chain.genlayer.com';
const w = await Wallet.fromEncryptedJson(fs.readFileSync(path.join(KS, 'pchg.json'), 'utf8'), PW);
const evm = w.connect(new JsonRpcProvider(CHAIN_RPC, 4221));
const OUT = path.join(ROOT, 'deployment.json');
const dep = fs.existsSync(OUT) ? JSON.parse(fs.readFileSync(OUT, 'utf8')) : { network: 'genlayer testnet bradbury phase 2', chain_id: 4221 };
const save = () => fs.writeFileSync(OUT, JSON.stringify(dep, null, 2));
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function compile(name) {
  const source = fs.readFileSync(path.join(ROOT, 'evm', name + '.sol'), 'utf8');
  const out = JSON.parse(solc.compile(JSON.stringify({
    language: 'Solidity', sources: { [name + '.sol']: { content: source } },
    settings: { optimizer: { enabled: true, runs: 200 }, evmVersion: 'paris', outputSelection: { '*': { '*': ['abi', 'evm.bytecode.object'] } } },
  })));
  const errs = (out.errors || []).filter((e) => e.severity === 'error');
  if (errs.length) { for (const e of errs) console.error(e.formattedMessage); process.exit(1); }
  const c = out.contracts[name + '.sol'][name];
  fs.mkdirSync(path.join(ROOT, 'evm', 'abi'), { recursive: true });
  fs.writeFileSync(path.join(ROOT, 'evm', 'abi', name + '.json'), JSON.stringify(c.abi, null, 2));
  return { abi: c.abi, bytecode: '0x' + c.evm.bytecode.object };
}
async function evmDeploy(name, args = []) {
  const key = name.toLowerCase();
  if (dep[key]) return dep[key].address;
  const c = compile(name);
  const contract = await new ContractFactory(c.abi, c.bytecode, evm).deploy(...args);
  await contract.waitForDeployment();
  dep[key] = { address: await contract.getAddress(), tx: contract.deploymentTransaction().hash, compiler: solc.version() };
  save();
  console.log('deployed', name, dep[key].address);
  return dep[key].address;
}

console.log('deployer', w.address);
const token = await evmDeploy('TestUSD');
const escrow = await evmDeploy('AgenticCommerce', [token]);
if (!dep.ratify) {
  const c = client(w.privateKey);
  const code = fs.readFileSync(path.join(ROOT, 'contracts', 'ratify.py'), 'utf8');
  const hash = await c.deployContract({ code, args: [escrow], fees: await fees(c) });
  console.log('ratify tx', hash);
  for (let i = 0; i < 60; i++) {
    await sleep(10000);
    const tx = await c.getTransaction({ hash });
    if (['ACCEPTED', 'FINALIZED'].includes(tx.statusName)) {
      if (tx.txExecutionResultName !== 'FINISHED_WITH_RETURN') { console.error('deploy failed', tx.txExecutionResultName); process.exit(1); }
      dep.ratify = { address: tx.txDataDecoded?.contractAddress || tx.recipient, tx: hash };
      dep.address = dep.ratify.address;
      dep.tx = hash;
      dep.deployed_at = new Date().toISOString();
      save();
      break;
    }
  }
}
console.log('RATIFY', dep.ratify?.address, EXPLORER + '/address/' + dep.ratify?.address);
console.log('escrow', escrow, 'token', token);
process.exit(0);
