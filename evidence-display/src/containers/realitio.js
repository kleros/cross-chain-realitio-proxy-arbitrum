import React, { Component } from "react";
import Web3 from "web3";

import RealitioForeignArbitrationProxy from "@kleros/cross-chain-realitio-contracts/artifacts/src/RealitioForeignProxyArb.sol/RealitioForeignProxyArb.json";
import RealitioHomeArbitrationProxy from "@kleros/cross-chain-realitio-contracts/artifacts/src/RealitioHomeProxyArb.sol/RealitioHomeProxyArb.json";
import RealitioInterface from "@kleros/cross-chain-realitio-contracts/artifacts/src/interfaces/RealitioInterface.sol/RealitioInterface.json";

import RealityLogo from "../assets/images/reality_eth_logo.png";
import { populatedJSONForTemplate } from "@reality.eth/reality-eth-lib/formatters/question";

const CONCURRENT_QUERIES = 100;
const BLOCK_RANGE = 1000;

class RealitioDisplayInterface extends Component {
  state = { question: null };

  async componentDidMount() {
    if (window.location.search[0] !== "?") return;

    const message = Object.fromEntries(new URLSearchParams(decodeURIComponent(window.location.search.substring(1))));
    console.debug(message);

    const {
      arbitrableContractAddress,
      disputeID,
      arbitratorChainID,
      arbitrableChainID,
      chainID,
      arbitratorJsonRpcUrl,
      arbitrableJsonRpcUrl,
      jsonRpcUrl,
    } = message;

    console.log(arbitrableContractAddress);
    const rpcURL = arbitrableJsonRpcUrl || arbitratorJsonRpcUrl || jsonRpcUrl;
    const cid = arbitrableChainID || arbitratorChainID || chainID;

    if (!rpcURL || !disputeID || !cid) {
      console.error("Evidence display is missing critical information.");
      return;
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

    const realitioContractAddress = await homeProxy.methods.realitio().call();
    const realitio = new homeWeb3.eth.Contract(RealitioInterface.abi, realitioContractAddress);

    const arbitrationCreatedLogs = await getForeignEventLog(foreignProxy, "ArbitrationCreated", { _disputeID: disputeID });

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

    console.log(questionEventLog[0].returnValues.question);
    console.log(templateEventLog[0].returnValues.question_text);
    console.log(
      populatedJSONForTemplate(
        questionEventLog[0].returnValues.question,
        templateEventLog[0].returnValues.question_text
      )
    );
    this.setState({
      questionID,
      chainID: cid,
      realitioContractAddress,
      rawQuestion: questionEventLog[0].returnValues.question,
      rawTemplate: templateEventLog[0].returnValues.question_text,
    });
  }

  render() {
    const { questionID, chainID, realitioContractAddress, rawQuestion, rawTemplate } = this.state;
    if (!questionID) return <div />;

    return (
      <div
        style={{
          backgroundColor: "#f0f4f8",
          padding: "16px",
          fontFamily: "Roboto, sans-serif",
        }}
      >
        <div>
          <img src={RealityLogo} alt="Logo of reality.eth" style={{ maxWidth: "100%" }} />
        </div>
        <hr
          style={{
            height: "3px",
            border: "none",
            backgroundSize: "contain",
            color: "#27b4ee",
            background: "linear-gradient(45deg, #24b3ec 0%, #24b3ec 93%, #b9f9fb  93%, #b9f9fb  95%, #dcfb6c 95%)",
          }}
        />
        <div
          style={{
            marginTop: "16px",
            marginBottom: "32px",
            fontSize: "18x",
            lineHeight: "1.4",
            wordBreak: "break-word",
          }}
        >
          {populatedJSONForTemplate(rawTemplate, rawQuestion).title}
        </div>
        <a
          style={{ color: "#2093ff" }}
          href={`https://reality.eth.limo/app/index.html#!/network/${chainID}/question/${realitioContractAddress}-${questionID}`}
          target="_blank"
          rel="noopener noreferrer"
        >
          See on reality.eth
        </a>
      </div>
    );
  }
}

export default RealitioDisplayInterface;
