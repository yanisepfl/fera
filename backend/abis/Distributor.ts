// DistributorAbi — GENERATED from contracts/out/Distributor.sol/Distributor.json (BK-1 regen, 2026-07-16).
// Source of truth: the compiled forge artifact's .abi (i.e. contracts/src/Distributor.sol).
// Do not hand-edit: re-run the BK-1 ABI regen to refresh. 9 functions, 2 events, 9 errors.
export const DistributorAbi = [
  {
    "type": "constructor",
    "inputs": [
      {
        "name": "esFera_",
        "type": "address",
        "internalType": "contract IEsFera"
      },
      {
        "name": "rootPoster_",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "controller_",
        "type": "address",
        "internalType": "contract IEmissionsController"
      }
    ],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "claim",
    "inputs": [
      {
        "name": "epochId",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "kind",
        "type": "uint8",
        "internalType": "uint8"
      },
      {
        "name": "amount",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "proof",
        "type": "bytes32[]",
        "internalType": "bytes32[]"
      }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "claimedOf",
    "inputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "controller",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "address",
        "internalType": "contract IEmissionsController"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "esFera",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "address",
        "internalType": "contract IEsFera"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "isClaimed",
    "inputs": [
      {
        "name": "epochId",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "account",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "kind",
        "type": "uint8",
        "internalType": "uint8"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "bool",
        "internalType": "bool"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "postRoot",
    "inputs": [
      {
        "name": "epochId",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "merkleRoot",
        "type": "bytes32",
        "internalType": "bytes32"
      },
      {
        "name": "totalEsFera",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "rootOf",
    "inputs": [
      {
        "name": "epochId",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "bytes32",
        "internalType": "bytes32"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "rootPoster",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "address",
        "internalType": "address"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "totalEsFeraOf",
    "inputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "event",
    "name": "Claimed",
    "inputs": [
      {
        "name": "epochId",
        "type": "uint256",
        "indexed": true,
        "internalType": "uint256"
      },
      {
        "name": "account",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      },
      {
        "name": "kind",
        "type": "uint8",
        "indexed": false,
        "internalType": "uint8"
      },
      {
        "name": "amount",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "RootPosted",
    "inputs": [
      {
        "name": "epochId",
        "type": "uint256",
        "indexed": true,
        "internalType": "uint256"
      },
      {
        "name": "merkleRoot",
        "type": "bytes32",
        "indexed": false,
        "internalType": "bytes32"
      },
      {
        "name": "totalEsFera",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      }
    ],
    "anonymous": false
  },
  {
    "type": "error",
    "name": "AlreadyClaimed",
    "inputs": []
  },
  {
    "type": "error",
    "name": "EmittedMismatch",
    "inputs": []
  },
  {
    "type": "error",
    "name": "EpochNotFinalized",
    "inputs": []
  },
  {
    "type": "error",
    "name": "ExceedsEmitted",
    "inputs": []
  },
  {
    "type": "error",
    "name": "InvalidProof",
    "inputs": []
  },
  {
    "type": "error",
    "name": "OnlyRootPoster",
    "inputs": []
  },
  {
    "type": "error",
    "name": "RootAlreadyPosted",
    "inputs": []
  },
  {
    "type": "error",
    "name": "RootNotPosted",
    "inputs": []
  },
  {
    "type": "error",
    "name": "ZeroAddress",
    "inputs": []
  }
] as const;
