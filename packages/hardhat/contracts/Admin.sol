// SPDX-License-Identifier: MIT
pragma solidity >=0.6.0 <0.8.0;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";

import "./interfaces/IJuicer.sol";
import "./abstract/JuiceAdmin.sol";

/// All functions in here should be governable with FLOW.
/// Owner should eventually change to a governance contract.
contract Admin is JuiceAdmin {
    using SafeERC20 for IERC20;

    /** 
      @param _juicer The juicer that is being administered.
      @param _router The router used to execute swaps.
      @param _rewardToken The token that this project's Tickets can be redeemed for.
    */
    constructor(
        IJuicer _juicer,
        UniswapV2Router02 _router,
        IERC20 _rewardToken
    ) public JuiceAdmin(_juicer, _router) {
        juicer.budgetStore().claimOwnership();
        juicer.ticketStore().claimOwnership();
        appointJuicer(juicer);
        juicer.issueTickets("Juice", "JUICE", _rewardToken);
    }

    /** 
      @notice Grants a Juicer access to its Ticket store and Budget stores
      @param _juicer The juicer that is being appointed.
    */
    function appointJuicer(IJuicer _juicer) public onlyOwner {
        ITicketStore _ticketStore = _juicer.ticketStore();
        IBudgetStore _budgetStore = _juicer.budgetStore();
        _ticketStore.grantRole_(
            _ticketStore.DEFAULT_ADMIN_ROLE_(),
            address(_juicer)
        );
        _budgetStore.grantRole_(
            _budgetStore.DEFAULT_ADMIN_ROLE_(),
            address(_juicer)
        );
        _juicer.setAdmin(address(this));
    }

    /** 
      @notice Revokes the ability for a Juicer to access its Ticket store and Budget stores
      @param _juicer The juicer that is being depcrecated.
    */
    function deprecateJuicer(IJuicer _juicer) external onlyOwner {
        IBudgetStore _budgetStore = _juicer.budgetStore();
        ITicketStore _ticketStore = _juicer.ticketStore();
        _ticketStore.revokeRole_(
            _ticketStore.DEFAULT_ADMIN_ROLE_(),
            address(_juicer)
        );
        _budgetStore.revokeRole_(
            _budgetStore.DEFAULT_ADMIN_ROLE_(),
            address(_juicer)
        );
    }

    /** 
      @notice Gives Ticket holders within one Juicer access to migrate to another Juicer.
      @param _from The juicer to allow a new migration from.
      @param _to The juicer to allow migration to.
    */
    function allowMigration(IJuicer _from, IJuicer _to) external onlyOwner {
        _from.addToMigrationAllowList(address(_to));
    }
}