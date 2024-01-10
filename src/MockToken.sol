// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import '@openzeppelin/contracts/token/ERC20/ERC20.sol';

contract ERC20MockToken is ERC20 {
  string private _name;
  string private _symbol;

  constructor() ERC20('ERC20MockOP', 'e20mOP') {}

  function mint(address to, uint256 amount) external {
    _mint(to, amount);
  }
  
  // Gives one full token to any given address.
  function drip(address to) external {
    _mint(to, 1e18);
  }

  function setNameAndSymbol(string calldata _newName, string calldata _newSymbol) public {
    _name = _newName;
    _symbol = _newSymbol;
  }

   /**
     * @dev Returns the name of the token.
     */
    function name() public view override returns (string memory) {
        return _name;
    }

    /**
     * @dev Returns the symbol of the token, usually a shorter version of the
     * name.
     */
    function symbol() public view override returns (string memory) {
        return _symbol;
    }

}
