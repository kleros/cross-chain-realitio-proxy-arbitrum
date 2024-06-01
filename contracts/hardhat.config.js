require("dotenv/config");
require("@nomiclabs/hardhat-waffle");
require("@nomiclabs/hardhat-ethers");
require("@nomicfoundation/hardhat-verify");
require("@nomiclabs/hardhat-web3");

const exec = require("./tasks/exec.js");

task('exec', "Execute msg on L1")
  .addParam('txhash', 'Hash of txn that triggered and L2 to L1 message')
  .setAction(async args => {
    await exec(args.txhash)
  })

module.exports = {
  solidity: {
    version: "0.8.25",
    settings: {
      optimizer: {
        enabled: true,
        runs: 200,
      },
    },
  },
  paths: {
    sources: "./src",
  },
  networks: {
    hardhat: {
      blockGasLimit: 100000000000,
    },
    sepolia: {
      chainId: 11155111,
      url: `https://sepolia.infura.io/v3/${process.env.INFURA_API_KEY}`,
      accounts: [process.env.PRIVATE_KEY],
    },
    arbitrumSepolia: {
      chainId: 421614,
      url: `https://arbitrum-sepolia.infura.io/v3/${process.env.INFURA_API_KEY}`,
      accounts: [process.env.PRIVATE_KEY],
    },
    /*
    mainnet: {
      chainId: 1,
      url: `https://mainnet.infura.io/v3/${process.env.INFURA_API_KEY}`,
      accounts: [process.env.PRIVATE_KEY],
    },
    arbitrumOne: {
      chainId: 42161,
      url: 'https://arb1.arbitrum.io/rpc',
      accounts: [process.env.PRIVATE_KEY]
    },
    */
  },
  etherscan: {
    apiKey: {
      sepolia: process.env.ETHERSCAN_API_KEY,
      arbitrumSepolia: process.env.ARBITSCAN_API_KEY,
    },
    customChains: [
      {
          network: "arbitrumSepolia",
          chainId: 421614,
          urls: {
              apiURL: "https://api-sepolia.arbiscan.io/api",
              browserURL: "https://sepolia.arbiscan.io/",
          },
      },
    ],
  },
};
