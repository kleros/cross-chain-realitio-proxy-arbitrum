const { ethers } = require("hardhat");

const paramsByChainId = {
  421614: {
    // Arbitrum Sepolia's chain ID
    realitio: "0xB78396EFaF0a177d125e9d45B2C6398Ac5f803B9",
    foreignChainId: 11155111, // Arbitrum Sepolia's chain ID
  },
  42161: {
    // Arbitrum One
    realitio: "0x5D18bD4dC5f1AC8e9bD9B666Bd71cB35A327C4A9",
    foreignChainId: 1,
  },
};
const metadata =
  '{"tos":"ipfs://QmNV5NWwCudYKfiHuhdWxccrPyxs4DnbLGQace2oMKHkZv/Question_Resolution_Policy.pdf", "foreignProxy":true}'; // Same for all chains.

async function main() {
  console.log(`Running deployment script for home proxy contract on Arbitrum`);

  const { providers } = ethers;
  const foreignNetworks = {
    42161: hre.config.networks.mainnet,
    421614: hre.config.networks.sepolia,
  };

  const chainId = hre.network.config.chainId;
  const { url } = foreignNetworks[chainId];
  const provider = new providers.JsonRpcProvider(url);
  const [account] = await ethers.getSigners();

  const nonce = await provider.getTransactionCount(account.address);
  console.log(`Nonce: ${nonce}`);
  const transaction = {
    from: account.address,
    nonce: nonce,
  };
  const foreignProxy = ethers.utils.getContractAddress(transaction);
  console.log(`Foreign proxy: ${foreignProxy}`);

  const { foreignChainId, realitio } = paramsByChainId[chainId];

  const artifact = await ethers.getContractFactory("RealitioHomeProxyArb");

  const homeProxy = await artifact.deploy(realitio, foreignChainId, foreignProxy, metadata);
  const contractAddress = homeProxy.address;
  console.log(`RealitioHomeProxyArb was deployed to ${contractAddress}`);
}

// Execute the deployment script
main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
