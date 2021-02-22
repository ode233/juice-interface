// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface ITicketsController {
    event Redeem(
        address indexed holder,
        address indexed issuer,
        address beneficiary,
        uint256 amount,
        uint256 returnAmount,
        IERC20 returnToken
    );

    event Swap(
        address issuer,
        IERC20 from,
        uint256 amount,
        IERC20 to,
        uint256 swappedAmount
    );

    function redeem(
        address _issuer,
        uint256 _amount,
        uint256 _minReturn,
        address _beneficiary
    ) external returns (uint256 returnAmount);

    function addToMigrationAllowList(address _contract) external;
}
