// SPDX-License-Identifier: MIT
pragma solidity ^0.8.7;
// Remix:
// import {Chainlink, ChainlinkClient} from "@chainlink/contracts@1.3.0/src/v0.8/ChainlinkClient.sol";
// import {ConfirmedOwner} from "@chainlink/contracts@1.3.0/src/v0.8/shared/access/ConfirmedOwner.sol";
// import {LinkTokenInterface} from "@chainlink/contracts@1.3.0/src/v0.8/shared/interfaces/LinkTokenInterface.sol";

// Local:
import "@chainlink/contracts/src/v0.8/ChainlinkClient.sol";
import "@chainlink/contracts/src/v0.8/shared/access/ConfirmedOwner.sol";
import "@chainlink/contracts/src/v0.8/shared/interfaces/LinkTokenInterface.sol";

contract TakumiPay is ChainlinkClient, ConfirmedOwner {
    using Chainlink for Chainlink.Request;

    bytes32 private jobId;
    uint256 private fee;

    event ProductPurchased(bytes32 indexed requestId, string productId);
    event ProductListUpdated();

    constructor() ConfirmedOwner(msg.sender) {
        _setChainlinkToken(0x779877A7B0D9E8603169DdbD7836e478b4624789);
        _setChainlinkOracle(0x6090149792dAAeE9D1D568c9f9a6F6B46AA29eFD);
        jobId = "ca98366cc7314957b8c012c72f05aeeb";
        fee = (1 * 10 ** 18) / 10; // 0.1 LINK
    }

    function purchaseProduct(
        string memory _productId
    ) public returns (bytes32 requestId) {
        Chainlink.Request memory req = _buildChainlinkRequest(
            jobId,
            address(this),
            this.fulfillPurchase.selector
        );

        string memory url = string.concat(
            "http://195.26.240.233:3000/purchase?contractAddress=",
            addressToString(address(this)),
            "&productId=",
            _productId
        );

        req._add("get", url); // Use _add instead of add
        return _sendChainlinkRequest(req, fee);
    }

    function fulfillPurchase(
        bytes32 _requestId
    ) public recordChainlinkFulfillment(_requestId) {
        emit ProductPurchased(_requestId, "productId");
    }

    // Helper to convert address to string
    function addressToString(
        address _addr
    ) internal pure returns (string memory) {
        bytes32 value = bytes32(uint256(uint160(_addr)));
        bytes memory alphabet = "0123456789abcdef";

        bytes memory str = new bytes(42);
        str[0] = "0";
        str[1] = "x";
        for (uint i = 0; i < 20; i++) {
            str[2 + i * 2] = alphabet[uint(uint8(value[i + 12] >> 4))]; // Fixed here
            str[3 + i * 2] = alphabet[uint(uint8(value[i + 12] & 0x0f))]; // Fixed here
        }
        return string(str);
    }

    function withdrawLink() public onlyOwner {
        LinkTokenInterface link = LinkTokenInterface(_chainlinkTokenAddress());
        require(
            link.transfer(msg.sender, link.balanceOf(address(this))),
            "Unable to transfer"
        );
    }
}
