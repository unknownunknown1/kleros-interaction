/**
 *  @title ArbitrableTokenList
 *  @author Matheus Alencar - <mtsalenc@gmail.com>
 *  This code hasn't undertaken bug bounty programs yet.
 */

pragma solidity ^0.4.24;

import "../arbitration/Arbitrable.sol";
import "./PermissionInterface.sol";
/**
 *  @title ArbitrableTokenList
 *  This is a T2CL for tokens. Tokens can be submitted and cleared with a time out for challenging.
 */
contract ArbitrableTokenList is PermissionInterface, Arbitrable {

    /* Enums */

    enum TokenStatus {
        Absent, // The item is not on the list.
        Registered, // The item is on the list.
        RegistrationRequested, // The item has a request to be added to the list.
        ClearingRequested // The item has a request to be removed from the list.
    }

    enum RulingOption {
        Other, // Arbitrator did not rule of refused to rule.
        Accept, // Execute request. Rule in favor of requester.
        Refuse // Refuse request. Rule in favor of challenger.
    }

    enum Party {
        None,
        Submitter,
        Challenger
    }

    /* Structs */

    struct Token {
        TokenStatus status; // Status of the item.
        uint lastAction; // Time of the last action.
        uint challengeRewardBalance; // The amount of funds placed at stake for this item. Does not include arbitrationFees.
        uint challengeReward; // The challengeReward of the item for the round.
        address submitter; // Address of the submitter of the item status change request, if any.
        address challenger; // Address of the challenger, if any.
        uint submitterFees; // The amount of fees paid for the submitter side.
        uint challengerFees; // The amount of fees paid for the challenger side.
        bool disputed; // True if a dispute is taking place.
        uint disputeID; // ID of the dispute, if any.
        uint firstContributionTime; // The time the first contribution was made at.
        uint arbitrationFeesWaitingTime; // The waiting time for fees for each round.
        uint timeToChallenge; // The time to challenge for each round.
    }

    /* Modifiers */

    modifier onlyGovernor {require(msg.sender == governor, "The caller is not the governor."); _;}

    /* Events */

    /**
     *  @dev Called when the item's status changes or when it is challenged/resolved.
     *  @param requester Address of the requester.
     *  @param challenger Address of the challenger, if any.
     *  @param tokenID The tokenID of the item.
     *  @param status The status of the item.
     *  @param disputed Wether the item is being disputed.
     */
    event TokenStatusChange(
        address indexed requester,
        address indexed challenger,
        bytes32 indexed tokenID,
        TokenStatus status,
        bool disputed
    );

    /** @dev Emitted when a contribution is made.
     *  @param _tokenID The ID of the token that the contribution was made to.
     *  @param _contributor The address that sent the contribution.
     *  @param _value The value of the contribution.
     */
    event Contribution(bytes32 indexed _tokenID, address indexed _contributor, uint _value);

    /* Storage */

    // Settings
    uint public challengeReward; // The stake deposit required in addition to arbitration fees for challenging a request.
    uint public timeToChallenge; // The time before a request becomes executable if not challenged.
    uint public arbitrationFeesWaitingTime; // The maximum time to wait for arbitration fees if the dispute is raised.
    uint public stake; // The stake parameter for arbitration fees crowdfunding.
    address public governor; // The address that can update t2clGovernor, arbitrationFeesWaitingTime and challengeReward.

    // Tokens
    mapping(bytes32 => Token) public items;
    mapping(uint => bytes32) public disputeIDToTokenID;
    bytes32[] public itemsList;

    /* Constructor */

    /**
     *  @dev Constructs the arbitrable token list.
     *  @param _arbitrator The chosen arbitrator.
     *  @param _arbitratorExtraData Extra data for the arbitrator contract.
     *  @param _metaEvidence The URI of the meta evidence object.
     *  @param _governor The governor of this contract.
     *  @param _arbitrationFeesWaitingTime The maximum time to wait for arbitration fees if the dispute is raised.
     *  @param _challengeReward The amount in Weis of deposit required for a submission or a challenge in addition to the arbitration fees.
     *  @param _timeToChallenge The time in seconds, parties have to challenge.
     *  @param _stake The stake parameter for sharing fees.
     */
    constructor(
        Arbitrator _arbitrator,
        bytes _arbitratorExtraData,
        string _metaEvidence,
        address _governor,
        uint _arbitrationFeesWaitingTime,
        uint _challengeReward,
        uint _timeToChallenge,
        uint _stake
    ) Arbitrable(_arbitrator, _arbitratorExtraData) public {
        challengeReward = _challengeReward;
        timeToChallenge = _timeToChallenge;
        governor = _governor;
        arbitrationFeesWaitingTime = _arbitrationFeesWaitingTime;
        stake = _stake;
        emit MetaEvidence(0, _metaEvidence);
    }

    /* Public */

    // ************************ //
    // *       Requests       * //
    // ************************ //

    /** @dev Submits a request to change the item status.
     *  @param _tokenID The keccak hash of a JSON object with all of the token's properties and no insignificant whitespaces.
     */
    function requestStatusChange(bytes32 _tokenID) external payable {
        Token storage item = items[_tokenID];
        require(msg.value >= challengeReward, "Not enough ETH.");
        require(!item.disputed, "Token must not be disputed for submitting status change request");

        if (item.status == TokenStatus.Absent)
            item.status = TokenStatus.RegistrationRequested;
        else if (item.status == TokenStatus.Registered)
            item.status = TokenStatus.ClearingRequested;
        else
            revert("Token in wrong status for request.");

        item.challengeRewardBalance = msg.value;
        item.lastAction = now;
        item.submitter = msg.sender;

        item.challengeReward = challengeReward;
        item.arbitrationFeesWaitingTime = arbitrationFeesWaitingTime;
        item.timeToChallenge = timeToChallenge;

        emit TokenStatusChange(msg.sender, address(0), _tokenID, item.status, false);
    }

    /** @dev Challenge and fully fund challenger side of the dispute.
     *  @param _tokenID The tokenID of the item with the request to execute.
     */
    function fundedChallenge(bytes32 _tokenID) external payable {
        Token storage item = items[_tokenID];
        require(item.submitter != address(0), "The specified item does not exist.");
        require(
            !item.disputed || arbitrator.disputeStatus(item.disputeID) == Arbitrator.DisputeStatus.Appealable,
            "The agreement is already disputed and is not appealable."
        );
        require(
            item.status == TokenStatus.RegistrationRequested || item.status == TokenStatus.ClearingRequested,
            "Token does not have any pending requests"
        );
        require(
            msg.value >= item.challengeReward + arbitrator.arbitrationCost(arbitratorExtraData),
            "Not enough ETH."
        );

        item.challengeRewardBalance += item.challengeReward;
        item.challengerFees = msg.value - item.challengeReward;
        item.challenger = msg.sender;
        item.lastAction = now;

        emit Contribution(_tokenID, msg.sender, item.challengerFees);
    }

    /** @dev Fund a side of the dispute.
     *  @param _tokenID The tokenID of the item with the request to execute.
     *  @param _party The side to fund fees. 1 for the submitter and 2 for the challenger.
     */
    function fundDispute(bytes32 _tokenID, Party _party) public payable {
        require(_party == Party.Submitter || _party == Party.Challenger, "Invalid party selection");
        Token storage item = items[_tokenID];
        require(item.submitter != address(0), "The specified item does not exist.");
        require(item.challengeRewardBalance == item.challengeReward * 2, "Both sides must have staked ETH.");
        require(!item.disputed, "Item is already disputed");
        require(
            item.status == TokenStatus.RegistrationRequested || item.status == TokenStatus.ClearingRequested,
            "Token does not have any pending requests"
        );

        uint arbitrationCost = arbitrator.arbitrationCost(arbitratorExtraData);
        if (_party == Party.Submitter)
            item.submitterFees += msg.value;
        else
            item.challengerFees += msg.value;

        if (item.submitterFees >= arbitrationCost && item.challengerFees >= arbitrationCost) {
            item.disputeID = arbitrator.createDispute.value(arbitrationCost)(2, arbitratorExtraData);
            disputeIDToTokenID[item.disputeID] = _tokenID;
            item.disputed = true;
        }
    }

    /** @dev Execute a request after the time for challenging it has passed. Can be called by anyone.
     *  @param _tokenID The tokenID of the item with the request to execute.
     */
    function executeRequest(bytes32 _tokenID) external {
        Token storage item = items[_tokenID];
        require(now - item.lastAction > timeToChallenge, "The time to challenge has not passed yet.");
        require(item.submitter != address(0), "The specified agreement does not exist.");
        require(!item.disputed, "The specified agreement is disputed.");

        if (item.status == TokenStatus.RegistrationRequested)
            item.status = TokenStatus.Registered;
        else if (item.status == TokenStatus.ClearingRequested)
            item.status = TokenStatus.Absent;
        else
            revert("Token in wrong status for executing request.");

        item.lastAction = now;
        item.submitter.send(item.challengeRewardBalance); // Deliberate use of send in order to not block the contract in case of reverting fallback.
        item.challengeRewardBalance = 0;

        emit TokenStatusChange(item.submitter, address(0), _tokenID, item.status, false);
    }

    /** @dev Submit a reference to evidence. EVENT.
     *  @param _evidence A link to an evidence using its URI.
     */
    function submitEvidence(bytes32 _tokenID, string _evidence) public {
        Token storage item = items[_tokenID];
        require(item.disputed, "The item is not disputed");
        emit Evidence(arbitrator, item.disputeID, msg.sender, _evidence);
    }

    // ************************ //
    // *      Governance      * //
    // ************************ //

    /** @dev Changes the `timeToChallenge` storage variable.
     *  @param _timeToChallenge The new `timeToChallenge` storage variable.
     */
    function changeTimeToChallenge(uint _timeToChallenge) external onlyGovernor {
        timeToChallenge = _timeToChallenge;
    }

    /** @dev Changes the `challengeReward` storage variable.
     *  @param _challengeReward The new `challengeReward` storage variable.
     */
    function changeChallengeReward(uint _challengeReward) external onlyGovernor {
        challengeReward = _challengeReward;
    }

    /** @dev Changes the `governor` storage variable.
     *  @param _governor The new `governor` storage variable.
     */
    function changeGovernor(address _governor) external onlyGovernor {
        governor = _governor;
    }

    /** @dev Changes the `stake` storage variable.
     *  @param _stake The new `stake` storage variable.
     */
    function changeStake(uint _stake) public onlyGovernor {
        stake = _stake;
    }

    /** @dev Changes the `arbitrationFeesWaitingTime` storage variable.
     *  @param _arbitrationFeesWaitingTime The new `_arbitrationFeesWaitingTime` storage variable.
     */
    function changeArbitrationFeesWaitingTime(uint _arbitrationFeesWaitingTime) external onlyGovernor {
        arbitrationFeesWaitingTime = _arbitrationFeesWaitingTime;
    }

    /* Public Views */

    /** @dev Return true if the item is allowed. We consider the item to be in the list if its status is contested and it has not won a dispute previously.
     *  @param _tokenID The tokenID of the item to check.
     *  @return allowed True if the item is allowed, false otherwise.
     */
    function isPermitted(bytes32 _tokenID) external view returns (bool allowed) {
        Token storage item = items[_tokenID];
        return item.status == TokenStatus.Registered || item.status == TokenStatus.ClearingRequested;
    }

    /* Internal */

    /**
     *  @dev Execute the ruling of a dispute.
     *  @param _disputeID ID of the dispute in the Arbitrator contract.
     *  @param _ruling Ruling given by the arbitrator. Note that 0 is reserved for "Not able/wanting to make a decision".
     */
    function executeRuling(uint _disputeID, uint _ruling) internal {
        // TODO
    }

    /* Interface Views */

    /** @dev Return the numbers of items in the list per status. This function is O(n) at worst, where n is the number of items. This could exceed the gas limit, therefore this function should only be used for interface display and not by other contracts.
     *  @return The numbers of items in the list per status.
     */
    function itemsCounts()
        external
        view
        returns (
            uint disputed,
            uint absent,
            uint registered,
            uint submitted,
            uint clearingRequested
        )
    {
        for (uint i = 0; i < itemsList.length; i++) {
            Token storage item = items[itemsList[i]];

            if (item.disputed) disputed++;
            if (item.status == TokenStatus.Absent) absent++;
            else if (item.status == TokenStatus.Registered) registered++;
            else if (item.status == TokenStatus.RegistrationRequested) submitted++;
            else if (item.status == TokenStatus.ClearingRequested) clearingRequested++;
        }
    }

    /** @dev Return the values of the items the query finds. This function is O(n) at worst, where n is the number of items. This could exceed the gas limit, therefore this function should only be used for interface display and not by other contracts.
     *  @param _cursor The pagination cursor.
     *  @param _count The number of items to return.
     *  @param _filter The filter to use. Each element of the array in sequence means:
     *  - Include absent items in result.
     *  - Include registered items in result.
     *  - Include items with registration requests that are not disputed in result.
     *  - Include items with clearing requests that are not disputed in result.
     *  - Include disputed items with registration requests in result.
     *  - Include disputed items with clearing requests in result.
     *  - Include items submitted by the caller.
     *  - Include items challenged by the caller.
     *  @param _oldestFirst The sort order to use.
     *  @return The values of the items found and wether there are more items for the current filter and sort.
     */
    function queryTokens(
        bytes32 _cursor,
        uint _count,
        bool[8] _filter,
        bool _oldestFirst
    ) external view returns (bytes32[] values, bool hasMore) {
        uint _cursorIndex;
        values = new bytes32[](_count);
        uint _index = 0;

        if (_cursor == 0)
            _cursorIndex = 0;
        else {
            for (uint j = 0; j < itemsList.length; j++) {
                if (itemsList[j] == _cursor) {
                    _cursorIndex = j;
                    break;
                }
            }
            require(_cursorIndex != 0, "The cursor is invalid.");
        }

        for (
                uint i = _cursorIndex == 0 ? (_oldestFirst ? 0 : 1) : (_oldestFirst ? _cursorIndex + 1 : itemsList.length - _cursorIndex + 1);
                _oldestFirst ? i < itemsList.length : i <= itemsList.length;
                i++
            ) { // Oldest or newest first.
            bytes32 itemID = itemsList[_oldestFirst ? i : itemsList.length - i];
            Token storage item = items[itemID];
            if (
                    /* solium-disable operator-whitespace */
                    (_filter[0] && item.status == TokenStatus.Absent) ||
                    (_filter[1] && item.status == TokenStatus.Registered) ||
                    (_filter[2] && item.status == TokenStatus.RegistrationRequested && !item.disputed) ||
                    (_filter[3] && item.status == TokenStatus.ClearingRequested && !item.disputed) ||
                    (_filter[4] && item.status == TokenStatus.RegistrationRequested && item.disputed) ||
                    (_filter[5] && item.status == TokenStatus.ClearingRequested && item.disputed) ||
                    (_filter[6] && item.submitter == msg.sender) || // My Submissions.
                    (_filter[7] && item.challenger == msg.sender) // My Challenges.
                    /* solium-enable operator-whitespace */
            ) {
                if (_index < _count) {
                    values[_index] = itemsList[_oldestFirst ? i : itemsList.length - i];
                    _index++;
                } else {
                    hasMore = true;
                    break;
                }
            }
        }
    }

}