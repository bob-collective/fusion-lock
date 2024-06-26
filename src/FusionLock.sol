// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";

interface BridgeInterface {
    /**
     * @dev reference: https://github.com/ethereum-optimism/optimism/blob/65ec61dde94ffa93342728d324fecf474d228e1f/packages/contracts-bedrock/contracts/L1/L1StandardBridge.sol#L188
     */
    function depositERC20To(
        address _l1Token,
        address _l2Token,
        address _to,
        uint256 _amount,
        uint32 _minGasLimit,
        bytes calldata _extraData
    ) external;

    /**
     * @dev reference: https://github.com/ethereum-optimism/optimism/blob/65ec61dde94ffa93342728d324fecf474d228e1f/packages/contracts-bedrock/contracts/L1/L1StandardBridge.sol#L137
     */
    function depositETHTo(address _to, uint32 _minGasLimit, bytes calldata _extraData) external payable;
}

/**
 * @title FusionLock Contract
 * @dev This contract allows users to deposit ERC20 tokens or Ether within a specified time time.
 * It provides functionalities for bridging tokens between Layer 1 (L1) and Layer 2 (L2) networks.
 * Users can also withdraw their deposited tokens after the max lock time ends.
 */
contract FusionLock is Ownable, Pausable {
    using SafeERC20 for IERC20;
    using Address for address payable;

    // Events
    event TokenAllowed(address token, TokenInfo info);
    event TokenDataChange(address l1Token, address l2Token, address l1Bridge);
    event BridgeAddress(address bridgeAddress);
    event WithdrawalTimeUpdated(uint256 endTime);
    event Deposit(address indexed depositOwner, address indexed token, uint256 amount, uint256 depositTime);
    event WithdrawToL1(address indexed owner, address indexed token, uint256 amount);
    event WithdrawToL2(
        address indexed owner, address indexed receiver, address indexed l1Token, address l2Token, uint256 amount
    );
    event SavedToken(address indexed user, address indexed token, uint256 amount);

    // Struct to hold token information.
    struct TokenInfo {
        bool isAllowed; // Flag indicating whether the token is allowed for deposit.
        address l2TokenAddress; // Address of the corresponding token on Layer 2.
        address l1BridgeAddressOverride; // Optional address to use for bridging to L2.
    }

    // Struct to hold L1 and L2 token addresses.
    struct TokenBridgingData {
        address l1TokenAddress;
        address l2TokenAddress;
        address l1BridgeAddressOverride;
    }

    // Struct to hold token information.
    struct SaveTokenData {
        address user; // user to send the funds to
        address token; // token to send
        uint256 amount; // amount to send
    }

    // State variables
    mapping(address => TokenInfo) public allowedTokens; // Mapping to track allowed ERC20 tokens and their corresponding L2 addresses.
    mapping(address => mapping(address => uint256)) public deposits; // Mapping to store deposit data: user address => token address => deposit amount.
    mapping(address => uint256) public totalDeposits; // Mapping to track total deposit amount per token address. Used for refunds in case of bridging failure.
    uint256 public withdrawalStartTime; // Start time for withdrawal
    address public bridgeProxyAddress; // Address of the bridge contract for L1-L2 token transfers

    // Constant representing the Ethereum token address.
    address public constant ETH_TOKEN_ADDRESS = address(0x00);

    /**
     * @dev Constructor
     * @param setWithdrawalStartTime Withdrawal start time
     * @param allowTokens Array of addresses representing ERC20 tokens to be allowed for deposit
     * @param initialOwner Address of the initial owner of the contract.
     */
    constructor(uint256 setWithdrawalStartTime, address[] memory allowTokens, address initialOwner)
        Ownable(initialOwner)
    {
        require(setWithdrawalStartTime > block.timestamp, "Withdrawal start time can't be historical");
        withdrawalStartTime = setWithdrawalStartTime;

        for (uint256 tokenId = 0; tokenId < allowTokens.length; tokenId++) {
            _allow(allowTokens[tokenId], address(0x00), address(0x00));
        }
        // allow eth by default
        _allow(ETH_TOKEN_ADDRESS, address(0x00), address(0x00));
    }

    /**
     * @dev Modifier to check if deposit is allowed.
     * @param amount Amount of tokens being deposited.
     */
    modifier isDepositAllowed(uint256 amount) {
        require(!isWithdrawalTimeStarted(), "Deposit time already ended");
        require(amount > 0, "Amount Should Be Greater Than Zero");
        _;
    }

    /**
     * @dev Deposit ERC20 tokens.
     * @param token Address of the ERC20 token.
     * @param amount Amount of tokens to deposit.
     */
    function depositERC20(address token, uint256 amount) external isDepositAllowed(amount) whenNotPaused {
        require(allowedTokens[token].isAllowed, "Deposit token not allowed");

        deposits[msg.sender][token] += amount;
        totalDeposits[token] += amount;
        // Transfer tokens to contract
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        // Emit Deposit event
        emit Deposit(msg.sender, token, amount, block.timestamp);
    }

    /**
     * @dev Deposit Ether
     * Allows users to deposit Ether into the contract.
     */
    function depositEth() external payable isDepositAllowed(msg.value) whenNotPaused {
        // Increase the deposited Ether amount for the sender.
        deposits[msg.sender][ETH_TOKEN_ADDRESS] += msg.value;
        totalDeposits[ETH_TOKEN_ADDRESS] += msg.value;
        // Emit Deposit Event
        emit Deposit(msg.sender, ETH_TOKEN_ADDRESS, msg.value, block.timestamp);
    }

    /**
     * @dev Function to withdraw ERC20 tokens or Ether for a given deposit.
     * @param token Address of the token to withdraw.
     */
    function withdrawSingleDepositToL1(address token) internal {
        uint256 transferAmount = deposits[msg.sender][token];

        require(transferAmount != 0, "Withdrawal completed or token never deposited");

        deposits[msg.sender][token] = 0;
        totalDeposits[token] -= transferAmount;

        if (token == ETH_TOKEN_ADDRESS) {
            // Note: we use openzeppelin's `sendValue` rather than `transfer` because
            // `transfer` forwards a fixed amount of gas (2300), which may not be enough
            // if msg.sender is a smart contract. We should be OK against reentrancy
            // attacks since we follow the checks-effects-interactions pattern
            payable(msg.sender).sendValue(transferAmount);
        } else {
            // Transfer ERC20 tokens to the sender.
            IERC20(token).safeTransfer(msg.sender, transferAmount);
        }
        emit WithdrawToL1(msg.sender, token, transferAmount);
    }

    /**
     * @dev Internal function to withdraw tokens to Layer 2.
     * @param token Address of the token to withdraw.
     * @param minGasLimit Minimum gas limit for each individual withdrawal transaction.
     * @param receiver The receiver of the funds on L2.
     */
    function withdrawSingleDepositToL2(address token, uint32 minGasLimit, address receiver) internal {
        uint256 transferAmount = deposits[msg.sender][token];

        require(transferAmount != 0, "Withdrawal completed or token never deposited");

        // Retrieve token information.
        TokenInfo memory tokenInfo = allowedTokens[token];

        // check l2 token address set.
        require(token == ETH_TOKEN_ADDRESS || tokenInfo.l2TokenAddress != address(0x00), "L2 token address not set");

        address bridgeAddress = bridgeProxyAddress;
        if (tokenInfo.l1BridgeAddressOverride != address(0x00)) {
            bridgeAddress = tokenInfo.l1BridgeAddressOverride;
        }

        deposits[msg.sender][token] = 0;
        totalDeposits[token] -= transferAmount;

        if (token == ETH_TOKEN_ADDRESS) {
            // Bridge Ether to Layer 2.
            BridgeInterface(bridgeAddress).depositETHTo{value: transferAmount}(receiver, minGasLimit, hex"");
        } else {
            // Approve tokens for transfer to the bridge.
            IERC20(token).approve(bridgeAddress, transferAmount);
            // Bridge ERC20 tokens to Layer 2.
            BridgeInterface(bridgeAddress).depositERC20To(
                token, tokenInfo.l2TokenAddress, receiver, transferAmount, minGasLimit, hex""
            );
        }
        emit WithdrawToL2(msg.sender, receiver, token, tokenInfo.l2TokenAddress, transferAmount);
    }

    /**
     * @dev Function to withdraw all deposits to Layer 2 for multiple tokens.
     * @param tokens Array of token addresses to withdraw.
     * @param minGasLimit Minimum gas limit for the withdrawal transactions.
     * @param receiver The receiver of the funds on L2.
     */
    function withdrawDepositsToL2(address[] memory tokens, uint32 minGasLimit, address receiver)
        external
        whenNotPaused
    {
        require(isWithdrawalTimeStarted(), "Withdrawal not started");
        // check if bridge address set
        require(bridgeProxyAddress != address(0x00), "Bridge address not set");

        // Loop through each token and withdraw to Layer 2.
        for (uint256 i = 0; i < tokens.length; i++) {
            withdrawSingleDepositToL2(tokens[i], minGasLimit, receiver);
        }
    }

    /**
     * @dev Function to withdraw all deposits to Layer 1 for multiple tokens.
     * @param tokens Array of token addresses to withdraw.
     */
    function withdrawDepositsToL1(address[] memory tokens) external {
        require(isWithdrawalTimeStarted(), "Withdrawal not started");
        // Loop through each token and withdraw to Layer 1.
        for (uint256 i = 0; i < tokens.length; i++) {
            withdrawSingleDepositToL1(tokens[i]);
        }
    }

    /**
     * @dev Function to allow ERC20 tokens for deposit.
     * This function allows the contract owner to allow specific ERC20 tokens for deposit.
     * @param l1TokenAddress Address of the ERC20 token to allow on Layer 1.
     * @param l2TokenAddress Address of the corresponding token on Layer 2.
     * @param l1BridgeAddressOverride Address of the corresponding bridge to use for this token.
     *                                Can be 0 to use the default. This should be used for tokens
     *                                that cannot use the L1StandardBridge contract. Note that the
     *                                override is expected to implement the same BridgeInterface.
     */
    function allow(address l1TokenAddress, address l2TokenAddress, address l1BridgeAddressOverride)
        external
        onlyOwner
    {
        require(!isWithdrawalTimeStarted(), "Withdrawal has started, token allowance cannot be modified");
        _allow(l1TokenAddress, l2TokenAddress, l1BridgeAddressOverride);
    }

    /**
     * @dev Internal function to allow ERC20 tokens for deposit.
     * This function updates the allowedTokens mapping with the provided token information.
     * @param l1TokenAddress Address of the ERC20 token to allow.
     * @param l2TokenAddress Address of the corresponding token on Layer 2.
     * @param l1BridgeAddressOverride Address of the corresponding bridge to use for this token.
     *                                Can be 0 to use the default.
     */
    function _allow(address l1TokenAddress, address l2TokenAddress, address l1BridgeAddressOverride) internal {
        TokenInfo memory tokenInfo = TokenInfo(true, l2TokenAddress, l1BridgeAddressOverride);
        allowedTokens[l1TokenAddress] = tokenInfo;
        emit TokenAllowed(l1TokenAddress, tokenInfo);
    }

    /**
     * @dev Function to change L2 address and the bridge address of tokens that were allowed for deposit.
     * This function allows the contract owner to change the L2 address and the L1 bridge address for tokens
     * that were previously allowed for deposit.
     * @param tokenData An array of structs, each containing the Layer 1 (L1) token address, its (L1) bridge
     *                     address, and its Layer 2 (L2) token address.
     */
    function changeMultipleL2TokenData(TokenBridgingData[] memory tokenData) external onlyOwner {
        for (uint256 i = 0; i < tokenData.length; i++) {
            TokenBridgingData memory token = tokenData[i];
            // Ensure the token is allowed for deposit before changing its L2 address
            require(allowedTokens[token.l1TokenAddress].isAllowed, "Need to allow token before changing token data");

            // Update the L2 address of the token
            allowedTokens[token.l1TokenAddress].l2TokenAddress = token.l2TokenAddress;
            allowedTokens[token.l1TokenAddress].l1BridgeAddressOverride = token.l1BridgeAddressOverride;

            emit TokenDataChange(token.l1TokenAddress, token.l2TokenAddress, token.l1BridgeAddressOverride);
        }
    }

    /**
     * @dev Function to change the withdrawal time.
     * This function allows the contract owner to change the withdrawal time.
     * @param newWithdrawalStartTime New withdrawal start time.
     */
    function changeWithdrawalTime(uint256 newWithdrawalStartTime) external onlyOwner {
        require(block.timestamp < newWithdrawalStartTime, "New timestamp can't be historical");
        require(
            withdrawalStartTime > newWithdrawalStartTime, "Withdrawal start time can only be decreased, not increased"
        );

        withdrawalStartTime = newWithdrawalStartTime;
        emit WithdrawalTimeUpdated(newWithdrawalStartTime);
    }

    /**
     * @dev Function to set the address of the bridge proxy.
     * This function allows the contract owner to set the address of the bridge proxy for token transfers between Layer 1 and Layer 2.
     * @param l2BridgeProxyAddress Address of the bridge proxy contract.
     */
    function setBridgeProxyAddress(address l2BridgeProxyAddress) external onlyOwner {
        bridgeProxyAddress = l2BridgeProxyAddress;
        emit BridgeAddress(l2BridgeProxyAddress);
    }

    /**
     * @dev This function allows the contract owner to recover ERC20 tokens that would
     * otherwise stay locked in the contract forever.
     * @param tokenData An array of structs containing information about the tokens to be saved.
     */
    function saveTokens(SaveTokenData[] calldata tokenData) external onlyOwner {
        for (uint256 i = 0; i < tokenData.length; i++) {
            saveToken(tokenData[i].user, tokenData[i].token, tokenData[i].amount);
        }
    }

    /**
     * @dev Internal function to recover an ERC20 token that would otherwise stay locked in
     * the contract forever. This function transfers the specified amount of ERC20 token
     * from the contract's balance to the specified user's address.
     * @param user Address of the user to send the tokens to.
     * @param token Address of the ERC20 token to be saved.
     * @param amount Amount of tokens to be saved.
     */
    function saveToken(address user, address token, uint256 amount) internal {
        require(
            token != ETH_TOKEN_ADDRESS,
            "Only ERC20 tokens can be recovered, since eth bridging is supposed to be infallible"
        );

        uint256 tokenBalance = IERC20(token).balanceOf(address(this));

        require(tokenBalance >= totalDeposits[token] + amount, "Insufficient balance to save token");

        IERC20(token).safeTransfer(user, amount);

        emit SavedToken(user, token, amount);
    }

    /**
     * @dev Function to pause contract. This calls the Pausable contract.
     */
    function pause() external onlyOwner {
        super._pause();
    }

    /**
     * @dev Function to unpause contract. This calls the Pausable contract.
     */
    function unpause() external onlyOwner {
        super._unpause();
    }

    /**
     * @dev Function to check if the withdrawal time has started.
     * @return bool true if the withdrawal time has started, false otherwise.
     */
    function isWithdrawalTimeStarted() public view returns (bool) {
        // Check if the withdrawal time has started.
        return block.timestamp >= withdrawalStartTime;
    }

    /**
     * @dev Get the Ether balance of the contract
     * @return uint256 Ether balance of the contract
     */
    function getEthBalance() public view returns (uint256) {
        return address(this).balance;
    }

    /**
     * @dev Function to retrieve information about a token's allowance for deposit.
     * @param token Address of the token to retrieve information for.
     */
    function getTokenInfo(address token) public view returns (TokenInfo memory) {
        return allowedTokens[token];
    }

    /**
     * @dev Get the deposited amount of a token for a given user
     * @param depositOwner Address of the user
     * @param token Address of the token
     * @return uint256 Amount of tokens deposited
     */
    function getDepositAmount(address depositOwner, address token) public view returns (uint256) {
        return deposits[depositOwner][token];
    }

    fallback() external payable {
        revert("fallback not allowed");
    }

    receive() external payable {
        revert("receive not allowed");
    }
}
