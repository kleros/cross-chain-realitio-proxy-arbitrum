// SPDX-License-Identifier: MIT

pragma solidity 0.8.25;

import "../RealitioHomeProxyArb.sol";
import "./MockBridge.sol";

/// @dev MockHomeProxy to bypass the modifier and usage of precompile.
contract MockRealitioHomeProxy is RealitioHomeProxyArb {
    address public mockInbox;
    MockBridge public mockBridge;

    /// @dev Override the original one
    modifier onlyForeignProxyAlias() override {
        require(msg.sender == mockInbox, "Can only be called by foreign proxy");
        _;
    }

    constructor(
        RealitioInterface _realitio,
        uint256 _foreignChainId,
        address _foreignProxy,
        string memory _metadata,
        address _mockInbox,
        MockBridge _mockBridge
    ) RealitioHomeProxyArb(_realitio, _foreignChainId, _foreignProxy, _metadata) {
        mockInbox = _mockInbox;
        mockBridge = _mockBridge;
    }

    function sendToL1(bytes memory _data) internal override {
        mockBridge.sendAsBridge(foreignProxy, _data);
    }
}
