// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {FunctionsClient} from "@chainlink/contracts/src/v0.8/functions/v1_0_0/FunctionsClient.sol";
import {ConfirmedOwner} from "@chainlink/contracts/src/v0.8/shared/access/ConfirmedOwner.sol";
import {FunctionsRequest} from "@chainlink/contracts/src/v0.8/functions/v1_0_0/libraries/FunctionsRequest.sol";
import "@openzeppelin/contracts/utils/Strings.sol";

/**
 * @title TakumiPay
 * @notice This contract calls an external purchase API using Chainlink Functions,
 *         decodes the response, and stores it in an array of Purchase structs.
 */
contract TakumiPay is FunctionsClient, ConfirmedOwner {
    using FunctionsRequest for FunctionsRequest.Request;
    using Strings for address;

    // State variables for tracking request details
    bytes32 public s_lastRequestId;
    bytes public s_lastResponse;
    bytes public s_lastError;
    string[] public purchases;

    // Event emitted when a response is received and stored
    event Response(
        bytes32 indexed requestId,
        string purchaseResult,
        bytes response,
        bytes err
    );

    // Router address for Chainlink Functions on Sepolia
    address router = 0xb83E47C2bC239B3bf370bc41e1459A34b41238D0;

    // Inline JavaScript source code that builds the API URL and returns a delimited string.
    // Expects:
    //   args[0] = contract address (hex string)
    //   args[1] = productId
    string source =
        "const contractAddress = args[0];"
        "const productId = args[1];"
        "const url = 'http://195.26.240.233:3000/purchase';"
        "const body = { contractAddress: contractAddress, productId: productId };"
        "const headers = { 'Content-Type': 'application/json', 'X-API-Key': 'your_api_key_here' };"
        "const apiResponse = await Functions.makeHttpRequest({ url: url, method: 'POST', headers: headers, data: body });"
        "if (apiResponse.error) {"
        "  throw Error('Request failed');"
        "}"
        "const { data } = apiResponse;"
        "return Functions.encodeString("
        "  `${data.status}#${data.transactionId}#${data.contractAddress}#${data.product.id}#${data.product.name}#${data.product.price}#${data.timestamp}`"
        ");";
    // DON ID for Sepolia (Decentralized Oracle Network ID)
    bytes32 donID =
        0x66756e2d657468657265756d2d7365706f6c69612d3100000000000000000000;

    /**
     * @notice Constructor initializes the contract with the Chainlink Functions router.
     */
    constructor() FunctionsClient(router) ConfirmedOwner(msg.sender) {}

    /**
     * @notice Sends a Chainlink Functions request to call the purchase API.
     * @param subscriptionId The subscription ID used for billing.
     * @param _productId The product ID to include in the API call.
     * @param _gasLimit The gas limit to be used for the callback execution.
     * @return requestId The unique identifier of the request.
     */
    function purchaseProduct(
        uint64 subscriptionId,
        string calldata _productId,
        uint32 _gasLimit
    ) external onlyOwner returns (bytes32 requestId) {
        FunctionsRequest.Request memory req;
        req.initializeRequestForInlineJavaScript(source);

        // Build arguments: first, the contract address (as a hex string), then the productId.
        string[] memory args = new string[](2);
        args[0] = Strings.toHexString(address(this));
        args[1] = _productId;
        req.setArgs(args);

        // Encode the request and send it via the Functions router using the provided _gasLimit.
        s_lastRequestId = _sendRequest(
            req.encodeCBOR(),
            subscriptionId,
            _gasLimit,
            donID
        );

        return s_lastRequestId;
    }

    /**
     * @notice Callback function invoked by the Chainlink Functions oracle.
     *         It decodes the delimited response and stores it in the purchases array.
     * @param requestId The ID of the request.
     * @param response The encoded API response.
     * @param err Any error encountered during the API call.
     */
    function fulfillRequest(
        bytes32 requestId,
        bytes memory response,
        bytes memory err
    ) internal override {
        require(s_lastRequestId == requestId, "Unexpected request ID");
        s_lastResponse = response;
        s_lastError = err;

        // Convert response bytes to a string.
        string memory fullResponse = string(response);

        purchases.push(fullResponse);

        emit Response(requestId, fullResponse, response, err);
    }
}
