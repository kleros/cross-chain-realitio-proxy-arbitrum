const HOME_CHAIN_IDS = [42161, 421614];
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

async function deployHomeProxy({ deployments, getChainId, ethers, config }) {
  console.log(`Running deployment script for home proxy contract on Arbitrum`);

  const { deploy } = deployments;
  const { providers } = ethers;
  const foreignNetworks = {
    42161: config.networks.mainnet,
    421614: config.networks.sepolia,
  };

  const chainId = await getChainId();
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

  const homeProxy = await deploy("RealitioHomeProxyArb", {
    from: account.address,
    args: [realitio, foreignChainId, foreignProxy, metadata],
  });
  const contractAddress = homeProxy.address;
  console.log(`RealitioHomeProxyArb was deployed to ${contractAddress}`);
}

deployHomeProxy.tags = ["HomeChain"];
deployHomeProxy.skip = async ({ getChainId }) => !HOME_CHAIN_IDS.includes(Number(await getChainId()));

module.exports = deployHomeProxy;
