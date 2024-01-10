// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IRouterClient} from "@chainlink/contracts-ccip/src/v0.8/ccip/interfaces/IRouterClient.sol";
import {OwnerIsCreator} from "@chainlink/contracts-ccip/src/v0.8/shared/access/OwnerIsCreator.sol";
import {Client} from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/Client.sol";
import {CCIPReceiver} from "@chainlink/contracts-ccip/src/v0.8/ccip/applications/CCIPReceiver.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

import "./utils/Counters.sol";
import "./simpleSwap.sol";

/// @title - Portfolio Manager contract that uses CCIP to create a Token Index Portfolio by accessing liquidity cross chain
contract PriceOracleReceiver is OwnerIsCreator, CCIPReceiver {
    using Counters for Counters.Counter;
    // Custom errors to provide more descriptive revert messages.
    error NotEnoughBalance(uint256 currentBalance, uint256 calculatedFees); // Used to make sure contract has enough balance.
    error NothingToWithdraw(); // Used when trying to withdraw Ether but there's nothing to withdraw.
    error FailedToWithdrawEth(address owner, address target, uint256 value); // Used when the withdrawal of Ether fails.
    error DestinationChainNotAllowlisted(uint64 destinationChainSelector); // Used when the destination chain has not been allowlisted by the contract owner.
    error SourceChainNotAllowlisted(uint64 sourceChainSelector); // Used when the source chain has not been allowlisted by the contract owner.
    error SenderNotAllowlisted(address sender); // Used when the sender has not been allowlisted by the contract owner.

    // Event emitted when a message is sent to another chain.
    event MessageSent(
        bytes32 indexed messageId, // The unique ID of the CCIP message.
        uint64 indexed destinationChainSelector, // The chain selector of the destination chain.
        address receiver, // The address of the receiver on the destination chain.
        address payload, // The payload being sent.
        address feeToken, // the token address used to pay CCIP fees.
        uint256 fees // The fees paid for sending the CCIP message.
    );

     // Event emitted when a message is sent to another chain with tokens
    event MessageSent(
        bytes32 indexed messageId, // The unique ID of the CCIP message.
        uint64 indexed destinationChainSelector, // The chain selector of the destination chain.
        address receiver, // The address of the receiver on the destination chain.
        bytes payload, // The text being sent.
        address token, // The token address that was transferred.
        uint256 tokenAmount, // The token amount that was transferred.
        address feeToken, // the token address used to pay CCIP fees.
        uint256 fees // The fees paid for sending the message.
    );

    event PriceReceived(
        uint256 latestPrice
    );

    event PriceSet(
        address token,
        uint256 latestPrice
    );

    // Event emitted when a message is received from another chain.
    event MessageReceived(
        bytes32 indexed messageId, // The unique ID of the CCIP message.
        uint64 indexed sourceChainSelector, // The chain selector of the source chain.
        address sender, // The address of the sender from the source chain.
        address payloadToken, // The payload address that was received.
        uint256 payloadPrice // The payload price that was received.
    );

    struct RemoteOracle { // optimise to mappings instead 
        uint64 destinationChainSelector;
        address destinationPriceOracleAddress;
        address destinationSwapperAddress;
    }

    struct TokenPosition {
        address tokenPriceFeed;
        address mockTokenAddress;
        uint256 amount; // 18 decimals
        uint256 weight; // 10k basis
    }

    event TokensSwapped (
        uint256 stableCoinTokenAmount,
        uint256 targetAmount
    );

    Counters.Counter public portfolioId;
    uint256 private constant BASIS_POINTS = 100 * 100;
    uint256 private constant PORTFOLIO_SIZE = 1e20;
    uint256 public totalMarketCap;
    bytes32 private s_lastReceivedMessageId; // Store the last received messageId.
    address private s_lastReceivedPayload_token; // Store the last received payload.
    uint256 private s_lastReceivedPayload_price; // Store the last received payload.
    address private s_lastReceivedTokenAddress; // Store the last received token address.
    uint256 private s_lastReceivedTokenAmount; // Store the last received amount.
    address private s_lastReceivedTargetTokenAddress; // Store the last received text.
    uint256 private s_lastReceivedTargetTokenAmount; // Store the last received text.

    address public swapper; 
    address public stableCoin = 0xFd57b4ddBf88a4e07fF4e34C487b99af2Fe82a05;
    address public priceOralceCCIPReceiver = 0x19570576a8F28108D9C0d4e90aF60c698Abb94B9;
    address public swapperCCIPReceiver = 0xfdb536A22Ea46FcD7DCE0E1b4A5fbD4a8a9a3258;

    address[] public priceFeedAddresses = [
        // 0x1b44F3514812d835EB1BDB0acB33d3fA3351Ee43, //BTC 
        0x694AA1769357215DE4FAC081bf1f309aDC325306, //ETH 0x0Bb05501197aAe963090A9ad37dCaafD661143Ba
        0xc59E3633BAAC79493d908e63626716e204A45EdF  //LINK
    ];

    // Mapping of portfolio id to portfolios owners 
    mapping(uint256 portfolioId => address owner) public portfoliosOwners;

    // Mapping of portfolio id to token portfolio positions
    mapping(uint256 id => TokenPosition[]) public portfolios;

    // Mapping of price feed addresses to mockToken addresses
    mapping(address priceFeed => address mockToken) public dataFeedToTargetToken;

    // Mapping to store token weights
    mapping(address token => uint256) public latestTokenWeights;

    // Mapping to store information on remote price oracles    
    mapping(address token => RemoteOracle) public RemoteOracles;

    // Mapping to store latest circulating marketcap
    mapping(address => uint256) public tokensCirculatingMarketCap;

    // Mapping to store latest token prices
    mapping(address => uint256) public latestTokenPrices;

    // Mapping to keep track of allowlisted destination chains.
    mapping(uint64 => bool) public allowlistedDestinationChains;

    // Mapping to keep track of allowlisted source chains.
    mapping(uint64 => bool) public allowlistedSourceChains;

    // Mapping to keep track of allowlisted senders.
    mapping(address => bool) public allowlistedSenders;

    /// @notice Constructor initializes the contract with the router address.
    /// @param _router The address of the router contract.
    constructor(address _router) CCIPReceiver(_router) {
    }

    /// @dev Modifier that checks if the chain with the given destinationChainSelector is allowlisted.
    /// @param _destinationChainSelector The selector of the destination chain.
    modifier onlyAllowlistedDestinationChain(uint64 _destinationChainSelector) {
        if (!allowlistedDestinationChains[_destinationChainSelector])
            revert DestinationChainNotAllowlisted(_destinationChainSelector);
        _;
    }

    /// @dev Modifier that checks if the chain with the given sourceChainSelector is allowlisted and if the sender is allowlisted.
    /// @param _sourceChainSelector The selector of the destination chain.
    /// @param _sender The address of the sender.
    modifier onlyAllowlisted(uint64 _sourceChainSelector, address _sender) {
        if (!allowlistedSourceChains[_sourceChainSelector])
            revert SourceChainNotAllowlisted(_sourceChainSelector);
        if (!allowlistedSenders[_sender]) revert SenderNotAllowlisted(_sender);
        _;
    }

    /// @dev Updates the allowlist status of a destination chain for transactions.
    function allowlistDestinationChain(
        uint64 _destinationChainSelector,
        bool allowed
    ) external onlyOwner {
        allowlistedDestinationChains[_destinationChainSelector] = allowed;
    }

    /// @dev Updates the allowlist status of a source chain for transactions.
    function allowlistSourceChain(
        uint64 _sourceChainSelector,
        bool allowed
    ) external onlyOwner {
        allowlistedSourceChains[_sourceChainSelector] = allowed;
    }

    /// @dev Updates the allowlist status of a sender for transactions.
    function allowlistSender(address _sender, bool allowed) external onlyOwner {
        allowlistedSenders[_sender] = allowed;
    }

    /// @dev Testing purposes only
    function setLatestPrice(address token, uint256 price) public {
        latestTokenPrices[token] = price;
    }

    function toUint256(bytes memory _bytes)   
    internal
    pure
    returns (uint256 value) {

        assembly {
        value := mload(add(_bytes, 0x20))
        }
    }

    /// @notice Sends data to receiver on the destination chain.
    /// @notice Pay for fees in native gas.
    /// @dev Assumes your contract has sufficient native gas tokens.
    /// @param _destinationChainSelector The identifier (aka selector) for the destination blockchain.
    /// @param _receiver The address of the recipient on the destination blockchain.
    /// @param _dataFeed The address of token of interest to fetch the price.
    function sendMessagePayNative(
        uint64 _destinationChainSelector,
        address _receiver,
        address _dataFeed
    )
        public
        onlyAllowlistedDestinationChain(_destinationChainSelector)
        returns (bytes32 messageId)
    {

        // Create an EVM2AnyMessage struct in memory with necessary information for sending a cross-chain message
        Client.EVM2AnyMessage memory evm2AnyMessage = _buildCCIPMessage(
            _receiver,
            _dataFeed,
            address(0)
        );

        // Initialize a router client instance to interact with cross-chain router
        IRouterClient router = IRouterClient(i_router);

        // Get the fee required to send the CCIP message
        uint256 fees = router.getFee(_destinationChainSelector, evm2AnyMessage) * 3;

        if (fees > address(this).balance)
            revert NotEnoughBalance(address(this).balance, fees);

        // Send the CCIP message through the router and store the returned CCIP message ID
        messageId = router.ccipSend{value: fees}(
            _destinationChainSelector,
            evm2AnyMessage
        );

        // Emit an event with message details
        emit MessageSent(
            messageId,
            _destinationChainSelector,
            _receiver,
            _dataFeed,
            address(0),
            fees
        );

        // Return the CCIP message ID
        return messageId;
    }

    /// handle a received message
    function _ccipReceive(
        Client.Any2EVMMessage memory any2EvmMessage
    )
        internal
        override
        onlyAllowlisted(
            any2EvmMessage.sourceChainSelector,
            abi.decode(any2EvmMessage.sender, (address))
        ) // Make sure source chain and sender are allowlisted
    {
        s_lastReceivedMessageId = any2EvmMessage.messageId; // fetch the messageId
        if (abi.decode(any2EvmMessage.sender, (address)) == priceOralceCCIPReceiver) {
            (s_lastReceivedPayload_token, s_lastReceivedPayload_price) = abi.decode(any2EvmMessage.data, (address, uint256)); // abi-decoding of the sent payload

            emit MessageReceived(
                any2EvmMessage.messageId,
                any2EvmMessage.sourceChainSelector, // fetch the source chain identifier (aka selector)
                abi.decode(any2EvmMessage.sender, (address)), // abi-decoding of the sender address,
                s_lastReceivedPayload_token,
                s_lastReceivedPayload_price
            );

            latestTokenPrices[s_lastReceivedPayload_token] = s_lastReceivedPayload_price;

            emit PriceSet(
                s_lastReceivedPayload_token,
                s_lastReceivedPayload_price
            );
        } else {
            (s_lastReceivedTargetTokenAddress, s_lastReceivedTargetTokenAmount) = abi.decode(any2EvmMessage.data, (address, uint256)); // abi-decoding of the sent text
            // Expect one token to be transferred at once, but you can transfer several tokens.
            s_lastReceivedTokenAddress = any2EvmMessage.destTokenAmounts[0].token;
            s_lastReceivedTokenAmount = any2EvmMessage.destTokenAmounts[0].amount;
            
            emit MessageReceived(
                any2EvmMessage.messageId,
                any2EvmMessage.sourceChainSelector, // fetch the source chain identifier (aka selector)
                abi.decode(any2EvmMessage.sender, (address)), // abi-decoding of the sender address,
                any2EvmMessage.destTokenAmounts[0].token,
                any2EvmMessage.destTokenAmounts[0].amount // !! optimize
            );
            
            if (any2EvmMessage.destTokenAmounts[0].amount > 0) {
                address recipient = portfoliosOwners[portfolioId.current()]; // This has to be sent along with other data 
                IERC20(any2EvmMessage.destTokenAmounts[0].token).transfer(recipient, any2EvmMessage.destTokenAmounts[0].amount);
            }
        }
    }

    /// @notice Construct a CCIP message.
    /// @dev This function will create an EVM2AnyMessage struct with all the necessary information for sending a payload.
    /// @param _receiver The address of the receiver.
    /// @param _payload The bytes data to be sent.
    /// @param _feeTokenAddress The address of the token used for fees. Set address(0) for native gas.
    /// @return Client.EVM2AnyMessage Returns an EVM2AnyMessage struct which contains information for sending a CCIP message.
    function _buildCCIPMessage(
        address _receiver,
        address _payload,
        address _feeTokenAddress
    ) internal pure returns (Client.EVM2AnyMessage memory) {
        // Create an EVM2AnyMessage struct in memory with necessary information for sending a cross-chain message
        return
            Client.EVM2AnyMessage({
                receiver: abi.encode(_receiver), // ABI-encoded receiver address
                data: abi.encode(_payload), // ABI-encoded bytes
                tokenAmounts: new Client.EVMTokenAmount[](0), // Empty array aas no tokens are transferred
                extraArgs: Client._argsToBytes(
                    // Additional arguments, setting gas limit and non-strict sequencing mode
                    Client.EVMExtraArgsV1({gasLimit: 600_000})
                ),
                // Set the feeToken to a feeTokenAddress, indicating specific asset will be used for fees
                feeToken: _feeTokenAddress
            });
    }

    /// @notice Sends data and transfer tokens to receiver on the destination chain.
    /// @notice Pay for fees in native gas.
    /// @dev Assumes your contract has sufficient native gas like ETH on Ethereum or MATIC on Polygon.
    /// @param _destinationChainSelector The identifier (aka selector) for the destination blockchain.
    /// @param _receiver The address of the recipient on the destination blockchain.
    /// @param _priceFeedAddress The string data to be sent.
    /// @param _targetTokenAmount The string data to be sent.
    /// @param _buy The string data to be sent.
    /// @param _token token address.
    /// @param _amount token amount.
    /// @return messageId The ID of the CCIP message that was sent.
    function sendMessagePayNative(
        uint64 _destinationChainSelector,
        address _receiver,
        address _priceFeedAddress,
        uint256 _targetTokenAmount,
        bool _buy, // true to buy tokens, false to sell
        address _token,
        uint256 _amount
    )
        public
        onlyAllowlistedDestinationChain(_destinationChainSelector)
        returns (bytes32 messageId)
    {
        bytes memory payload = abi.encode(_priceFeedAddress, _targetTokenAmount, _buy);
        // Create an EVM2AnyMessage struct in memory with necessary information for sending a cross-chain message
        // address(0) means fees are paid in native gas
        Client.EVM2AnyMessage memory evm2AnyMessage = _buildCCIPMessage(
            _receiver,
            payload,
            _token,
            _amount,
            address(0)
        );

        // Initialize a router client instance to interact with cross-chain router
        IRouterClient router = IRouterClient(this.getRouter());

        // Get the fee required to send the CCIP message
        uint256 fees = router.getFee(_destinationChainSelector, evm2AnyMessage);

        if (fees > address(this).balance)
            revert NotEnoughBalance(address(this).balance, fees);

        // approve the Router to spend tokens on contract's behalf. It will spend the amount of the given token
        IERC20(_token).approve(address(router), _amount);

        // Send the message through the router and store the returned message ID
        messageId = router.ccipSend{value: fees}(
            _destinationChainSelector,
            evm2AnyMessage
        );

        // Emit an event with message details
        emit MessageSent(
            messageId,
            _destinationChainSelector,
            _receiver,
            payload,
            _token,
            _amount,
            address(0),
            fees
        );

        // Return the message ID
        return messageId;
    }

    /// Functions to token transfers
    /**
     * @notice Returns the details of the last CCIP received message.
     * @dev This function retrieves the ID, text, token address, and token amount of the last received CCIP message.
     * @return messageId The ID of the last received CCIP message.
     * @return targetTokenAddress The text of the last received CCIP message.
     * @return targetTokenAmount The text of the last received CCIP message.
     * @return tokenAddress The address of the token in the last CCIP received message.
     * @return tokenAmount The amount of the token in the last CCIP received message.
     */
    function getLastReceivedTokenMessageDetails()
        public
        view
        returns (
            bytes32 messageId,
            address targetTokenAddress,
            uint256 targetTokenAmount,
            address tokenAddress,
            uint256 tokenAmount
        )
    {
        return (
            s_lastReceivedMessageId,
            s_lastReceivedTargetTokenAddress,
            s_lastReceivedTargetTokenAmount,
            s_lastReceivedTokenAddress,
            s_lastReceivedTokenAmount
        );
    }
    /// @notice Construct a CCIP message.
    /// @dev This function will create an EVM2AnyMessage struct with all the necessary information for programmable tokens transfer.
    /// @param _receiver The address of the receiver.
    /// @param _payload The string data to be sent.
    /// @param _token The token to be transferred.
    /// @param _amount The amount of the token to be transferred.
    /// @param _feeTokenAddress The address of the token used for fees. Set address(0) for native gas.
    /// @return Client.EVM2AnyMessage Returns an EVM2AnyMessage struct which contains information for sending a CCIP message.
    function _buildCCIPMessage(
        address _receiver,
        bytes memory _payload,
        address _token,
        uint256 _amount,
        address _feeTokenAddress
    ) internal pure returns (Client.EVM2AnyMessage memory) {
        // Set the token amounts
        Client.EVMTokenAmount[]
            memory tokenAmounts = new Client.EVMTokenAmount[](1);
        Client.EVMTokenAmount memory tokenAmount = Client.EVMTokenAmount({
            token: _token,
            amount: _amount
        });
        tokenAmounts[0] = tokenAmount;
        // Create an EVM2AnyMessage struct in memory with necessary information for sending a cross-chain message
        Client.EVM2AnyMessage memory evm2AnyMessage = Client.EVM2AnyMessage({
            receiver: abi.encode(_receiver), // ABI-encoded receiver address
            data: _payload, // ABI-encoded data
            tokenAmounts: tokenAmounts, // The amount and type of token being transferred
            extraArgs: Client._argsToBytes(
                // Additional arguments, setting gas limit and non-strict sequencing mode
                Client.EVMExtraArgsV1({gasLimit: 600_000})
            ),
            // Set the feeToken to a feeTokenAddress, indicating specific asset will be used for fees
            feeToken: _feeTokenAddress
        });
        return evm2AnyMessage;
    }

    /// @notice Fetches the details of the last received message.
    /// @return messageId The ID of the last received message.
    /// @return payloadAddress The last received payload address.
    /// @return payloadPrice The last received payload price.
    function getLastReceivedMessageDetails()
        external
        view
        returns (bytes32 messageId, address payloadAddress, uint256 payloadPrice)
    {
        return (s_lastReceivedMessageId, s_lastReceivedPayload_token, s_lastReceivedPayload_price);
    }

    /// @notice Fallback function to allow the contract to receive Ether.
    /// @dev This function has no function body, making it a default function for receiving Ether.
    /// It is automatically called when Ether is sent to the contract without any data.
    receive() external payable {}

    /// @notice Allows the contract owner to withdraw the entire balance of Ether from the contract.
    /// @dev This function reverts if there are no funds to withdraw or if the transfer fails.
    /// It should only be callable by the owner of the contract.
    /// @param _beneficiary The address to which the Ether should be sent.
    function withdraw(address _beneficiary) public onlyOwner {
        // Retrieve the balance of this contract
        uint256 amount = address(this).balance;

        // Revert if there is nothing to withdraw
        if (amount == 0) revert NothingToWithdraw();

        // Attempt to send the funds, capturing the success status and discarding any return data
        (bool sent, ) = _beneficiary.call{value: amount}("");

        // Revert if the send failed, with information about the attempted transfer
        if (!sent) revert FailedToWithdrawEth(msg.sender, _beneficiary, amount);
    }

    /// @notice Allows the owner of the contract to withdraw all tokens of a specific ERC20 token.
    /// @dev This function reverts with a 'NothingToWithdraw' error if there are no tokens to withdraw.
    /// @param _beneficiary The address to which the tokens will be sent.
    /// @param _token The contract address of the ERC20 token to be withdrawn.
    function withdrawToken(
        address _beneficiary,
        address _token
    ) public onlyOwner {
        // Retrieve the balance of this contract
        uint256 amount = IERC20(_token).balanceOf(address(this));

        // Revert if there is nothing to withdraw
        if (amount == 0) revert NothingToWithdraw();

        IERC20(_token).transfer(_beneficiary, amount);
    }

    /** -------------------------- OPERATOR MANAGEMENT CALLS ------------------------- **/

     /**
     * Returns the latest answer.
     */
    function getChainlinkDataFeedLatestAnswer(address _dataFeed) public view returns (int) {
        AggregatorV3Interface dataFeed = AggregatorV3Interface(_dataFeed);
        // prettier-ignore
        (
            /* uint80 roundID */,
            int answer,
            /*uint startedAt*/,
            /*uint timeStamp*/,
            /*uint80 answeredInRound*/
        ) = dataFeed.latestRoundData();
        return answer;
    }

    function fetchLatestPrices() public {
        for (uint256 i = 0; i < priceFeedAddresses.length; i++) {
            address token = priceFeedAddresses[i];
            RemoteOracle memory oracle = RemoteOracles[token]; // reuse same logic for forming batch portfolio
            if (oracle.destinationPriceOracleAddress == address(0)) {
                AggregatorV3Interface dataFeed = AggregatorV3Interface(token);
                // prettier-ignore
                (
                    /* uint80 roundID */,
                    int price,
                    /*uint startedAt*/,
                    /*uint timeStamp*/,
                    /*uint80 answeredInRound*/
                ) = dataFeed.latestRoundData();
                latestTokenPrices[token] = uint256(price);
            } else {
                sendMessagePayNative(
                    oracle.destinationChainSelector, 
                    oracle.destinationPriceOracleAddress,
                    token
                );
            }
        }
    }

    function setRemoteOracles(address token, RemoteOracle calldata oracle) external onlyOwner {
        priceFeedAddresses.push(token); // may result in 2 pushes
        RemoteOracles[token] = oracle;
    }

    function setMarketCaps(address[] calldata tokens, uint256[] calldata circulatingSupply) external onlyOwner {
        uint256 tempTotalMarketCap;
        for (uint256 i = 0; i < tokens.length; i++) {
            address token = tokens[i];
            uint256 tokenPrice = latestTokenPrices[token];
            uint256 tokenSupply = circulatingSupply[i];
            
            uint256 tokenMarketCap = tokenSupply * tokenPrice;
            tokensCirculatingMarketCap[token] = tokenMarketCap;
            tempTotalMarketCap += tokenMarketCap;
        }
        totalMarketCap = tempTotalMarketCap;
    }

    function deriveFractions() external onlyOwner {
        for (uint256 i = 0; i < priceFeedAddresses.length; i++) {
            address token = priceFeedAddresses[i];
            uint256 tokenMarketCap = tokensCirculatingMarketCap[token];
            uint256 fraction = (tokenMarketCap * BASIS_POINTS) / totalMarketCap;
            latestTokenWeights[token] = fraction;
        }
    }

    function setSwapper(address _swapper) external onlyOwner {
        swapper = _swapper;
    }

    function setDataFeedToMock(address priceFeed, address mockToken) external onlyOwner {
        dataFeedToTargetToken[priceFeed] = mockToken;
    }

    function triggerSwap(address _stableCoin, address priceFeedAddress, uint256 targetAmount, bool buy) internal {
        AggregatorV3Interface dataFeed = AggregatorV3Interface(priceFeedAddress);
        // prettier-ignore
        (
            /* uint80 roundID */,
            int price,
            /*uint startedAt*/,
            /*uint timeStamp*/,
            /*uint80 answeredInRound*/
        ) = dataFeed.latestRoundData();
        
        uint256 tokenPriceInStable = uint256(price); // 8 decimals
        uint256 stableCoinTokenAmount = (tokenPriceInStable * targetAmount) / 1e8; // 18 decimals
        address targetToken = dataFeedToTargetToken[priceFeedAddress];

        if (buy) {
            IERC20(_stableCoin).transferFrom(msg.sender, address(this), stableCoinTokenAmount); 
            IERC20(_stableCoin).approve(swapper, stableCoinTokenAmount);
        } else {
            IERC20(targetToken).approve(swapper, targetAmount);
        }

        (uint256 stableCoinTokenAmountSwapped, uint256 targetAmountSwapped) = SimpleSwap(swapper).swapStableForTarget(_stableCoin, priceFeedAddress, targetToken, targetAmount, buy);
        emit TokensSwapped(stableCoinTokenAmountSwapped, targetAmountSwapped);

        if (!buy) {
            IERC20(_stableCoin).transfer(msg.sender, stableCoinTokenAmountSwapped); 
        }
    }

    /** -------------------------- PORTFOLIO MANAGEMENT CALLS ------------------------- **/

    function formBatchPortfolio() public {
        portfolioId.increment();
        TokenPosition[] storage portfolio = portfolios[portfolioId.current()];

        for (uint256 i = 0; i < priceFeedAddresses.length; i++) {
            address priceFeedAddress = priceFeedAddresses[i];
            address targetToken = dataFeedToTargetToken[priceFeedAddress];
            uint256 fraction = latestTokenWeights[priceFeedAddress];
            uint256 stableCoinValueOfToken = PORTFOLIO_SIZE * fraction / BASIS_POINTS; 
            uint256 tokenAmount = (stableCoinValueOfToken / latestTokenPrices[priceFeedAddress]) * 1e8;
            uint256 stableCoinAmount = stableCoinValueOfToken * 12 / 10;  // Send 20% extra tokens to mitigate price fluctuations
            RemoteOracle memory oracle = RemoteOracles[priceFeedAddress]; // reuse same logic for forming batch portfolio

            if (oracle.destinationPriceOracleAddress == address(0)) {
                triggerSwap(stableCoin, priceFeedAddress, tokenAmount, true);

                TokenPosition memory currentTokenPosition = TokenPosition(
                    priceFeedAddress, 
                    targetToken,
                    tokenAmount,
                    fraction
                );
                
                portfolio.push(currentTokenPosition);
            } else {
                IERC20(stableCoin).transferFrom(msg.sender, address(this), stableCoinAmount);

                sendMessagePayNative(
                    oracle.destinationChainSelector, 
                    oracle.destinationSwapperAddress, 
                    priceFeedAddress,
                    tokenAmount,
                    true, // true to buy tokens, false to sell
                    stableCoin,
                    stableCoinAmount
                );

                TokenPosition memory currentTokenPosition = TokenPosition( // any changes here?
                    priceFeedAddress, 
                    targetToken,
                    tokenAmount,
                    fraction
                );
                
                portfolio.push(currentTokenPosition);
            }
        }
        portfoliosOwners[portfolioId.current()] = msg.sender;
    }

    function rebalancePortfolio(uint256 _portfolioId) public {
        require(msg.sender == portfoliosOwners[_portfolioId]);

        TokenPosition[] storage portfolio = portfolios[_portfolioId];

        for (uint256 i = 0; i < portfolio.length; i++) {
            TokenPosition storage tokenPosition = portfolio[i];

            address priceFeedAddress = tokenPosition.tokenPriceFeed;
            uint256 fraction = latestTokenWeights[priceFeedAddress];
            uint256 stableCoinValueOfToken = PORTFOLIO_SIZE * fraction / BASIS_POINTS; 
            uint256 tokenAmount = (stableCoinValueOfToken / latestTokenPrices[priceFeedAddress]) * 1e8;

            RemoteOracle memory oracle = RemoteOracles[priceFeedAddress]; // reuse same logic for forming batch portfolio

            uint256 amountToBuyOrSell;
            bool buyOrSell;
            if (tokenAmount > tokenPosition.amount) {
                amountToBuyOrSell = tokenAmount - tokenPosition.amount;
                buyOrSell = true;
            } else {
                amountToBuyOrSell = tokenPosition.amount - tokenAmount;
                buyOrSell = false;
            }
                        
            if (oracle.destinationPriceOracleAddress == address(0)) {
                triggerSwap(stableCoin, priceFeedAddress, amountToBuyOrSell, buyOrSell);
            } else { // Different Chain
                uint256 updatedTokenAmount = 
                    amountToBuyOrSell * latestTokenPrices[priceFeedAddress] / 1e8 * 12 / 10;  // Send 20% extra tokens to mitigate price fluctuations, recalculate value

                if (buyOrSell) { // deposit if need to buy fo rebalancing
                    IERC20(stableCoin).transferFrom(msg.sender, address(this), updatedTokenAmount);   
                } else {
                    updatedTokenAmount = 0; // no need to send tokeny on sell
                }
                sendMessagePayNative(
                    oracle.destinationChainSelector, 
                    oracle.destinationSwapperAddress, 
                    priceFeedAddress,
                    amountToBuyOrSell,
                    buyOrSell, // true to buy tokens, false to sell
                    stableCoin,
                    updatedTokenAmount
                );
            }

            tokenPosition.amount = tokenAmount;                    
            tokenPosition.weight = fraction;
        }
    }

    function redeemBatchPortfolio(uint256 _portfolioId) public {
        require(msg.sender == portfoliosOwners[_portfolioId]);

        TokenPosition[] storage portfolio = portfolios[_portfolioId];

        for (uint256 i = 0; i < portfolio.length; i++) {
            TokenPosition storage tokenPosition = portfolio[i];
            address priceFeedAddress = tokenPosition.tokenPriceFeed;
            RemoteOracle memory oracle = RemoteOracles[priceFeedAddress]; // reuse same logic for forming batch portfolio

            if (tokenPosition.mockTokenAddress == address(0)) {
                sendMessagePayNative(
                    oracle.destinationChainSelector, 
                    oracle.destinationSwapperAddress, 
                    priceFeedAddress,
                    tokenPosition.amount,
                    false, // true to buy tokens, false to sell
                    stableCoin,
                    0
                );
            } else {
                triggerSwap(stableCoin, tokenPosition.tokenPriceFeed, tokenPosition.amount, false);
            }
        }
    }
}

