const FOREIGN_CHAIN_IDS = [11155111, 1];
const paramsByChainId = {
  11155111: {
    arbitrator: "0x90992fb4E15ce0C59aEFfb376460Fda4Ee19C879", // Kleros Liquid on Sepolia
    arbitratorExtraData:
      "0x00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000",
    inbox: "0xaAe29B0366299461418F5324a79Afc425BE5ae21",
    metaEvidence: "/ipfs/QmZdBkzD76TTusernqYosnZKGveHu39muv6ygvqjdEWrrW/metaevidence.json",
  },
  1: {
    arbitrator: "0x988b3a538b618c7a603e1c11ab82cd16dbe28069", // KlerosLiquid address
    arbitratorExtraData:
      "0x0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001f", // General Court - 31 jurors
    inbox: "0x4Dbd4fc535Ac27206064B68FfCf827b0A60BAB3f", // https://docs.arbitrum.io/build-decentralized-apps/reference/useful-addresses
    metaEvidence: "TODO", // Need to reupload with different chain ids.
  },
};

// Note that values apply to both testnet and mainnet since fees are obvserved to be about the same on both chains as of mid 2024.
const surplus = ethers.utils.parseUnits("0.05", "ether"); // This amount is at least x100 times higher than required amount to account for potential gas fee increase on L1. The surplus will be automatically reimbursed.
const l2GasLimit = 1500000;
const gasPriceBid = 1000000000; // x10000 bid of random arb sepolia tx. Gas price * gasLimit will result in additional 0.0015 eth fee for automatic-redeem on L2. The surplus will be reimbursed.
const winnerMultiplier = 3000;
const loserMultiplier = 7000;
const loserAppealPeriodMultiplier = 5000;

async function deployForeignProxy({ deployments, getChainId, ethers, config }) {
  console.log("Starting foreign proxy deployment..");

  const { deploy } = deployments;
  const { providers } = ethers;
  const chainId = await getChainId();
  const { arbitrator, arbitratorExtraData, inbox, metaEvidence } = paramsByChainId[chainId];

  const homeNetworks = {
    1: config.networks.arbitrumOne,
    11155111: config.networks.arbitrumSepolia,
  };

  const { url } = homeNetworks[chainId];
  const provider = new providers.JsonRpcProvider(url);

  const [account] = await ethers.getSigners();
  const nonce = await provider.getTransactionCount(account.address);
  console.log(`Nonce: ${nonce}`);
  const transaction = {
    from: account.address,
    nonce: nonce - 1, // Subtract 1 to get the nonce that was before home proxy deployment
  };

  const homeProxy = ethers.utils.getContractAddress(transaction);
  console.log(`Home proxy: ${homeProxy}`);

  let governor;
  if (chainId === 1) {
    governor = "TODO"; // Determine later
  } else {
    governor = (await ethers.getSigners())[0].address;
  }

  const foreignProxy = await deploy("RealitioForeignProxyArb", {
    from: account.address,
    args: [
      homeProxy,
      governor,
      arbitrator,
      arbitratorExtraData,
      inbox,
      surplus,
      l2GasLimit,
      gasPriceBid,
      metaEvidence,
      [winnerMultiplier, loserMultiplier, loserAppealPeriodMultiplier],
    ],
  });

  console.log(`Foreign proxy contract was successfully deployed at ${foreignProxy.address}`);
}

deployForeignProxy.tags = ["ForeignChain"];
deployForeignProxy.skip = async ({ getChainId }) => !FOREIGN_CHAIN_IDS.includes(Number(await getChainId()));

module.exports = deployForeignProxy;
