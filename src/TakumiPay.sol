// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract TakumiWallet {
    using SafeERC20 for IERC20;

    // ====== Roles ======

    address public owner;
    mapping(address => bool) private admins;
    address[] private adminList;

    // ====== Global Pause ======

    bool public paused;

    // ====== Spending Limits ======

    mapping(address => uint256) public maxTransactionAmount; // token => max amount (0 = no limit)

    // ====== Withdrawal Timelock ======

    uint256 public withdrawalDelay;
    uint256 public constant MAX_WITHDRAWAL_DELAY = 7 days;
    uint256 private withdrawalNonce;

    struct WithdrawalRequest {
        address token;
        address to;
        uint256 amount;
        uint256 unlockTime;
        bool executed;
        bool cancelled;
    }

    mapping(bytes32 => WithdrawalRequest) public withdrawalRequests;

    // ====== Transactions ======

    uint256 public txCounter;

    struct Transaction {
        address walletAddress;
        address tokenAddress;       // address(0) = native token (ETH, MATIC, etc.)
        string bookingId;
        uint256 exchangeRateId;
        string productVariantId;
        uint256 timestamp;
        string refId;
        uint256 amount;
    }

    struct TransactionParams {
        string bookingId;
        uint256 exchangeRateId;
        string productVariantId;
        address tokenAddress;
        string refId;
        uint256 amount;
    }

    mapping(uint256 => Transaction) public transactions;
    mapping(address => uint256[]) private userTransactions;
    mapping(string => uint256) private refToTx;

    // ====== Point Deposits ======

    uint256 public pointDepositCounter;

    struct PointDeposit {
        address walletAddress;
        address tokenAddress;
        uint256 amount;
        string refId;
        uint256 timestamp;
    }

    mapping(uint256 => PointDeposit) public pointDeposits;
    mapping(string => uint256) private pointRefToDeposit;
    mapping(address => uint256[]) private userPointDeposits;

    mapping(address => bool) public allowedPointTokens;
    address[] private allowedPointTokenList;
    bool public pointDepositsPaused;

    // ====== Events ======

    event TransactionCreated(
        uint256 indexed txId,
        address indexed walletAddress,
        address indexed tokenAddress,
        string bookingId,
        uint256 exchangeRateId,
        string productVariantId,
        uint256 timestamp,
        string refId,
        uint256 amount
    );
    event AdminAdded(address indexed admin);
    event AdminRemoved(address indexed admin);
    event Withdraw(address indexed to, address indexed token, uint256 amount);
    event NativeDeposit(address indexed from, uint256 amount);
    event ContractPausedToggled(bool paused);
    event MaxTransactionAmountUpdated(address indexed token, uint256 amount);
    event WithdrawalQueued(
        bytes32 indexed withdrawalId,
        address indexed token,
        address indexed to,
        uint256 amount,
        uint256 unlockTime
    );
    event WithdrawalExecuted(bytes32 indexed withdrawalId);
    event WithdrawalCancelled(bytes32 indexed withdrawalId);
    event WithdrawalDelayUpdated(uint256 delay);
    event TokenRecovered(address indexed token, address indexed to, uint256 amount);
    event PointDepositCreated(
        uint256 indexed depositId,
        address indexed walletAddress,
        address indexed tokenAddress,
        string refId,
        uint256 amount,
        uint256 timestamp
    );
    event PointTokenAdded(address indexed token);
    event PointTokenRemoved(address indexed token);
    event PointDepositsPausedToggled(bool paused);

    // ====== Modifiers ======

    modifier onlyOwner() {
        require(msg.sender == owner, "Not authorized: only owner");
        _;
    }

    modifier onlyAdminOrOwner() {
        require(msg.sender == owner || admins[msg.sender], "Not authorized: only owner/admin");
        _;
    }

    modifier onlyUser(address user) {
        require(msg.sender == user, "Not authorized: only user");
        _;
    }

    modifier whenNotPaused() {
        require(!paused, "Contract is paused");
        _;
    }

    modifier whenPointDepositsActive() {
        require(!pointDepositsPaused, "Point deposits are paused");
        _;
    }

    constructor() {
        owner = msg.sender;
    }

    // ====== Global Pause ======

    function setPaused(bool _paused) external onlyOwner {
        paused = _paused;
        emit ContractPausedToggled(_paused);
    }

    // ====== Spending Limits ======

    function setMaxTransactionAmount(address token, uint256 amount) external onlyOwner {
        maxTransactionAmount[token] = amount;
        emit MaxTransactionAmountUpdated(token, amount);
    }

    // ====== Create Transaction (supports ERC20 + Native) ======

    function createTransaction(
        string calldata bookingId,
        uint256 exchangeRateId,
        string calldata productVariantId,
        address tokenAddress,
        string calldata refId,
        uint256 amount
    ) external payable whenNotPaused {
        if (tokenAddress == address(0)) {
            require(msg.value == amount, "Incorrect amount sent");
        } else {
            require(msg.value == 0, "ETH not required for ERC20");
            IERC20(tokenAddress).safeTransferFrom(msg.sender, address(this), amount);
        }
        _recordTransaction(msg.sender, bookingId, exchangeRateId, productVariantId, tokenAddress, refId, amount);
    }

    // ====== Batch Transaction Creation ======

    function createTransactionBatch(TransactionParams[] calldata params) external payable whenNotPaused {
        uint256 len = params.length;
        require(len > 0, "Empty batch");
        require(len <= 20, "Batch too large");

        // Pre-compute expected native total and validate params
        uint256 totalNative = 0;
        for (uint256 i = 0; i < len; i++) {
            require(params[i].amount > 0, "Amount must be greater than 0");
            if (params[i].tokenAddress == address(0)) {
                totalNative += params[i].amount;
            }
        }
        require(msg.value == totalNative, "Incorrect ETH amount for batch");

        // Check for intra-batch duplicate refIds (O(n^2), max 20 items)
        for (uint256 i = 0; i < len; i++) {
            for (uint256 j = i + 1; j < len; j++) {
                require(
                    keccak256(bytes(params[i].refId)) != keccak256(bytes(params[j].refId)),
                    "Duplicate refId in batch"
                );
            }
            // Transfer ERC20 upfront before any state changes
            if (params[i].tokenAddress != address(0)) {
                IERC20(params[i].tokenAddress).safeTransferFrom(msg.sender, address(this), params[i].amount);
            }
        }

        // Record all transactions (ETH and ERC20 tokens are already in the contract)
        for (uint256 i = 0; i < len; i++) {
            TransactionParams calldata p = params[i];
            _recordTransaction(msg.sender, p.bookingId, p.exchangeRateId, p.productVariantId, p.tokenAddress, p.refId, p.amount);
        }
    }

    function _recordTransaction(
        address sender,
        string calldata bookingId,
        uint256 exchangeRateId,
        string calldata productVariantId,
        address tokenAddress,
        string calldata refId,
        uint256 amount
    ) internal {
        require(refToTx[refId] == 0, "refId must be unique");
        require(amount > 0, "Amount must be greater than 0");

        uint256 maxAmt = maxTransactionAmount[tokenAddress];
        if (maxAmt > 0) {
            require(amount <= maxAmt, "Amount exceeds spending limit");
        }

        txCounter += 1;
        transactions[txCounter] = Transaction({
            walletAddress: sender,
            tokenAddress: tokenAddress,
            bookingId: bookingId,
            exchangeRateId: exchangeRateId,
            productVariantId: productVariantId,
            timestamp: block.timestamp,
            refId: refId,
            amount: amount
        });

        userTransactions[sender].push(txCounter);
        refToTx[refId] = txCounter;

        emit TransactionCreated(
            txCounter,
            sender,
            tokenAddress,
            bookingId,
            exchangeRateId,
            productVariantId,
            block.timestamp,
            refId,
            amount
        );
    }

    // ====== Withdrawals (ERC20 + Native) ======

    function withdraw(address token, address to, uint256 amount) external onlyOwner {
        require(to != address(0), "Invalid recipient");
        require(amount > 0, "Amount must be greater than 0");
        _doWithdraw(token, to, amount);
    }

    function withdrawAll(address token, address to) external onlyOwner {
        require(to != address(0), "Invalid recipient");
        uint256 balance = token == address(0) ? address(this).balance : IERC20(token).balanceOf(address(this));
        require(balance > 0, "No balance");
        _doWithdraw(token, to, balance);
    }

    function _doWithdraw(address token, address to, uint256 amount) internal {
        if (token == address(0)) {
            require(address(this).balance >= amount, "Insufficient ETH balance");
            (bool ok, ) = payable(to).call{value: amount}("");
            require(ok, "ETH transfer failed");
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
        emit Withdraw(to, token, amount);
    }

    // ====== Withdrawal Timelock ======

    function setWithdrawalDelay(uint256 delay) external onlyOwner {
        require(delay <= MAX_WITHDRAWAL_DELAY, "Delay exceeds maximum");
        withdrawalDelay = delay;
        emit WithdrawalDelayUpdated(delay);
    }

    function queueWithdrawal(address token, address to, uint256 amount) external onlyOwner returns (bytes32) {
        require(to != address(0), "Invalid recipient");
        require(amount > 0, "Amount must be greater than 0");

        withdrawalNonce += 1;
        bytes32 withdrawalId = keccak256(abi.encodePacked(token, to, amount, block.timestamp, withdrawalNonce));
        uint256 unlockTime = block.timestamp + withdrawalDelay;

        withdrawalRequests[withdrawalId] = WithdrawalRequest({
            token: token,
            to: to,
            amount: amount,
            unlockTime: unlockTime,
            executed: false,
            cancelled: false
        });

        emit WithdrawalQueued(withdrawalId, token, to, amount, unlockTime);
        return withdrawalId;
    }

    function executeWithdrawal(bytes32 withdrawalId) external onlyOwner {
        WithdrawalRequest storage req = withdrawalRequests[withdrawalId];
        require(req.unlockTime > 0, "Withdrawal not found");
        require(!req.executed, "Already executed");
        require(!req.cancelled, "Already cancelled");
        require(block.timestamp >= req.unlockTime, "Timelock not expired");

        req.executed = true;
        _doWithdraw(req.token, req.to, req.amount);
        emit WithdrawalExecuted(withdrawalId);
    }

    function cancelWithdrawal(bytes32 withdrawalId) external onlyOwner {
        WithdrawalRequest storage req = withdrawalRequests[withdrawalId];
        require(req.unlockTime > 0, "Withdrawal not found");
        require(!req.executed, "Already executed");
        require(!req.cancelled, "Already cancelled");
        req.cancelled = true;
        emit WithdrawalCancelled(withdrawalId);
    }

    // ====== Token Recovery ======

    function recoverToken(address token, address to, uint256 amount) external onlyOwner {
        require(to != address(0), "Invalid recipient");
        require(amount > 0, "Amount must be greater than 0");
        if (token == address(0)) {
            require(address(this).balance >= amount, "Insufficient ETH balance");
            (bool ok, ) = payable(to).call{value: amount}("");
            require(ok, "ETH transfer failed");
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
        emit TokenRecovered(token, to, amount);
    }

    // ====== ETH Direct Deposit Handling ======

    receive() external payable {
        emit NativeDeposit(msg.sender, msg.value);
    }

    fallback() external payable {
        if (msg.value > 0) {
            emit NativeDeposit(msg.sender, msg.value);
        }
    }

    // ====== Admin Management ======

    function addAdmin(address admin) external onlyOwner {
        require(!admins[admin], "Already admin");
        admins[admin] = true;
        adminList.push(admin);
        emit AdminAdded(admin);
    }

    function removeAdmin(address admin) external onlyOwner {
        require(admins[admin], "Not an admin");
        admins[admin] = false;
        emit AdminRemoved(admin);
    }

    function getAllAdmins() external view onlyOwner returns (address[] memory) {
        return adminList;
    }

    function isAdmin(address admin) external view returns (bool) {
        return admins[admin];
    }

    // ====== Transaction View Functions ======

    function getUserTransactions(uint256 offset, uint256 limit) external view onlyUser(msg.sender) returns (Transaction[] memory) {
        return _paginateTx(userTransactions[msg.sender], offset, limit);
    }

    function getTransactionsByAddress(address user, uint256 offset, uint256 limit) external view onlyAdminOrOwner returns (Transaction[] memory) {
        return _paginateTx(userTransactions[user], offset, limit);
    }

    function _paginateTx(uint256[] storage txIds, uint256 offset, uint256 limit) internal view returns (Transaction[] memory) {
        uint256 total = txIds.length;
        if (offset >= total) return new Transaction[](0);
        uint256 size = _min(limit, total - offset);
        Transaction[] memory result = new Transaction[](size);
        for (uint256 i = 0; i < size; i++) {
            result[i] = transactions[txIds[offset + i]];
        }
        return result;
    }

    function getTransactionByRef(string calldata refId) external view onlyAdminOrOwner returns (Transaction memory) {
        uint256 txId = refToTx[refId];
        require(txId != 0, "Transaction not found");
        return transactions[txId];
    }

    function getUserTransactionCount(address user) external view onlyAdminOrOwner returns (uint256) {
        return userTransactions[user].length;
    }

    function getTransactionsInRange(uint256 start, uint256 end, uint256 offset, uint256 limit) external view onlyAdminOrOwner returns (Transaction[] memory) {
        Transaction[] memory temp = new Transaction[](txCounter);
        uint256 count = 0;

        for (uint256 i = 1; i <= txCounter; i++) {
            Transaction memory txData = transactions[i];
            if (txData.timestamp >= start && txData.timestamp <= end) {
                temp[count] = txData;
                count++;
            }
        }

        if (offset >= count) return new Transaction[](0);
        uint256 size = _min(limit, count - offset);
        Transaction[] memory result = new Transaction[](size);
        for (uint256 j = 0; j < size; j++) {
            result[j] = temp[offset + j];
        }
        return result;
    }

    // ====== Point Deposit Functions ======

    function depositPoints(
        address tokenAddress,
        string calldata refId,
        uint256 amount
    ) external whenNotPaused whenPointDepositsActive {
        require(allowedPointTokens[tokenAddress], "Token not allowed for point deposits");
        require(pointRefToDeposit[refId] == 0, "refId already used");
        require(amount > 0, "Amount must be greater than 0");

        IERC20(tokenAddress).safeTransferFrom(msg.sender, address(this), amount);

        pointDepositCounter += 1;
        pointDeposits[pointDepositCounter] = PointDeposit({
            walletAddress: msg.sender,
            tokenAddress: tokenAddress,
            amount: amount,
            refId: refId,
            timestamp: block.timestamp
        });

        userPointDeposits[msg.sender].push(pointDepositCounter);
        pointRefToDeposit[refId] = pointDepositCounter;

        emit PointDepositCreated(
            pointDepositCounter,
            msg.sender,
            tokenAddress,
            refId,
            amount,
            block.timestamp
        );
    }

    // ====== Point Deposit View Functions ======

    function getPointDepositByRef(string calldata refId) external view onlyAdminOrOwner returns (PointDeposit memory) {
        uint256 depositId = pointRefToDeposit[refId];
        require(depositId != 0, "Point deposit not found");
        return pointDeposits[depositId];
    }

    function getPointDepositsByAddress(address user, uint256 offset, uint256 limit) external view onlyAdminOrOwner returns (PointDeposit[] memory) {
        return _paginateDeposit(userPointDeposits[user], offset, limit);
    }

    function getUserPointDeposits(uint256 offset, uint256 limit) external view onlyUser(msg.sender) returns (PointDeposit[] memory) {
        return _paginateDeposit(userPointDeposits[msg.sender], offset, limit);
    }

    function getUserPointDepositCount(address user) external view onlyAdminOrOwner returns (uint256) {
        return userPointDeposits[user].length;
    }

    function _paginateDeposit(uint256[] storage ids, uint256 offset, uint256 limit) internal view returns (PointDeposit[] memory) {
        uint256 total = ids.length;
        if (offset >= total) return new PointDeposit[](0);
        uint256 size = _min(limit, total - offset);
        PointDeposit[] memory result = new PointDeposit[](size);
        for (uint256 i = 0; i < size; i++) {
            result[i] = pointDeposits[ids[offset + i]];
        }
        return result;
    }

    // ====== Point Token Whitelist Management ======

    function addAllowedPointToken(address token) external onlyOwner {
        require(token != address(0), "Invalid token address");
        require(!allowedPointTokens[token], "Token already allowed");
        allowedPointTokens[token] = true;
        allowedPointTokenList.push(token);
        emit PointTokenAdded(token);
    }

    function removeAllowedPointToken(address token) external onlyOwner {
        require(allowedPointTokens[token], "Token not in whitelist");
        allowedPointTokens[token] = false;
        emit PointTokenRemoved(token);
    }

    function getAllowedPointTokens() external view returns (address[] memory) {
        return allowedPointTokenList;
    }

    function isAllowedPointToken(address token) external view returns (bool) {
        return allowedPointTokens[token];
    }

    // ====== Point Deposit Pause Control ======

    function setPointDepositsPaused(bool _paused) external onlyOwner {
        pointDepositsPaused = _paused;
        emit PointDepositsPausedToggled(_paused);
    }

    // ====== Helpers ======

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}
