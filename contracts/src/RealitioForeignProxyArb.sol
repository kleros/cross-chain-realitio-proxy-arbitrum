// SPDX-License-Identifier: MIT

/**
 *  @authors: [@unknownunknown1]
 *  @reviewers: []
 *  @auditors: []
 *  @bounties: []
 *  @deployments: []
 */

pragma solidity 0.8.25;

import {IDisputeResolver, IArbitrator} from "@kleros/dispute-resolver-interface-contract/contracts/IDisputeResolver.sol";
import {IForeignArbitrationProxy, IHomeArbitrationProxy} from "./interfaces/ArbitrationProxyInterfaces.sol";
import "./interfaces/IInbox.sol";
import "./interfaces/IOutbox.sol";

/**
 * @title Arbitration proxy for Realitio on Ethereum side (A.K.A. the Foreign Chain).
 * @dev This contract is meant to be deployed to the Ethereum chains where Kleros is deployed.
 */
contract RealitioForeignProxyArb is IForeignArbitrationProxy, IDisputeResolver {
    /* Constants */
    uint256 public constant NUMBER_OF_CHOICES_FOR_ARBITRATOR = type(uint256).max; // The number of choices for the arbitrator.
    uint256 public constant REFUSE_TO_ARBITRATE_REALITIO = type(uint256).max; // Constant that represents "Refuse to rule" in realitio format.
    uint256 public constant MULTIPLIER_DIVISOR = 10000; // Divisor parameter for multipliers.
    uint256 public constant META_EVIDENCE_ID = 0; // The ID of the MetaEvidence for disputes.
    uint256 private constant L2_CALL_VALUE = 0; // The msg.value for L2 tx. Always 0.
    uint256 private constant BLOCK_BASE_FEE = 0; // Block baseFee is set to 0 to use current block's baseFee.

    /* Storage */

    enum Status {
        None,
        Requested,
        Created,
        Ruled,
        Relayed,
        Failed
    }

    struct ArbitrationRequest {
        Status status; // Status of the arbitration.
        uint248 deposit; // The deposit paid by the requester at the time of the arbitration.
        uint256 disputeID; // The ID of the dispute in arbitrator contract.
        uint256 answer; // The answer given by the arbitrator.
        Round[] rounds; // Tracks each appeal round of a dispute.
    }

    struct DisputeDetails {
        uint256 arbitrationID; // The ID of the arbitration.
        address requester; // The address of the requester who managed to go through with the arbitration request.
    }

    // Round struct stores the contributions made to particular answers.
    struct Round {
        mapping(uint256 => uint256) paidFees; // Tracks the fees paid in this round in the form paidFees[answer].
        mapping(uint256 => bool) hasPaid; // True if the fees for this particular answer have been fully paid in the form hasPaid[answer].
        mapping(address => mapping(uint256 => uint256)) contributions; // Maps contributors to their contributions for each answer in the form contributions[address][answer].
        uint256 feeRewards; // Sum of reimbursable appeal fees available to the parties that made contributions to the answer that ultimately wins a dispute.
        uint256[] fundedAnswers; // Stores the answer choices that are fully funded.
    }

    address public deployer = msg.sender;
    // TODO: make it immutable after test.
    IArbitrator public arbitrator; // The address of the arbitrator. TRUSTED.
    bytes public arbitratorExtraData; // The extra data used to raise a dispute in the arbitrator.
    address public homeProxy; // Proxy on L2.
    IInbox public inbox; // Arbitrum inbox contract.
    
    // Note that setting gasPriceBid to 0 will result in immediate revert on L1.
    // If the values are set too low the tx won't redeed itself automatically on L2. The deposit will be reimbursed and manual redeem will be activated.
    // It can be done here https://retryable-dashboard.arbitrum.io/tx
    // Preferred values for gasLimit and gasPriceBid are 1500000 and 1000000000 respectively. This values are greatly higher than required amount to ensure automatic redeem.
    uint256 public l2GasLimit; // Gas limit for tx on L2.
    uint256 public gasPriceBid; // Gas price bid for tx on L2.

    // The amount to add to arbitration fees to cover for Arbitrum fees. The leftover will be reimbursed. This is required for Realtio UI.
    // Surplus amount covers submission cost for retryable ticket on L1 + gasLimit * gasPriceBid.
    // Submission cost is based on the length of the passed message and current gas fees. It's usually greatly lower than 0.05 but it's preferred to use this value
    // to account for potential gas fee spikes. It shouldn't be an issue since 0.05 is a relatively low value compared to Kleros arbitration cost
    // and the leftover will be reimbursed anyway.
    uint256 public surplusAmount; 

    // Multipliers are in basis points.
    uint256 public immutable winnerMultiplier; // Multiplier for calculating the appeal fee that must be paid for the answer that was chosen by the arbitrator in the previous round.
    uint256 public immutable loserMultiplier; // Multiplier for calculating the appeal fee that must be paid for the answer that the arbitrator didn't rule for in the previous round.
    uint256 public immutable loserAppealPeriodMultiplier; // Multiplier for calculating the duration of the appeal period for the loser, in basis points.

    mapping(uint256 => mapping(address => ArbitrationRequest)) public arbitrationRequests; // Maps arbitration ID to its data. arbitrationRequests[uint(questionID)][requester].
    mapping(uint256 => DisputeDetails) public disputeIDToDisputeDetails; // Maps external dispute ids to local arbitration ID and requester who was able to complete the arbitration request.
    mapping(uint256 => bool) public arbitrationIDToDisputeExists; // Whether a dispute has already been created for the given arbitration ID or not.
    mapping(uint256 => address) public arbitrationIDToRequester; // Maps arbitration ID to the requester who was able to complete the arbitration request.

    event RetryableTicketCreated(uint256 indexed ticketId);

    modifier onlyL2Bridge() {
        IBridge bridge = inbox.bridge();
        require(msg.sender == address(bridge), "NOT_BRIDGE");
        IOutbox outbox = IOutbox(bridge.activeOutbox());
        address l2Sender = outbox.l2ToL1Sender();
        require(l2Sender == homeProxy, "Can only be called by Home proxy");
        _;
    }

    /**
     * @notice Creates an arbitration proxy on the foreign chain (L1).
     * @param _arbitrator Arbitrator contract address.
     * @param _arbitratorExtraData The extra data used to raise a dispute in the arbitrator.
     * @param _inbox L2 inbox.
     * @param _surplusAmount The surplus amount to cover Arbitrum fees.
     * @param _l2GasLimit L2 gas limit 
     * @param _gasPriceBid Max gas price L2.
     * @param _metaEvidence The URI of the meta evidence file.
     * @param _winnerMultiplier Multiplier for calculating the appeal cost of the winning answer.
     * @param _loserMultiplier Multiplier for calculating the appeal cost of the losing answer.
     * @param _loserAppealPeriodMultiplier Multiplier for calculating the appeal period for the losing answer.
     */
    constructor(
        IArbitrator _arbitrator,
        bytes memory _arbitratorExtraData,
        address _inbox,
        uint256 _surplusAmount,
        uint256 _l2GasLimit,
        uint256 _gasPriceBid,
        string memory _metaEvidence,
        uint256 _winnerMultiplier,
        uint256 _loserMultiplier,
        uint256 _loserAppealPeriodMultiplier
    ) {
        arbitrator = _arbitrator;
        arbitratorExtraData = _arbitratorExtraData;
        inbox = IInbox(_inbox);
        surplusAmount = _surplusAmount;
        l2GasLimit = _l2GasLimit;
        gasPriceBid = _gasPriceBid;
        winnerMultiplier = _winnerMultiplier;
        loserMultiplier = _loserMultiplier;
        loserAppealPeriodMultiplier = _loserAppealPeriodMultiplier;

        emit MetaEvidence(META_EVIDENCE_ID, _metaEvidence);
    }

    /* External and public */

    /**
     * @notice Set home proxy.
     * @param _homeProxy Address of the proxy on L2.
     */
    // TODO: move to constructor
    function setHomeProxy(address _homeProxy) external {
        require(msg.sender == deployer, "Only deployer can");
        homeProxy = _homeProxy;
        deployer = address(0);
    }

    // TODO: remove these 4 after testing. Temp functions. Keep the governance as it's better to have options and we can redeploy if needed anyway
    function changeL2GasLimit(uint256 _l2GasLimit) external {
        require(msg.sender == deployer, "Only deployer can");
        l2GasLimit = _l2GasLimit;
    }

    function changeGasPriceBid(uint256 _gasPriceBid) external {
        require(msg.sender == deployer, "Only deployer can");
        gasPriceBid = _gasPriceBid;
    }

    function changeSurplus(uint256 _surplus) external {
        require(msg.sender == deployer, "Only deployer can");
        surplusAmount = _surplus;
    }

    function changeArbitrator(IArbitrator _arbitrator, string memory _metaEvidence) external {
        require(msg.sender == deployer, "Only deployer can");
        arbitrator = _arbitrator;
        emit MetaEvidence(META_EVIDENCE_ID, _metaEvidence);
    }

    // ************************ //
    // *    Realitio logic    * //
    // ************************ //

    /**
     * @notice Requests arbitration for the given question and contested answer.
     * @param _questionID The ID of the question.
     * @param _maxPrevious The maximum value of the current bond for the question. The arbitration request will get rejected if the current bond is greater than _maxPrevious. If set to 0, _maxPrevious is ignored.
     */
    function requestArbitration(bytes32 _questionID, uint256 _maxPrevious) external payable override {
        require(homeProxy != address(0), "Home proxy is not set");
        require(!arbitrationIDToDisputeExists[uint256(_questionID)], "Dispute already created");

        ArbitrationRequest storage arbitration = arbitrationRequests[uint256(_questionID)][msg.sender];
        require(arbitration.status == Status.None, "Arbitration already requested");

        bytes4 methodSelector = IHomeArbitrationProxy.receiveArbitrationRequest.selector;
        bytes memory data = abi.encodeWithSelector(methodSelector, _questionID, msg.sender, _maxPrevious);
        
        // Taken from here https://docs.arbitrum.io/for-devs/troubleshooting-building#what-is-a-retryable-tickets-submission-fee-how-can-i-calculate-it-what-happens-if-i-the-fee-i-provide-is-insufficient
        uint256 maxSubmissionCost = inbox.calculateRetryableSubmissionFee(data.length, BLOCK_BASE_FEE);
        uint256 arbFee = arbGasFee(maxSubmissionCost);
        uint256 arbitrationCost = arbitrator.arbitrationCost(arbitratorExtraData);
        require(msg.value >= arbitrationCost + arbFee, "Deposit value too low");

        arbitration.status = Status.Requested;
        arbitration.deposit = uint248(msg.value - arbFee);

        uint256 ticketID = inbox.createRetryableTicket{value: arbFee}(
            homeProxy,
            L2_CALL_VALUE,
            maxSubmissionCost,
            msg.sender, // excessFeeRefundAddress
            msg.sender, // callValueRefundAddress
            l2GasLimit,
            gasPriceBid,
            data
        );

        emit RetryableTicketCreated(ticketID);

        emit ArbitrationRequested(_questionID, msg.sender, _maxPrevious);
    }

    /**
     * @notice Receives the acknowledgement of the arbitration request for the given question and requester. TRUSTED.
     * @param _questionID The ID of the question.
     * @param _requester The requester.
     */
    function receiveArbitrationAcknowledgement(bytes32 _questionID, address _requester) public override onlyL2Bridge {
        uint256 arbitrationID = uint256(_questionID);
        ArbitrationRequest storage arbitration = arbitrationRequests[arbitrationID][_requester];
        require(arbitration.status == Status.Requested, "Invalid arbitration status");

        uint256 arbitrationCost = arbitrator.arbitrationCost(arbitratorExtraData);
        if (arbitration.deposit >= arbitrationCost) {
            try
                arbitrator.createDispute{value: arbitrationCost}(NUMBER_OF_CHOICES_FOR_ARBITRATOR, arbitratorExtraData)
            returns (uint256 disputeID) {
                DisputeDetails storage disputeDetails = disputeIDToDisputeDetails[disputeID];
                disputeDetails.arbitrationID = arbitrationID;
                disputeDetails.requester = _requester;

                arbitrationIDToDisputeExists[arbitrationID] = true;
                arbitrationIDToRequester[arbitrationID] = _requester;

                // At this point, arbitration.deposit is guaranteed to be greater than or equal to the arbitration cost.
                uint256 remainder = arbitration.deposit - arbitrationCost;

                arbitration.status = Status.Created;
                arbitration.deposit = 0;
                arbitration.disputeID = disputeID;
                arbitration.rounds.push();

                if (remainder > 0) {
                    payable(_requester).send(remainder);
                }

                emit ArbitrationCreated(_questionID, _requester, disputeID);
                emit Dispute(arbitrator, disputeID, META_EVIDENCE_ID, arbitrationID);
            } catch {
                arbitration.status = Status.Failed;
                emit ArbitrationFailed(_questionID, _requester);
            }
        } else {
            arbitration.status = Status.Failed;
            emit ArbitrationFailed(_questionID, _requester);
        }
    }

    /**
     * @notice Receives the cancelation of the arbitration request for the given question and requester. TRUSTED.
     * @param _questionID The ID of the question.
     * @param _requester The requester.
     */
    function receiveArbitrationCancelation(bytes32 _questionID, address _requester) public override onlyL2Bridge {
        uint256 arbitrationID = uint256(_questionID);
        ArbitrationRequest storage arbitration = arbitrationRequests[arbitrationID][_requester];
        require(arbitration.status == Status.Requested, "Invalid arbitration status");
        uint256 deposit = arbitration.deposit;

        delete arbitrationRequests[arbitrationID][_requester];
        payable(_requester).send(deposit);

        emit ArbitrationCanceled(_questionID, _requester);
    }

    /**
     * @notice Cancels the arbitration in case the dispute could not be created. Requires a small deposit to cover arbitrum fees.
     * @param _questionID The ID of the question.
     * @param _requester The address of the arbitration requester.
     */
    function handleFailedDisputeCreation(bytes32 _questionID, address _requester) external payable override {
        uint256 arbitrationID = uint256(_questionID);
        ArbitrationRequest storage arbitration = arbitrationRequests[arbitrationID][_requester];
        require(arbitration.status == Status.Failed, "Invalid arbitration status");
            
        bytes4 methodSelector = IHomeArbitrationProxy.receiveArbitrationFailure.selector;
        bytes memory data = abi.encodeWithSelector(methodSelector, _questionID, _requester);

        uint256 maxSubmissionCost = inbox.calculateRetryableSubmissionFee(data.length, BLOCK_BASE_FEE);
        uint256 arbFee = arbGasFee(maxSubmissionCost);
        require(msg.value >= arbFee, "Should cover arbitrum fee");
        uint256 deposit = arbitration.deposit;

        delete arbitrationRequests[arbitrationID][_requester];
        uint256 surplusValue = msg.value - arbFee;
        payable(msg.sender).send(surplusValue);
        payable(_requester).send(deposit);

        uint256 ticketID = inbox.createRetryableTicket{value: arbFee}(
            homeProxy,
            L2_CALL_VALUE,
            maxSubmissionCost,
            msg.sender, // excessFeeRefundAddress
            msg.sender, // callValueRefundAddress
            l2GasLimit,
            gasPriceBid,
            data
        );

        emit RetryableTicketCreated(ticketID);

        emit ArbitrationCanceled(_questionID, _requester);
    }

    // ********************************* //
    // *    Appeals and arbitration    * //
    // ********************************* //

    /**
     * @notice Takes up to the total amount required to fund an answer. Reimburses the rest. Creates an appeal if at least two answers are funded.
     * @param _arbitrationID The ID of the arbitration, which is questionID cast into uint256.
     * @param _answer One of the possible rulings the arbitrator can give that the funder considers to be the correct answer to the question.
     * Note that the answer has Kleros denomination, meaning that it has '+1' offset compared to Realitio format.
     * Also note that '0' answer can be funded.
     * @return Whether the answer was fully funded or not.
     */
    function fundAppeal(uint256 _arbitrationID, uint256 _answer) external payable override returns (bool) {
        ArbitrationRequest storage arbitration = arbitrationRequests[_arbitrationID][
            arbitrationIDToRequester[_arbitrationID]
        ];
        require(arbitration.status == Status.Created, "No dispute to appeal.");

        uint256 disputeID = arbitration.disputeID;
        (uint256 appealPeriodStart, uint256 appealPeriodEnd) = arbitrator.appealPeriod(disputeID);
        require(block.timestamp >= appealPeriodStart && block.timestamp < appealPeriodEnd, "Appeal period is over.");

        uint256 multiplier;
        {
            uint256 winner = arbitrator.currentRuling(disputeID);
            if (winner == _answer) {
                multiplier = winnerMultiplier;
            } else {
                require(
                    block.timestamp - appealPeriodStart <
                        ((appealPeriodEnd - appealPeriodStart) * (loserAppealPeriodMultiplier)) / MULTIPLIER_DIVISOR,
                    "Appeal period is over for loser"
                );
                multiplier = loserMultiplier;
            }
        }

        uint256 lastRoundID = arbitration.rounds.length - 1;
        Round storage round = arbitration.rounds[lastRoundID];
        require(!round.hasPaid[_answer], "Appeal fee is already paid.");
        uint256 appealCost = arbitrator.appealCost(disputeID, arbitratorExtraData);
        uint256 totalCost = appealCost + ((appealCost * multiplier) / MULTIPLIER_DIVISOR);

        // Take up to the amount necessary to fund the current round at the current costs.
        uint256 contribution = totalCost - (round.paidFees[_answer]) > msg.value
            ? msg.value
            : totalCost - (round.paidFees[_answer]);
        emit Contribution(_arbitrationID, lastRoundID, _answer, msg.sender, contribution);

        round.contributions[msg.sender][_answer] += contribution;
        round.paidFees[_answer] += contribution;
        if (round.paidFees[_answer] >= totalCost) {
            round.feeRewards += round.paidFees[_answer];
            round.fundedAnswers.push(_answer);
            round.hasPaid[_answer] = true;
            emit RulingFunded(_arbitrationID, lastRoundID, _answer);
        }

        if (round.fundedAnswers.length > 1) {
            // At least two sides are fully funded.
            arbitration.rounds.push();

            round.feeRewards = round.feeRewards - appealCost;
            arbitrator.appeal{value: appealCost}(disputeID, arbitratorExtraData);
        }

        if (msg.value - contribution > 0) payable(msg.sender).send(msg.value - contribution); // Sending extra value back to contributor. It is the user's responsibility to accept ETH.
        return round.hasPaid[_answer];
    }

    /**
     * @notice Sends the fee stake rewards and reimbursements proportional to the contributions made to the winner of a dispute. Reimburses contributions if there is no winner.
     * @param _arbitrationID The ID of the arbitration.
     * @param _beneficiary The address to send reward to.
     * @param _round The round from which to withdraw.
     * @param _answer The answer to query the reward from.
     * @return reward The withdrawn amount.
     */
    function withdrawFeesAndRewards(
        uint256 _arbitrationID,
        address payable _beneficiary,
        uint256 _round,
        uint256 _answer
    ) public override returns (uint256 reward) {
        address requester = arbitrationIDToRequester[_arbitrationID];
        ArbitrationRequest storage arbitration = arbitrationRequests[_arbitrationID][requester];
        Round storage round = arbitration.rounds[_round];
        require(arbitration.status == Status.Ruled, "Dispute not resolved");
        // Allow to reimburse if funding of the round was unsuccessful.
        if (!round.hasPaid[_answer]) {
            reward = round.contributions[_beneficiary][_answer];
        } else if (!round.hasPaid[arbitration.answer]) {
            // Reimburse unspent fees proportionally if the ultimate winner didn't pay appeal fees fully.
            // Note that if only one side is funded it will become a winner and this part of the condition won't be reached.
            reward = round.fundedAnswers.length > 1
                ? (round.contributions[_beneficiary][_answer] * round.feeRewards) /
                    (round.paidFees[round.fundedAnswers[0]] + round.paidFees[round.fundedAnswers[1]])
                : 0;
        } else if (arbitration.answer == _answer) {
            uint256 paidFees = round.paidFees[_answer];
            // Reward the winner.
            reward = paidFees > 0 ? (round.contributions[_beneficiary][_answer] * round.feeRewards) / paidFees : 0;
        }

        if (reward != 0) {
            round.contributions[_beneficiary][_answer] = 0;
            _beneficiary.send(reward); // It is the user's responsibility to accept ETH.
            emit Withdrawal(_arbitrationID, _round, _answer, _beneficiary, reward);
        }
    }

    /**
     * @notice Allows to withdraw any rewards or reimbursable fees for all rounds at once.
     * @dev This function is O(n) where n is the total number of rounds. Arbitration cost of subsequent rounds is `A(n) = 2A(n-1) + 1`.
     *      So because of this exponential growth of costs, you can assume n is less than 10 at all times.
     * @param _arbitrationID The ID of the arbitration.
     * @param _beneficiary The address that made contributions.
     * @param _contributedTo Answer that received contributions from contributor.
     */
    function withdrawFeesAndRewardsForAllRounds(
        uint256 _arbitrationID,
        address payable _beneficiary,
        uint256 _contributedTo
    ) external override {
        address requester = arbitrationIDToRequester[_arbitrationID];
        ArbitrationRequest storage arbitration = arbitrationRequests[_arbitrationID][requester];

        uint256 numberOfRounds = arbitration.rounds.length;
        for (uint256 roundNumber = 0; roundNumber < numberOfRounds; roundNumber++) {
            withdrawFeesAndRewards(_arbitrationID, _beneficiary, roundNumber, _contributedTo);
        }
    }

    /**
     * @notice Allows to submit evidence for a particular question.
     * @param _arbitrationID The ID of the arbitration related to the question.
     * @param _evidenceURI Link to evidence.
     */
    function submitEvidence(uint256 _arbitrationID, string calldata _evidenceURI) external override {
        emit Evidence(arbitrator, _arbitrationID, msg.sender, _evidenceURI);
    }

    /**
     * @notice Rules a specified dispute. Can only be called by the arbitrator.
     * @dev Accounts for the situation where the winner loses a case due to paying less appeal fees than expected.
     * @param _disputeID The ID of the dispute in the ERC792 arbitrator.
     * @param _ruling The ruling given by the arbitrator.
     */
    function rule(uint256 _disputeID, uint256 _ruling) external override {
        DisputeDetails storage disputeDetails = disputeIDToDisputeDetails[_disputeID];
        uint256 arbitrationID = disputeDetails.arbitrationID;
        address requester = disputeDetails.requester;

        ArbitrationRequest storage arbitration = arbitrationRequests[arbitrationID][requester];
        require(msg.sender == address(arbitrator), "Only arbitrator allowed");
        require(arbitration.status == Status.Created, "Invalid arbitration status");
        uint256 finalRuling = _ruling;

        // If one side paid its fees, the ruling is in its favor. Note that if the other side had also paid, an appeal would have been created.
        Round storage round = arbitration.rounds[arbitration.rounds.length - 1];
        if (round.fundedAnswers.length == 1) finalRuling = round.fundedAnswers[0];

        arbitration.answer = finalRuling;
        arbitration.status = Status.Ruled;
        emit Ruling(arbitrator, _disputeID, finalRuling);
    }

    /**
     * @notice Relays the ruling to home proxy. Requires a small deposit to cover arbitrum fees.
     * @param _questionID The ID of the question.
     * @param _requester The address of the arbitration requester.
     */
    function relayRule(bytes32 _questionID, address _requester) external payable {
        uint256 arbitrationID = uint256(_questionID);
        ArbitrationRequest storage arbitration = arbitrationRequests[arbitrationID][_requester];
        require(arbitration.status == Status.Ruled, "Dispute not resolved");
        
        // Realitio ruling is shifted by 1 compared to Kleros.
        uint256 realitioRuling = arbitration.answer != 0 ? arbitration.answer - 1 : REFUSE_TO_ARBITRATE_REALITIO;

        bytes4 methodSelector = IHomeArbitrationProxy.receiveArbitrationAnswer.selector;
        bytes memory data = abi.encodeWithSelector(methodSelector, _questionID, bytes32(realitioRuling));

        uint256 maxSubmissionCost = inbox.calculateRetryableSubmissionFee(data.length, BLOCK_BASE_FEE);
        uint256 arbFee = arbGasFee(maxSubmissionCost);
        require(msg.value >= arbFee, "Should cover arbitrum fee");

        arbitration.status = Status.Relayed;

        uint256 ticketID = inbox.createRetryableTicket{value: arbFee}(
            homeProxy,
            L2_CALL_VALUE,
            maxSubmissionCost,
            msg.sender, // excessFeeRefundAddress
            msg.sender, // callValueRefundAddress
            l2GasLimit,
            gasPriceBid,
            data
        );

        emit RetryableTicketCreated(ticketID);
        emit RulingRelayed(_questionID, bytes32(realitioRuling));

        if (msg.value - arbFee > 0) payable(msg.sender).send(msg.value - arbFee); // Sending extra value back to contributor. It is the user's responsibility to accept ETH.
    }

    /* External Views */

    /**
     * @notice Returns stake multipliers.
     * @return winner Winners stake multiplier.
     * @return loser Losers stake multiplier.
     * @return loserAppealPeriod Multiplier for calculating an appeal period duration for the losing side.
     * @return divisor Multiplier divisor.
     */
    function getMultipliers()
        external
        view
        override
        returns (uint256 winner, uint256 loser, uint256 loserAppealPeriod, uint256 divisor)
    {
        return (winnerMultiplier, loserMultiplier, loserAppealPeriodMultiplier, MULTIPLIER_DIVISOR);
    }

    /**
     * @notice Returns number of possible ruling options. Valid rulings are [0, return value].
     * @return count The number of ruling options.
     */
    function numberOfRulingOptions(uint256 /* _arbitrationID */) external pure override returns (uint256) {
        return NUMBER_OF_CHOICES_FOR_ARBITRATOR;
    }

    /**
     * @notice Gets the fee to create a dispute.
     * @return The fee to create a dispute.
     */
    function getDisputeFee(bytes32 /* _questionID */) external view override returns (uint256) {
        return arbitrator.arbitrationCost(arbitratorExtraData) + surplusAmount;
    }

    /**
     * @notice Gets the number of rounds of the specific question.
     * @param _arbitrationID The ID of the arbitration related to the question.
     * @return The number of rounds.
     */
    function getNumberOfRounds(uint256 _arbitrationID) external view returns (uint256) {
        address requester = arbitrationIDToRequester[_arbitrationID];
        ArbitrationRequest storage arbitration = arbitrationRequests[_arbitrationID][requester];
        return arbitration.rounds.length;
    }

    /**
     * @notice Gets the information of a round of a question.
     * @param _arbitrationID The ID of the arbitration.
     * @param _round The round to query.
     * @return paidFees The amount of fees paid for each fully funded answer.
     * @return feeRewards The amount of fees that will be used as rewards.
     * @return fundedAnswers IDs of fully funded answers.
     */
    function getRoundInfo(
        uint256 _arbitrationID,
        uint256 _round
    ) external view returns (uint256[] memory paidFees, uint256 feeRewards, uint256[] memory fundedAnswers) {
        address requester = arbitrationIDToRequester[_arbitrationID];
        ArbitrationRequest storage arbitration = arbitrationRequests[_arbitrationID][requester];
        Round storage round = arbitration.rounds[_round];
        fundedAnswers = round.fundedAnswers;

        paidFees = new uint256[](round.fundedAnswers.length);

        for (uint256 i = 0; i < round.fundedAnswers.length; i++) {
            paidFees[i] = round.paidFees[round.fundedAnswers[i]];
        }

        feeRewards = round.feeRewards;
    }

    /**
     * @notice Gets the information of a round of a question for a specific answer choice.
     * @param _arbitrationID The ID of the arbitration.
     * @param _round The round to query.
     * @param _answer The answer choice to get funding status for.
     * @return raised The amount paid for this answer.
     * @return fullyFunded Whether the answer is fully funded or not.
     */
    function getFundingStatus(
        uint256 _arbitrationID,
        uint256 _round,
        uint256 _answer
    ) external view returns (uint256 raised, bool fullyFunded) {
        address requester = arbitrationIDToRequester[_arbitrationID];
        ArbitrationRequest storage arbitration = arbitrationRequests[_arbitrationID][requester];
        Round storage round = arbitration.rounds[_round];

        raised = round.paidFees[_answer];
        fullyFunded = round.hasPaid[_answer];
    }

    /**
     * @notice Gets contributions to the answers that are fully funded.
     * @param _arbitrationID The ID of the arbitration.
     * @param _round The round to query.
     * @param _contributor The address whose contributions to query.
     * @return fundedAnswers IDs of the answers that are fully funded.
     * @return contributions The amount contributed to each funded answer by the contributor.
     */
    function getContributionsToSuccessfulFundings(
        uint256 _arbitrationID,
        uint256 _round,
        address _contributor
    ) external view returns (uint256[] memory fundedAnswers, uint256[] memory contributions) {
        address requester = arbitrationIDToRequester[_arbitrationID];
        ArbitrationRequest storage arbitration = arbitrationRequests[_arbitrationID][requester];
        Round storage round = arbitration.rounds[_round];

        fundedAnswers = round.fundedAnswers;
        contributions = new uint256[](round.fundedAnswers.length);

        for (uint256 i = 0; i < contributions.length; i++) {
            contributions[i] = round.contributions[_contributor][fundedAnswers[i]];
        }
    }

    /**
     * @notice Returns the sum of withdrawable amount.
     * @dev This function is O(n) where n is the total number of rounds.
     * @dev This could exceed the gas limit, therefore this function should be used only as a utility and not be relied upon by other contracts.
     * @param _arbitrationID The ID of the arbitration.
     * @param _beneficiary The contributor for which to query.
     * @param _contributedTo Answer that received contributions from contributor.
     * @return sum The total amount available to withdraw.
     */
    function getTotalWithdrawableAmount(
        uint256 _arbitrationID,
        address payable _beneficiary,
        uint256 _contributedTo
    ) external view override returns (uint256 sum) {
        address requester = arbitrationIDToRequester[_arbitrationID];
        ArbitrationRequest storage arbitration = arbitrationRequests[_arbitrationID][requester];
        if (arbitration.status < Status.Ruled) return sum;

        uint256 finalAnswer = arbitration.answer;
        uint256 noOfRounds = arbitration.rounds.length;
        for (uint256 roundNumber = 0; roundNumber < noOfRounds; roundNumber++) {
            Round storage round = arbitration.rounds[roundNumber];

            if (!round.hasPaid[_contributedTo]) {
                // Allow to reimburse if funding was unsuccessful for this answer option.
                sum += round.contributions[_beneficiary][_contributedTo];
            } else if (!round.hasPaid[finalAnswer]) {
                // Reimburse unspent fees proportionally if the ultimate winner didn't pay appeal fees fully.
                // Note that if only one side is funded it will become a winner and this part of the condition won't be reached.
                sum += round.fundedAnswers.length > 1
                    ? (round.contributions[_beneficiary][_contributedTo] * round.feeRewards) /
                        (round.paidFees[round.fundedAnswers[0]] + round.paidFees[round.fundedAnswers[1]])
                    : 0;
            } else if (finalAnswer == _contributedTo) {
                uint256 paidFees = round.paidFees[_contributedTo];
                // Reward the winner.
                sum += paidFees > 0
                    ? (round.contributions[_beneficiary][_contributedTo] * round.feeRewards) / paidFees
                    : 0;
            }
        }
    }

    /**
     * @notice Casts question ID into uint256 thus returning the related arbitration ID.
     * @param _questionID The ID of the question.
     * @return The ID of the arbitration.
     */
    function questionIDToArbitrationID(bytes32 _questionID) external pure returns (uint256) {
        return uint256(_questionID);
    }

    /**
     * @notice Maps external (arbitrator side) dispute id to local (arbitrable) dispute id.
     * @param _externalDisputeID Dispute id as in arbitrator side.
     * @return localDisputeID Dispute id as in arbitrable contract.
     */
    function externalIDtoLocalID(uint256 _externalDisputeID) external view override returns (uint256) {
        return disputeIDToDisputeDetails[_externalDisputeID].arbitrationID;
    }

    /**
     * @notice Maps external (arbitrator side) dispute id to local (arbitrable) dispute id.
     * @dev Logic that checks if the user have enough funds to create a ticket. This is done by checking if the msg.value provided by the user 
     * is greater than or equal to maxSubmissionCost + l2CallValue + gasLimit * maxFeePerGas.
     * https://docs.arbitrum.io/how-arbitrum-works/arbos/l1-l2-messaging
     * @param _maxSubmissionCost Cost to calculate a retryable ticket on L1.
     * @return arbFee Total arbitrum fee required to pass a message L1->L2.
     */
    function arbGasFee(uint256 _maxSubmissionCost) private view returns (uint256 arbFee) {
        arbFee = _maxSubmissionCost + L2_CALL_VALUE + l2GasLimit * gasPriceBid;
    }
}