const Web3 = require("web3");
const RealitioForeignArbitrationProxy = require("@kleros/cross-chain-realitio-contracts/artifacts/src/RealitioForeignProxyArb.sol/RealitioForeignProxyArb.json");
const RealitioHomeArbitrationProxy = require("@kleros/cross-chain-realitio-contracts/artifacts/src/RealitioHomeProxyArb.sol/RealitioHomeProxyArb.json");
const RealitioInterface = require("@kleros/cross-chain-realitio-contracts/artifacts/src/RealitioInterface.sol/RealitioInterface.json");
const RealitioQuestion = require("@realitio/realitio-lib/formatters/question.js");

const isNil = (value) => value === undefined || value === null;

const CONCURRENT_QUERIES = 100;
const BLOCK_RANGE = 1000;

module.exports = async function getMetaEvidence() {
  const { disputeID, arbitrableContractAddress, arbitrableJsonRpcUrl, arbitratorJsonRpcUrl, jsonRpcUrl } =
    scriptParameters;
  if (isNil(disputeID) || isNil(arbitrableContractAddress)) {
    return rejectScript("Both `disputeID` and `arbitrableContractAddress` script parameters are required");
  }

  const foreignWeb3 = new Web3(arbitratorJsonRpcUrl || jsonRpcUrl);
  async function getForeignEventLog(contract, event, filter) {
    const latestBlockNumber = await foreignWeb3.eth.getBlock("latest").then((block) => block.number);
    let upperBound = latestBlockNumber;
    let result = [];
    while (result.length === 0 && upperBound > 0) {
      const queries = [];
      for (let i = 1; i <= CONCURRENT_QUERIES; i++) {
        queries.push(
          contract.getPastEvents(event, {
            filter,
            fromBlock: Math.max(upperBound - BLOCK_RANGE, 0),
            toBlock: upperBound,
          })
        );
        upperBound = upperBound - BLOCK_RANGE;
      }
      result = await Promise.all(queries).then((results) => results.flat(Infinity));
    }
    return result;
  }
  const foreignProxy = new foreignWeb3.eth.Contract(RealitioForeignArbitrationProxy.abi, arbitrableContractAddress);

  const homeWeb3 = new Web3(arbitrableJsonRpcUrl || jsonRpcUrl);
  const homeProxy = new homeWeb3.eth.Contract(
    RealitioHomeArbitrationProxy.abi,
    await foreignProxy.methods.homeProxy().call()
  );
  const realitio = new homeWeb3.eth.Contract(RealitioInterface.abi, await homeProxy.methods.realitio().call());

  const arbitrationCreatedLogs = await getForeignEventLog(foreignProxy, "ArbitrationCreated", {
    _disputeID: disputeID,
  });

  if (arbitrationCreatedLogs.length != 1) {
    return rejectScript("Could not find the dispute");
  }

  const questionID = arbitrationCreatedLogs[0].returnValues._questionID;
  const questionEventLog = await realitio.getPastEvents("LogNewQuestion", {
    filter: { question_id: questionID },
    fromBlock: 0,
    toBlock: "latest",
  });

  const templateID = questionEventLog[0].returnValues.template_id;
  const templateEventLog = await realitio.getPastEvents("LogNewTemplate", {
    filter: { template_id: templateID },
    fromBlock: 0,
    toBlock: "latest",
  });

  const templateText = templateEventLog[0].returnValues.question_text;
  const questionData = RealitioQuestion.populatedJSONForTemplate(
    templateText,
    questionEventLog[0].returnValues.question
  );

  const erc1497OverridesMixin = questionData.title ? { question: questionData.title } : {};

  switch (questionData.type) {
    case "bool":
      return resolveScript({
        ...erc1497OverridesMixin,
        rulingOptions: {
          type: "single-select",
          titles: ["No", "Yes"],
          reserved: {
            "0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF": "Answered Too Soon",
          },
        },
      });
    case "uint":
      return resolveScript({
        ...erc1497OverridesMixin,
        rulingOptions: {
          type: "uint",
          precision: questionData.decimals,
          reserved: {
            "0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF": "Answered Too Soon",
          },
        },
      });
    case "single-select":
      return resolveScript({
        ...erc1497OverridesMixin,
        rulingOptions: {
          type: "single-select",
          titles: questionData.outcomes,
          reserved: {
            "0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF": "Answered Too Soon",
          },
        },
      });
    case "multiple-select":
      return resolveScript({
        ...erc1497OverridesMixin,
        rulingOptions: {
          type: "multiple-select",
          titles: questionData.outcomes,
          reserved: {
            "0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF": "Answered Too Soon",
          },
        },
      });
    case "datetime":
      return resolveScript({
        ...erc1497OverridesMixin,
        rulingOptions: {
          type: "datetime",
          reserved: {
            "0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF": "Answered Too Soon",
          },
        },
      });
    default:
      return resolveScript({ ...erc1497OverridesMixin });
  }
};
