## Cross-Chain Portfolio Manager Documentation
The main purpose of these MVP contracts is to present a way to manage token portfolios cross-chain from a single contract in a decentralized manner. 

Contracts consist of:
-   **MockToken**: Simple Mock ERC20 token for testing purposes.
-   **SimpleSwap**: Mock implementation of DEX, which fetches latest tokens prices using Chainlink Data Feed; used for testing on testnets, as tokens with high liqudity are not yet supported on mainnet 
-   **PriceOracleReceiver**: Contract to be deployed on target chain to fetch the latest price of tokens of interest.
-   **SwapperOracleReceiver**: Contract to be deployed on target chain to receive the sent tokens and orders, process swaps, and return the refund to origin chain.
-   **PriceOracleReceiver**: The main contract, which manages the portfolio funds. It implements two main pieces of cross-chain functionality: ability to fetch latest prices of tokens available on remote chains, and delegating orders to buy or sell target tokens on remote chains. The contract allows to perform three core actions: formation of cross-chain portfolio, redemption of the portfolio, and rebalancing of weights cross-chain.

## Usage

### Build

```shell
$ forge build
```

### Test

```shell
$ forge test
```

### Format

```shell
$ forge fmt
```

### Gas Snapshots

```shell
$ forge snapshot
```

### Anvil

```shell
$ anvil
```

### Cast

```shell
$ cast <subcommand>
```

### Help

```shell
$ forge --help
$ anvil --help
$ cast --help
```
