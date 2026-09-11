/// ABIs, read from the forge build artefacts rather than hand-written.
///
/// A hand-copied fragment is a second definition that drifts silently; these are
/// the exact ABIs the deployed bytecode was compiled from. Run `forge build`
/// before the swarm if a contract changed.
import { readFileSync } from 'node:fs'
import type { Abi } from 'viem'

const REPO = new URL('../..', import.meta.url).pathname

function artifact(path: string, name: string): Abi {
  return JSON.parse(readFileSync(`${REPO}/out/${path}/${name}.json`, 'utf8')).abi
}

export const BOOK = artifact('Book.sol', 'Book')
export const EXECUTOR = artifact('Executor.sol', 'Executor')
export const REGISTRY = artifact('TokenRegistry.sol', 'TokenRegistry')
export const OTC = artifact('OtcMaker.sol', 'OtcMaker')

export const ERC20 = [
  { name: 'balanceOf', type: 'function', stateMutability: 'view', inputs: [{ type: 'address' }], outputs: [{ type: 'uint256' }] },
  { name: 'allowance', type: 'function', stateMutability: 'view', inputs: [{ type: 'address' }, { type: 'address' }], outputs: [{ type: 'uint256' }] },
  { name: 'approve', type: 'function', stateMutability: 'nonpayable', inputs: [{ type: 'address' }, { type: 'uint256' }], outputs: [{ type: 'bool' }] },
  { name: 'transfer', type: 'function', stateMutability: 'nonpayable', inputs: [{ type: 'address' }, { type: 'uint256' }], outputs: [{ type: 'bool' }] },
] as const satisfies Abi

export const UNIV2_PAIR = [
  { name: 'getReserves', type: 'function', stateMutability: 'view', inputs: [], outputs: [{ type: 'uint112' }, { type: 'uint112' }, { type: 'uint32' }] },
  { name: 'token0', type: 'function', stateMutability: 'view', inputs: [], outputs: [{ type: 'address' }] },
] as const satisfies Abi

export const UNIV2_ROUTER = [
  {
    name: 'swapExactTokensForTokens',
    type: 'function',
    stateMutability: 'nonpayable',
    inputs: [
      { name: 'amountIn', type: 'uint256' },
      { name: 'amountOutMin', type: 'uint256' },
      { name: 'path', type: 'address[]' },
      { name: 'to', type: 'address' },
      { name: 'deadline', type: 'uint256' },
    ],
    outputs: [{ type: 'uint256[]' }],
  },
  {
    name: 'getAmountsOut',
    type: 'function',
    stateMutability: 'view',
    inputs: [{ name: 'amountIn', type: 'uint256' }, { name: 'path', type: 'address[]' }],
    outputs: [{ type: 'uint256[]' }],
  },
] as const satisfies Abi
