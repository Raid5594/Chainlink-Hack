// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./mockToken.sol";

/**
 * THIS IS AN EXAMPLE CONTRACT THAT USES HARDCODED
 * VALUES FOR CLARITY.
 * THIS IS AN EXAMPLE CONTRACT THAT USES UN-AUDITED CODE.
 * DO NOT USE THIS CODE IN PRODUCTION.
 */

/**
 * If you are reading data feeds on L2 networks, you must
 * check the latest answer from the L2 Sequencer Uptime
 * Feed to ensure that the data is accurate in the event
 * of an L2 sequencer outage. See the
 * https://docs.chain.link/data-feeds/l2-sequencer-feeds
 * page for details.
 */


contract SimpleSwap {    

    function swapStableForTarget(
        address stableCoin,
        address priceFeed,
        address targetCoin,
        uint256 targetAmount, // 18 decimals
        bool buy // true for buy / false for sell
    ) public returns(uint256, uint256) {
        AggregatorV3Interface dataFeed = AggregatorV3Interface(priceFeed);
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
        
        if (buy) {
            IERC20 mockStableCoin = IERC20(stableCoin);
            bool success = mockStableCoin.transferFrom(msg.sender, address(this), stableCoinTokenAmount);
            require(success, "transfer from failed");

            ERC20MockToken mockTargetCoin = ERC20MockToken(targetCoin);
            mockTargetCoin.mint(address(this), targetAmount);

            bool successtx = mockTargetCoin.transfer(msg.sender, targetAmount);
            require(successtx, "transfer failed");
        } else {
            ERC20MockToken mockTargetCoin = ERC20MockToken(targetCoin);
            bool success = mockTargetCoin.transferFrom(msg.sender, address(this), targetAmount);
            require(success, "transfer from failed");

            IERC20 mockStableCoin = IERC20(stableCoin);
            bool successtx = mockStableCoin.transfer(msg.sender, stableCoinTokenAmount);
            require(successtx, "transfer failed");
        }
        
        return (stableCoinTokenAmount, targetAmount);
    }

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

    function dripALot(address token, uint128 tokens) public {
        for (uint i; i < tokens; i++) {
            ERC20MockToken(token).drip(msg.sender);
        }
    }
}