// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract TakumiWallet {
    using SafeERC20 for IERC20;

    uint256 public txCounter;
    address public owner;

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

    // ====== Point Deposits ======

    struct PointDeposit {
        address walletAddress;
        address tokenAddress;
        uint256 amount;
        string  refId;
        uint256 timestamp;
    }

    uint256 public pointDepositCounter;
    mapping(uint256 => PointDeposit) public pointDeposits;
    mapping(string => uint256) private pointRefToDeposit;
    mapping(address => uint256[]) private userPointDeposits;

    mapping(address => bool) public allowedPointTokens;
    address[] private allowedPointTokenList;

    bool public pointDepositsPaused;

    // ====== End Point Deposits ======

    mapping(uint256 => Transaction) public transactions;
    mapping(address => uint256[]) private userTransactions;
    mapping(string => uint256) private refToTx;

    mapping(address => bool) private admins;
    address[] private adminList;

    event TransactionCreated(
        uint256 indexed txId,
        address indexed walletAddress,
        address indexed tokenAddress, // address(0) = native token
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

    event PointDepositCreated(
        uint256 indexed depositId,
        address indexed walletAddress,
        address indexed tokenAddress,
        string  refId,
        uint256 amount,
        uint256 timestamp
    );

    event PointTokenAdded(address indexed token);
    event PointTokenRemoved(address indexed token);
    event PointDepositsPausedToggled(bool paused);

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

    modifier whenPointDepositsActive() {
        require(!pointDepositsPaused, "Point deposits are paused");
        _;
    }

    constructor() {
        owner = msg.sender;
    }

    // ====== Create Transaction (supports ERC20 + Native) ======

    function createTransaction(
        string calldata bookingId,
        uint256 exchangeRateId,
        string calldata productVariantId,
        address tokenAddress,
        string calldata refId,
        uint256 amount
    ) external payable {
        require(refToTx[refId] == 0, "refId must be unique");
        require(amount > 0, "Amount must be greater than 0");

        if (tokenAddress == address(0)) {
            // Native token (ETH, MATIC, etc.)
            require(msg.value == amount, "Incorrect amount sent");
        } else {
            // ERC20 token
            require(msg.value == 0, "ETH not required for ERC20");
            IERC20(tokenAddress).safeTransferFrom(msg.sender, address(this), amount);
        }

        txCounter += 1;

        transactions[txCounter] = Transaction({
            walletAddress: msg.sender,
            tokenAddress: tokenAddress,
            bookingId: bookingId,
            exchangeRateId: exchangeRateId,
            productVariantId: productVariantId,
            timestamp: block.timestamp,
            refId: refId,
            amount: amount
        });

        userTransactions[msg.sender].push(txCounter);
        refToTx[refId] = txCounter;

        emit TransactionCreated(
            txCounter,
            msg.sender,
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

        if (token == address(0)) {
            // Withdraw native token
            require(address(this).balance >= amount, "Insufficient ETH balance");
            (bool success, ) = payable(to).call{value: amount}("");
            require(success, "ETH transfer failed");
        } else {
            // Withdraw ERC20
            IERC20(token).safeTransfer(to, amount);
        }

        emit Withdraw(to, token, amount);
    }

    function withdrawAll(address token, address to) external onlyOwner {
        require(to != address(0), "Invalid recipient");

        uint256 balance;
        if (token == address(0)) {
            balance = address(this).balance;
            require(balance > 0, "No ETH balance");
            (bool success, ) = payable(to).call{value: balance}("");
            require(success, "ETH transfer failed");
        } else {
            balance = IERC20(token).balanceOf(address(this));
            require(balance > 0, "No token balance");
            IERC20(token).safeTransfer(to, balance);
        }

        emit Withdraw(to, token, balance);
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

    // ===== Admin Management =====

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

    // ===== View Functions =====

    function getUserTransactions(uint256 offset, uint256 limit) external view onlyUser(msg.sender) returns (Transaction[] memory) {
        uint256[] memory txIds = userTransactions[msg.sender];
        uint256 total = txIds.length;

        if (offset >= total) {
            return new Transaction[](0) ;
        }

        uint256 available = total - offset;
        uint256 size = limit < available ? limit : available;

        Transaction[] memory result = new Transaction[](size);
        for (uint256 i = 0; i < size; i++) {
            result[i] = transactions[txIds[offset + i]];
        }
        return result;
    }

    function getTransactionsByAddress(address user, uint256 offset, uint256 limit) external view onlyAdminOrOwner returns (Transaction[] memory) {
        uint256[] memory txIds = userTransactions[user];
        uint256 total = txIds.length;

        if (offset >= total) {
            return new Transaction[](0) ;
        }

        uint256 available = total - offset;
        uint256 size = limit < available ? limit : available;

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

        if (offset >= count) {
            return new Transaction[](0) ;
        }

        uint256 available = count - offset;
        uint256 size = limit < available ? limit : available;

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
    ) external whenPointDepositsActive {
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

    function getPointDepositByRef(
        string calldata refId
    ) external view onlyAdminOrOwner returns (PointDeposit memory) {
        uint256 depositId = pointRefToDeposit[refId];
        require(depositId != 0, "Point deposit not found");
        return pointDeposits[depositId];
    }

    function getPointDepositsByAddress(
        address user,
        uint256 offset,
        uint256 limit
    ) external view onlyAdminOrOwner returns (PointDeposit[] memory) {
        uint256[] memory depositIds = userPointDeposits[user];
        uint256 total = depositIds.length;

        if (offset >= total) {
            return new PointDeposit[](0);
        }

        uint256 available = total - offset;
        uint256 size = limit < available ? limit : available;

        PointDeposit[] memory result = new PointDeposit[](size);
        for (uint256 i = 0; i < size; i++) {
            result[i] = pointDeposits[depositIds[offset + i]];
        }
        return result;
    }

    function getUserPointDeposits(
        uint256 offset,
        uint256 limit
    ) external view onlyUser(msg.sender) returns (PointDeposit[] memory) {
        uint256[] memory depositIds = userPointDeposits[msg.sender];
        uint256 total = depositIds.length;

        if (offset >= total) {
            return new PointDeposit[](0);
        }

        uint256 available = total - offset;
        uint256 size = limit < available ? limit : available;

        PointDeposit[] memory result = new PointDeposit[](size);
        for (uint256 i = 0; i < size; i++) {
            result[i] = pointDeposits[depositIds[offset + i]];
        }
        return result;
    }

    function getUserPointDepositCount(
        address user
    ) external view onlyAdminOrOwner returns (uint256) {
        return userPointDeposits[user].length;
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

    function setPointDepositsPaused(bool paused) external onlyOwner {
        pointDepositsPaused = paused;
        emit PointDepositsPausedToggled(paused);
    }
}