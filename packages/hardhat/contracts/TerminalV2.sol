// SPDX-License-Identifier: MIT
pragma solidity 0.8.6;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Address.sol";

import "@paulrberg/contracts/math/PRBMath.sol";
import "@paulrberg/contracts/math/PRBMathUD60x18.sol";

import "./interfaces/ITerminalV2.sol";
import "./interfaces/IGovernable.sol";

import "./abstract/JuiceboxProject.sol";
import "./abstract/Operatable.sol";
import "./abstract/Governable.sol";

import "./libraries/Operations.sol";
import "./libraries/Operations2.sol";

/**
  ─────────────────────────────────────────────────────────────────────────────────────────────────
  ─────────██████──███████──██████──██████████──██████████████──██████████████──████████████████───
  ─────────██░░██──███░░██──██░░██──██░░░░░░██──██░░░░░░░░░░██──██░░░░░░░░░░██──██░░░░░░░░░░░░██───
  ─────────██░░██──███░░██──██░░██──████░░████──██░░██████████──██░░██████████──██░░████████░░██───
  ─────────██░░██──███░░██──██░░██────██░░██────██░░██──────────██░░██──────────██░░██────██░░██───
  ─────────██░░██──███░░██──██░░██────██░░██────██░░██──────────██░░██████████──██░░████████░░██───
  ─────────██░░██──███░░██──██░░██────██░░██────██░░██──────────██░░░░░░░░░░██──██░░░░░░░░░░░░██───
  ─██████──██░░██──███░░██──██░░██────██░░██────██░░██──────────██░░██████████──██░░██████░░████───
  ─██░░██──██░░██──███░░██──██░░██────██░░██────██░░██──────────██░░██──────────██░░██──██░░██─────
  ─██░░██████░░██──███░░██████░░██──████░░████──██░░██████████──██░░██████████──██░░██──██░░██████─
  ─██░░░░░░░░░░██──███░░░░░░░░░░██──██░░░░░░██──██░░░░░░░░░░██──██░░░░░░░░░░██──██░░██──██░░░░░░██─
  ─██████████████──███████████████──██████████──██████████████──██████████████──██████──██████████─
  ───────────────────────────────────────────────────────────────────────────────────────────

  @notice 
  This contract manages the Juicebox ecosystem, serves as a payment terminal, and custodies all funds.

  @dev 
  A project can transfer its funds, along with the power to reconfigure and mint/burn their Tickets, from this contract to another allowed terminal contract at any time.
*/
contract TerminalV2 is
    ITerminalV2,
    ITerminal,
    Governable,
    Operatable,
    ReentrancyGuard
{
    // --- private stored properties --- //

    // The difference between the processed ticket tracker of a project and the project's ticket's total supply is the amount of tickets that
    // still need to have reserves printed against them.
    mapping(uint256 => int256) private _processedTicketTrackerOf;

    // The amount of ticket printed prior to a project configuring their first funding cycle.
    mapping(uint256 => uint256) private _preconfigureTicketCountOf;

    // --- public immutable stored properties --- //

    /// @notice The Projects contract which mints ERC-721's that represent project ownership and transfers.
    IProjects public immutable override projects;

    /// @notice The contract storing all funding cycle configurations.
    IFundingCycles public immutable override fundingCycles;

    /// @notice The contract that manages Ticket printing and redeeming.
    ITicketBooth public immutable override ticketBooth;

    /// @notice The contract that stores mods for each project.
    IModStore public immutable override modStore;

    /// @notice The prices feeds.
    IPrices public immutable override prices;

    /// @notice The directory of terminals.
    ITerminalDirectory public immutable override terminalDirectory;

    // --- public stored properties --- //

    /// @notice The amount of ETH that each project is responsible for.
    mapping(uint256 => uint256) public override balanceOf;

    /// @notice The percent fee the Juicebox project takes from tapped amounts. Out of 200.
    uint256 public override fee = 10;

    // Whether or not a particular contract is available for projects to migrate their funds and Tickets to.
    mapping(ITerminal => bool) public override migrationIsAllowed;

    // --- external views --- //

    /** 
      @notice 
      Gets the current overflowed amount for a specified project.

      @param _projectId The ID of the project to get overflow for.

      @return overflow The current overflow of funds for the project.
    */
    function currentOverflowOf(uint256 _projectId)
        external
        view
        override
        returns (uint256 overflow)
    {
        // Get a reference to the project's current funding cycle.
        FundingCycle memory _fundingCycle = fundingCycles.currentOf(_projectId);

        // There's no overflow if there's no funding cycle.
        if (_fundingCycle.number == 0) return 0;

        return _overflowFrom(_fundingCycle);
    }

    /** 
      @notice 
      Gets the amount of reserved tickets that a project has.

      @param _projectId The ID of the project to get overflow for.
      @param _reservedRate The reserved rate to use to make the calculation.

      @return amount overflow The current overflow of funds for the project.
    */
    function reservedTicketBalanceOf(uint256 _projectId, uint256 _reservedRate)
        external
        view
        override
        returns (uint256)
    {
        return
            _reservedTicketAmountFrom(
                _processedTicketTrackerOf[_projectId],
                _reservedRate,
                ticketBooth.totalSupplyOf(_projectId)
            );
    }

    /**
      @notice 
      The amount of tokens that can be claimed by the given address.

      @dev If there is a funding cycle reconfiguration ballot open for the project, the project's current bonding curve is bypassed.

      @param _projectId The ID of the project to get a claimable amount for.
      @param _count The number of Tickets that would be redeemed to get the resulting amount.

      @return amount The amount of tokens that can be claimed.
    */
    function claimableOverflowOf(uint256 _projectId, uint256 _count)
        external
        view
        override
        returns (uint256)
    {
        return
            _claimableOverflowOf(fundingCycles.currentOf(_projectId), _count);
    }

    // --- public views --- //

    /**
      @notice
      Whether or not a project can still print premined tickets.

      @param _projectId The ID of the project to get the status of.

      @return Boolean flag.
    */
    function canPrintPreminedTickets(uint256 _projectId)
        public
        view
        override
        returns (bool)
    {
        return
            // The total supply of tickets must equal the preconfigured ticket count.
            ticketBooth.totalSupplyOf(_projectId) ==
            _preconfigureTicketCountOf[_projectId] &&
            // The above condition is still possible after post-configured tickets have been printed due to ticket redeeming.
            // The only case when processedTicketTracker is 0 is before redeeming and printing reserved tickets.
            _processedTicketTrackerOf[_projectId] >= 0 &&
            uint256(_processedTicketTrackerOf[_projectId]) ==
            _preconfigureTicketCountOf[_projectId];
    }

    // --- external transactions --- //

    /** 
      @param _projects A Projects contract which mints ERC-721's that represent project ownership and transfers.
      @param _fundingCycles A funding cycle configuration store.
      @param _ticketBooth A contract that manages Ticket printing and redeeming.
      @param _operatorStore A contract storing operator assignments.
      @param _modStore A storage for a project's mods.
      @param _prices A price feed contract to use.
      @param _terminalDirectory A directory of a project's current Juicebox terminal to receive payments in.
    */
    constructor(
        IProjects _projects,
        IFundingCycles _fundingCycles,
        ITicketBooth _ticketBooth,
        IOperatorStore _operatorStore,
        IModStore _modStore,
        IPrices _prices,
        ITerminalDirectory _terminalDirectory,
        address _governance
    ) Operatable(_operatorStore) Governable(_governance) {
        require(
            _projects != IProjects(address(0)) &&
                _fundingCycles != IFundingCycles(address(0)) &&
                _ticketBooth != ITicketBooth(address(0)) &&
                _operatorStore != IOperatorStore(address(0)) &&
                _modStore != IModStore(address(0)) &&
                _prices != IPrices(address(0)) &&
                _terminalDirectory != ITerminalDirectory(address(0)),
            "TerminalV2: ZERO_ADDRESS"
        );
        projects = _projects;
        fundingCycles = _fundingCycles;
        ticketBooth = _ticketBooth;
        modStore = _modStore;
        prices = _prices;
        terminalDirectory = _terminalDirectory;
        governance = _governance;
    }

    /**
      @notice 
      Deploys a project. This will mint an ERC-721 into the `_owner`'s account, configure a first funding cycle, and set up any mods.

      @dev
      Each operation withing this transaction can be done in sequence separately.

      @dev
      Anyone can deploy a project on an owner's behalf.

      @param _owner The address that will own the project.
      @param _handle The project's unique handle.
      @param _uri A link to information about the project and this funding cycle.
      @param _properties The funding cycle configuration.
        @dev _properties.target The amount that the project wants to receive in this funding cycle. Sent as a wad.
        @dev _properties.currency The currency of the `target`. Send 0 for ETH or 1 for USD.
        @dev _properties.duration The duration of the funding stage for which the `target` amount is needed. Measured in days. Send 0 for a boundless cycle reconfigurable at any time.
        @dev _properties.cycleLimit The number of cycles that this configuration should last for before going back to the last permanent. This has no effect for a project's first funding cycle.
        @dev _properties.discountRate A number from 0-200 indicating how valuable a contribution to this funding stage is compared to the project's previous funding stage.
          If it's 200, each funding stage will have equal weight.
          If the number is 180, a contribution to the next funding stage will only give you 90% of tickets given to a contribution of the same amount during the current funding stage.
          If the number is 0, an non-recurring funding stage will get made.
        @dev _properties.ballot The new ballot that will be used to approve subsequent reconfigurations.
      @param _metadata A struct specifying the TerminalV2 specific params _bondingCurveRate, and _reservedRate.
        @dev _metadata.reservedRate A number from 0-200 indicating the percentage of each contribution's tickets that will be reserved for the project owner.
        @dev _metadata.bondingCurveRate The rate from 0-200 at which a project's Tickets can be redeemed for surplus.
          The bonding curve formula is https://www.desmos.com/calculator/sp9ru6zbpk
          where x is _count, o is _currentOverflow, s is _totalSupply, and r is _bondingCurveRate.
        @dev _metadata.reconfigurationBondingCurveRate The bonding curve rate to apply when there is an active ballot.
      @param _payoutMods Any payout mods to set.
      @param _ticketMods Any ticket mods to set.
    */
    function deploy(
        address _owner,
        bytes32 _handle,
        string calldata _uri,
        FundingCycleProperties calldata _properties,
        FundingCycleMetadataV2 calldata _metadata,
        PayoutMod[] memory _payoutMods,
        TicketMod[] memory _ticketMods
    ) external override {
        // Make sure the metadata checks out. If it does, return a packed version of it.
        uint256 _packedMetadata = _validateAndPackFundingCycleMetadata(
            _metadata
        );

        // Create the project for the owner.
        uint256 _projectId = projects.create(_owner, _handle, _uri, this);

        // Configure the funding stage's state.
        FundingCycle memory _fundingCycle = fundingCycles.configure(
            _projectId,
            _properties,
            _packedMetadata,
            fee,
            true
        );

        // Set payout mods if there are any.
        if (_payoutMods.length > 0)
            modStore.setPayoutMods(
                _projectId,
                _fundingCycle.configured,
                _payoutMods
            );

        // Set ticket mods if there are any.
        if (_ticketMods.length > 0)
            modStore.setTicketMods(
                _projectId,
                _fundingCycle.configured,
                _ticketMods
            );
    }

    /**
      @notice 
      Configures the properties of the current funding cycle if the project hasn't distributed tickets yet, or
      sets the properties of the proposed funding cycle that will take effect once the current one expires
      if it is approved by the current funding cycle's ballot.

      @dev
      Only a project's owner or a designated operator can configure its funding cycles.

      @param _projectId The ID of the project being reconfigured. 
      @param _properties The funding cycle configuration.
        @dev _properties.target The amount that the project wants to receive in this funding stage. Sent as a wad.
        @dev _properties.currency The currency of the `target`. Send 0 for ETH or 1 for USD.
        @dev _properties.duration The duration of the funding stage for which the `target` amount is needed. Measured in days. Send 0 for a boundless cycle reconfigurable at any time.
        @dev _properties.cycleLimit The number of cycles that this configuration should last for before going back to the last permanent. This has no effect for a project's first funding cycle.
        @dev _properties.discountRate A number from 0-200 indicating how valuable a contribution to this funding stage is compared to the project's previous funding stage.
          If it's 200, each funding stage will have equal weight.
          If the number is 180, a contribution to the next funding stage will only give you 90% of tickets given to a contribution of the same amount during the current funding stage.
          If the number is 0, an non-recurring funding stage will get made.
        @dev _properties.ballot The new ballot that will be used to approve subsequent reconfigurations.
      @param _metadata A struct specifying the TerminalV2 specific params _bondingCurveRate, and _reservedRate.
        @dev _metadata.reservedRate A number from 0-200 indicating the percentage of each contribution's tickets that will be reserved for the project owner.
        @dev _metadata.bondingCurveRate The rate from 0-200 at which a project's Tickets can be redeemed for surplus.
          The bonding curve formula is https://www.desmos.com/calculator/sp9ru6zbpk
          where x is _count, o is _currentOverflow, s is _totalSupply, and r is _bondingCurveRate.
        @dev _metadata.reconfigurationBondingCurveRate The bonding curve rate to apply when there is an active ballot.
      @param _payoutMods Any payout mods to set.
      @param _ticketMods Any ticket mods to set.

      @return The ID of the funding cycle that was successfully configured.
    */
    function configure(
        uint256 _projectId,
        FundingCycleProperties calldata _properties,
        FundingCycleMetadataV2 calldata _metadata,
        PayoutMod[] memory _payoutMods,
        TicketMod[] memory _ticketMods
    )
        external
        override
        nonReentrant
        requirePermission(
            projects.ownerOf(_projectId),
            _projectId,
            Operations.Configure
        )
        returns (uint256)
    {
        // Make sure the metadata is validated, and pack it into a uint256.
        uint256 _packedMetadata = _validateAndPackFundingCycleMetadata(
            _metadata
        );

        // All reserved tickets must be printed before configuring.
        if (
            uint256(_processedTicketTrackerOf[_projectId]) !=
            ticketBooth.totalSupplyOf(_projectId)
        ) _printReservedTickets(_projectId, "");

        // If the project can still print premined tickets configure the active funding cycle instead of creating a standby one.
        bool _shouldConfigureActive = canPrintPreminedTickets(_projectId);

        // Configure the funding stage's state.
        FundingCycle memory _fundingCycle = fundingCycles.configure(
            _projectId,
            _properties,
            _packedMetadata,
            fee,
            _shouldConfigureActive
        );

        // Set payout mods for the new configuration if there are any.
        if (_payoutMods.length > 0)
            modStore.setPayoutMods(
                _projectId,
                _fundingCycle.configured,
                _payoutMods
            );

        // Set payout mods for the new configuration if there are any.
        if (_ticketMods.length > 0)
            modStore.setTicketMods(
                _projectId,
                _fundingCycle.configured,
                _ticketMods
            );

        return _fundingCycle.id;
    }

    /** 
      @notice 
      Allows a project to print tickets for a specified beneficiary before payments have been received.

      @dev 
      This can only be done if the project hasn't yet received a payment after configuring a funding cycle.

      @dev
      Only a project's owner or a designated operator can print premined tickets.

      @param _projectId The ID of the project to premine tickets for.
      @param _amount The amount to base the ticket premine off of.
      @param _currency The currency of the amount to base the ticket premine off of. 
      @param _beneficiary The address to send the printed tickets to.
      @param _memo A memo to leave with the printing.
      @param _preferUnstakedTickets If there is a preference to unstake the printed tickets.
    */
    function printPreminedTickets(
        uint256 _projectId,
        uint256 _amount,
        uint256 _currency,
        uint256 _weight,
        address _beneficiary,
        string memory _memo,
        bool _preferUnstakedTickets
    )
        external
        override
        nonReentrant
        requirePermission(
            projects.ownerOf(_projectId),
            _projectId,
            Operations.PrintPreminedTickets
        )
    {
        // Can't send to the zero address.
        require(
            _beneficiary != address(0),
            "TerminalV2::printPreminedTickets: ZERO_ADDRESS"
        );

        // Get the current funding cycle to read the weight and currency from.
        _weight = _weight > 0 ? _weight : fundingCycles.BASE_WEIGHT();

        // Get the current funding cycle to read the weight and currency from.
        // Multiply the amount by the funding cycle's weight to determine the amount of tickets to print.
        uint256 _weightedAmount = PRBMathUD60x18.mul(
            PRBMathUD60x18.div(_amount, prices.getETHPriceFor(_currency)),
            _weight
        );

        // Make sure the project hasnt printed tickets that werent preconfigure.
        // Do this check after the external calls above.
        require(
            canPrintPreminedTickets(_projectId),
            "TerminalV2::printPreminedTickets: ALREADY_ACTIVE"
        );

        // Set the preconfigure tickets as processed so that reserved tickets cant be minted against them.
        // Make sure int casting isnt overflowing the int. 2^255 - 1 is the largest number that can be stored in an int.
        require(
            _processedTicketTrackerOf[_projectId] < 0 ||
                uint256(_processedTicketTrackerOf[_projectId]) +
                    uint256(_weightedAmount) <=
                uint256(type(int256).max),
            "TerminalV1::printPreminedTickets: INT_LIMIT_REACHED"
        );

        // Set the preconfigure tickets as processed so that reserved tickets cant be minted against them.
        _processedTicketTrackerOf[_projectId] =
            _processedTicketTrackerOf[_projectId] +
            int256(_weightedAmount);

        // Set the count of preconfigure tickets this project has printed.
        _preconfigureTicketCountOf[_projectId] =
            _preconfigureTicketCountOf[_projectId] +
            _weightedAmount;

        // Print the project's tickets for the beneficiary.
        ticketBooth.print(
            _beneficiary,
            _projectId,
            _weightedAmount,
            _preferUnstakedTickets
        );

        emit PrintPreminedTickets(
            _projectId,
            _beneficiary,
            _amount,
            _weight,
            _weightedAmount,
            _currency,
            _memo,
            msg.sender
        );
    }

    /**
      @notice 
      Contribute ETH to a project.

      @dev 
      Print's the project's tickets proportional to the amount of the contribution.

      @dev 
      The msg.value is the amount of the contribution in wei.

      @param _projectId The ID of the project being contribute to.
      @param _beneficiary The address to print Tickets for. 
      @param _memo A memo that will be included in the published event.
      @param _preferUnstakedTickets Whether ERC20's should be unstaked automatically if they have been issued.

      @return The ID of the funding cycle that the payment was made during.
    */
    function pay(
        uint256 _projectId,
        address _beneficiary,
        string calldata _memo,
        bool _preferUnstakedTickets
    ) external payable override nonReentrant returns (uint256) {
        return
            _pay(
                _projectId,
                msg.value,
                _beneficiary,
                0,
                _memo,
                _preferUnstakedTickets
            );
    }

    /**
      @notice 
      Contribute ETH to a project.

      @dev 
      Print's the project's tickets proportional to the amount of the contribution.

      @dev 
      The msg.value is the amount of the contribution in wei.

      @param _projectId The ID of the project being contribute to.
      @param _beneficiary The address to print Tickets for. 
      @param _minReturnedTickets The minimum number of tickets expected in return. 
      @param _memo A memo that will be included in the published event.
      @param _preferUnstakedTickets Whether ERC20's should be unstaked automatically if they have been issued.

      @return The ID of the funding cycle that the payment was made during.
    */
    function pay(
        uint256 _projectId,
        address _beneficiary,
        uint256 _minReturnedTickets,
        string calldata _memo,
        bool _preferUnstakedTickets
    ) external payable override nonReentrant returns (uint256) {
        return
            _pay(
                _projectId,
                msg.value,
                _beneficiary,
                _minReturnedTickets,
                _memo,
                _preferUnstakedTickets
            );
    }

    /**
      @notice 
      Tap into funds that have been contributed to a project's current funding cycle.

      @dev
      Anyone can tap funds on a project's behalf.

      @param _projectId The ID of the project to which the funding cycle being tapped belongs.
      @param _amount The amount being tapped, in the funding cycle's currency.
      @param _currency The expected currency being tapped.
      @param _minReturnedWei The minimum number of wei that the amount should be valued at.

      @return The ID of the funding cycle that was tapped.
    */
    function tap(
        uint256 _projectId,
        uint256 _amount,
        uint256 _currency,
        uint256 _minReturnedWei,
        string memory _memo
    ) external override nonReentrant returns (uint256) {
        // Register the funds as tapped. Get the ID of the funding cycle that was tapped.
        FundingCycle memory _fundingCycle = fundingCycles.tap(
            _projectId,
            _amount
        );

        // If there's no funding cycle, there are no funds to tap.
        if (_fundingCycle.id == 0) return 0;

        // Must not be paused.
        require(
            ((_fundingCycle.metadata >> 33) & 1) == 1,
            "TerminalV2:tap: PAUSED"
        );

        // Make sure the currency's match.
        require(
            _currency == _fundingCycle.currency,
            "TerminalV2::tap: UNEXPECTED_CURRENCY"
        );

        // The amount of ETH that is being tapped.
        uint256 _tappedWeiAmount = PRBMathUD60x18.div(
            _amount,
            prices.getETHPriceFor(_fundingCycle.currency)
        );

        // The amount being tapped must be at least as much as was expected.
        require(
            _minReturnedWei <= _tappedWeiAmount,
            "TerminalV2::tap: INADEQUATE"
        );

        // The amount being tapped must be available.
        require(
            _tappedWeiAmount <= balanceOf[_projectId],
            "TerminalV2::tap: INSUFFICIENT_FUNDS"
        );

        // Removed the tapped funds from the project's balance.
        balanceOf[_projectId] = balanceOf[_projectId] - _tappedWeiAmount;

        // Get a reference to the project owner, which will receive the admin's tickets from paying the fee,
        // and receive any extra tapped funds not allocated to mods.
        address payable _projectOwner = payable(projects.ownerOf(_projectId));

        // Get a reference to the handle of the project paying the fee and sending payouts.
        bytes32 _handle = projects.handleOf(_projectId);

        // Take a fee from the _tappedWeiAmount, if needed.
        // The project's owner will be the beneficiary of the resulting printed tickets from the governance project.
        uint256 _feeAmount = _fundingCycle.fee > 0 && _projectId > 1
            ? _takeFee(
                _tappedWeiAmount,
                _fundingCycle.fee,
                _projectOwner,
                string(bytes.concat("Fee from @", _handle))
            )
            : 0;

        // Payout to mods and get a reference to the leftover transfer amount after all mods have been paid.
        // The net transfer amount is the tapped amount minus the fee.
        uint256 _leftoverTransferAmount = _distributeToPayoutMods(
            _fundingCycle,
            _tappedWeiAmount - _feeAmount,
            string(bytes.concat("Payout from @", _handle))
        );

        // Transfer any remaining balance to the beneficiary.
        if (_leftoverTransferAmount > 0)
            Address.sendValue(_projectOwner, _leftoverTransferAmount);

        emit Tap(
            _fundingCycle.id,
            _projectId,
            _projectOwner,
            _amount,
            _tappedWeiAmount - _feeAmount,
            _leftoverTransferAmount,
            _feeAmount,
            _memo,
            msg.sender
        );

        return _fundingCycle.id;
    }

    /**
      @notice 
      Addresses can redeem their Tickets to claim the project's overflowed ETH.

      @dev
      Only a ticket's holder or a designated operator can redeem it.

      @param _account The account to redeem tickets for.
      @param _projectId The ID of the project to which the Tickets being redeemed belong.
      @param _count The number of Tickets to redeem.
      @param _minReturnedWei The minimum amount of Wei expected in return.
      @param _beneficiary The address to send the ETH to. Send the address this contract to burn the count.
      @param _preferUnstaked If the preference is to redeem tickets that have been converted to ERC-20s.

      @return amount The amount of ETH that the tickets were redeemed for.
    */
    function redeem(
        address _account,
        uint256 _projectId,
        uint256 _count,
        uint256 _minReturnedWei,
        address payable _beneficiary,
        string memory _memo,
        bool _preferUnstaked
    )
        external
        override
        nonReentrant
        requirePermissionAllowingWildcardDomain(
            _account,
            _projectId,
            Operations.Redeem
        )
        returns (uint256 amount)
    {
        // Get a reference to the current funding cycle for the project.
        FundingCycle memory _fundingCycle = fundingCycles.currentOf(_projectId);

        // Must not be paused.
        require(
            ((_fundingCycle.metadata >> 34) & 1) == 1,
            "TerminalV2:redeem: PAUSED"
        );

        // Save a reference to the type of access that is granted to this request by the delegate.
        AccessType _accessType;

        // Burn if the beneficiary address is that of this contract.
        if (_beneficiary == address(this)) {
            amount = 0;
            _accessType = AccessType.Allow;
        } else {
            // The amount of ETH claimable by the message sender from the specified project by redeeming the specified number of tickets.
            (amount, _memo, _accessType) = IFundingCycleDelegate(
                address(uint160(_fundingCycle.metadata >> 37))
            ) ==
                IFundingCycleDelegate(address(0)) &&
                ((_fundingCycle.metadata >> 36) & 1) == 1
                ? (
                    _claimableOverflowOf(_fundingCycle, _count),
                    _memo,
                    AccessType.Allow
                )
                : IFundingCycleDelegate(
                    address(uint160(_fundingCycle.metadata >> 37))
                ).redeemParams(
                        _fundingCycle,
                        _count,
                        _beneficiary,
                        _memo,
                        msg.sender
                    );

            require(
                _accessType != AccessType.Disallow,
                "TerminalV2::redeem: DISALLOWED"
            );

            // The amount being claimed must be at least as much as was expected.
            require(
                amount >= _minReturnedWei,
                "TerminalV2::redeem: INADEQUATE"
            );

            require(
                amount <= balanceOf[_projectId],
                "TerminalV2::redeem: INSUFFICIENT_FUNDS"
            );

            // Can't send claimed funds to the zero address.
            require(
                amount == 0 || _beneficiary != address(0),
                "TerminalV2::redeem: ZERO_ADDRESS"
            );
        }

        // The holder must have the specified number of the project's tickets.
        require(
            ticketBooth.balanceOf(_account, _projectId) >= _count,
            "TerminalV2::redeem: INSUFFICIENT_TICKETS"
        );

        // Redeem the tickets, which burns them.
        if (_count > 0) {
            // Get a reference to the processed ticket tracker for the project.
            int256 _processedTicketTracker = _processedTicketTrackerOf[
                _projectId
            ];

            // Subtract the count from the processed ticket tracker.
            // Subtract from processed tickets so that the difference between whats been processed and the
            // total supply remains the same.
            // If there are at least as many processed tickets as there are tickets being redeemed,
            // the processed ticket tracker of the project will be positive. Otherwise it will be negative.
            _processedTicketTrackerOf[_projectId] = _processedTicketTracker < 0 // If the tracker is negative, add the count and reverse it.
                ? -int256(uint256(-_processedTicketTracker) + _count) // the tracker is less than the count, subtract it from the count and reverse it.
                : _processedTicketTracker < int256(_count)
                ? -(int256(_count) - _processedTicketTracker) // simply subtract otherwise.
                : _processedTicketTracker - int256(_count);

            ticketBooth.redeem(_account, _projectId, _count, _preferUnstaked);
        }

        // Remove the redeemed funds from the project's balance.
        if (amount > 0) {
            balanceOf[_projectId] = balanceOf[_projectId] - amount;
            // Transfer funds to the specified address.
            Address.sendValue(_beneficiary, amount);
        }

        if (_accessType == AccessType.AllowWithCallback)
            IFundingCycleDelegate(
                address(uint160(_fundingCycle.metadata >> 37))
            ).redeemCallback(
                    _fundingCycle,
                    _count,
                    amount,
                    _beneficiary,
                    _memo,
                    msg.sender
                );

        emit Redeem(
            _account,
            _beneficiary,
            _projectId,
            _count,
            amount,
            _memo,
            msg.sender
        );
    }

    /**
      @notice 
      Allows a project owner to migrate its funds and operations to a new contract.

      @dev
      Only a project's owner or a designated operator can migrate it.

      @param _projectId The ID of the project being migrated.
      @param _to The contract that will gain the project's funds.
    */
    function migrate(uint256 _projectId, ITerminal _to)
        external
        override
        nonReentrant
        requirePermission(
            projects.ownerOf(_projectId),
            _projectId,
            Operations.Migrate
        )
    {
        // This TerminalV1 must be the project's current terminal.
        require(
            terminalDirectory.terminalOf(_projectId) == this,
            "TerminalV2::migrate: UNAUTHORIZED"
        );

        // The migration destination must be allowed.
        require(migrationIsAllowed[_to], "TerminalV2::migrate: NOT_ALLOWED");

        // All reserved tickets must be printed before migrating.
        if (
            uint256(_processedTicketTrackerOf[_projectId]) !=
            ticketBooth.totalSupplyOf(_projectId)
        ) _printReservedTickets(_projectId, "");

        // Get a reference to this project's current balance, included any earned yield.
        uint256 _balanceOf = balanceOf[_projectId];

        // Set the balance to 0.
        balanceOf[_projectId] = 0;

        // Move the funds to the new contract if needed.
        if (_balanceOf > 0) _to.addToBalance{value: _balanceOf}(_projectId);

        // Switch the direct payment terminal.
        terminalDirectory.setTerminal(_projectId, _to);

        emit Migrate(_projectId, _to, _balanceOf, msg.sender);
    }

    /** 
      @notice 
      Receives and allocates funds belonging to the specified project.

      @param _projectId The ID of the project to which the funds received belong.
    */
    function addToBalance(uint256 _projectId) external payable override {
        // The amount must be positive.
        require(msg.value > 0, "TerminalV1::addToBalance: BAD_AMOUNT");
        // Set the processed ticket tracker if this isnt the current terminal for the project.
        if (terminalDirectory.terminalOf(_projectId) != this)
            // Set the tracker to be the new total supply.
            _processedTicketTrackerOf[_projectId] = int256(
                ticketBooth.totalSupplyOf(_projectId)
            );

        // Set the balance.
        balanceOf[_projectId] = balanceOf[_projectId] + msg.value;
        emit AddToBalance(_projectId, msg.value, msg.sender);
    }

    /**
      @notice 
      Adds to the contract addresses that projects can migrate their Tickets to.

      @dev
      Only governance can add a contract to the migration allow list.

      @param _contract The contract to allow.
    */
    function allowMigration(ITerminal _contract) external override onlyGov {
        // Can't allow the zero address.
        require(
            _contract != ITerminal(address(0)),
            "TerminalV2::allowMigration: ZERO_ADDRESS"
        );

        // Toggle the contract as allowed.
        migrationIsAllowed[_contract] = !migrationIsAllowed[_contract];

        emit AllowMigration(_contract);
    }

    // --- public transactions --- //

    /**
      @notice 
      Prints all reserved tickets for a project.

      @param _projectId The ID of the project to which the reserved tickets belong.

      @return amount The amount of tickets that are being printed.
    */
    function printReservedTickets(uint256 _projectId, string memory _memo)
        external
        override
        nonReentrant
        returns (uint256 amount)
    {
        return _printReservedTickets(_projectId, _memo);
    }

    // --- private helper functions --- //

    /** 
      @notice
      Pays out the mods for the specified funding cycle.

      @param _fundingCycle The funding cycle to base the distribution on.
      @param _amount The total amount being paid out.
      @param _memo A memo to send along with project payouts.

      @return leftoverAmount If the mod percents dont add up to 100%, the leftover amount is returned.

    */
    function _distributeToPayoutMods(
        FundingCycle memory _fundingCycle,
        uint256 _amount,
        string memory _memo
    ) private returns (uint256 leftoverAmount) {
        // Set the leftover amount to the initial amount.
        leftoverAmount = _amount;

        // Get a reference to the project's payout mods.
        PayoutMod[] memory _mods = modStore.payoutModsOf(
            _fundingCycle.projectId,
            _fundingCycle.configured
        );

        if (_mods.length == 0) return leftoverAmount;

        //Transfer between all mods.
        for (uint256 _i = 0; _i < _mods.length; _i++) {
            // Get a reference to the mod being iterated on.
            PayoutMod memory _mod = _mods[_i];

            // The amount to send towards mods. Mods percents are out of 10000.
            uint256 _modCut = PRBMath.mulDiv(_amount, _mod.percent, 10000);

            if (_modCut > 0) {
                // Transfer ETH to the mod.
                // If there's an allocator set, transfer to its `allocate` function.
                if (_mod.allocator != IModAllocator(address(0))) {
                    _mod.allocator.allocate{value: _modCut}(
                        _fundingCycle.projectId,
                        _mod.projectId,
                        _mod.beneficiary
                    );
                } else if (_mod.projectId != 0) {
                    // Otherwise, if a project is specified, make a payment to it.

                    // Get a reference to the Juicebox terminal being used.
                    ITerminal _terminal = terminalDirectory.terminalOf(
                        _mod.projectId
                    );

                    // The project must have a terminal to send funds to.
                    require(
                        _terminal != ITerminal(address(0)),
                        "TerminalV2::_distributeToPayoutMods: BAD_MOD"
                    );

                    // Save gas if this contract is being used as the terminal.
                    if (_terminal == this) {
                        _pay(
                            _mod.projectId,
                            _modCut,
                            _mod.beneficiary,
                            0,
                            _memo,
                            _mod.preferUnstaked
                        );
                    } else {
                        _terminal.pay{value: _modCut}(
                            _mod.projectId,
                            _mod.beneficiary,
                            _memo,
                            _mod.preferUnstaked
                        );
                    }
                } else {
                    // Otherwise, send the funds directly to the beneficiary.
                    Address.sendValue(_mod.beneficiary, _modCut);
                }

                // Subtract from the amount to be sent to the beneficiary.
                leftoverAmount = leftoverAmount - _modCut;
            }

            emit DistributeToPayoutMod(
                _fundingCycle.id,
                _fundingCycle.projectId,
                _mod,
                _modCut,
                msg.sender
            );
        }
    }

    /** 
      @notice
      distributed tickets to the mods for the specified funding cycle.

      @param _fundingCycle The funding cycle to base the ticket distribution on.
      @param _amount The total amount of tickets to print.

      @return leftoverAmount If the mod percents dont add up to 100%, the leftover amount is returned.

    */
    function _distributeToTicketMods(
        FundingCycle memory _fundingCycle,
        uint256 _amount
    ) private returns (uint256 leftoverAmount) {
        // Set the leftover amount to the initial amount.
        leftoverAmount = _amount;

        // Get a reference to the project's ticket mods.
        TicketMod[] memory _mods = modStore.ticketModsOf(
            _fundingCycle.projectId,
            _fundingCycle.configured
        );

        //Transfer between all mods.
        for (uint256 _i = 0; _i < _mods.length; _i++) {
            // Get a reference to the mod being iterated on.
            TicketMod memory _mod = _mods[_i];

            // The amount to send towards mods. Mods percents are out of 10000.
            uint256 _modCut = PRBMath.mulDiv(_amount, _mod.percent, 10000);

            // Print tickets for the mod if needed.
            if (_modCut > 0)
                ticketBooth.print(
                    _mod.beneficiary,
                    _fundingCycle.projectId,
                    _modCut,
                    _mod.preferUnstaked
                );

            // Subtract from the amount to be sent to the beneficiary.
            leftoverAmount = leftoverAmount - _modCut;

            emit DistributeToTicketMod(
                _fundingCycle.id,
                _fundingCycle.projectId,
                _mod,
                _modCut,
                msg.sender
            );
        }
    }

    /** 
      @notice 
      See the documentation for 'pay'.
    */
    function _pay(
        uint256 _projectId,
        uint256 _amount,
        address _beneficiary,
        uint256 _minReturnedTickets,
        string memory _memo,
        bool _preferUnstakedTickets
    ) private returns (uint256) {
        // Positive payments only.
        require(_amount > 0, "TerminalV2::_pay: BAD_AMOUNT");

        // Cant send tickets to the zero address.
        require(_beneficiary != address(0), "TerminalV2::_pay: ZERO_ADDRESS");

        // Get a reference to the current funding cycle for the project.
        FundingCycle memory _fundingCycle = fundingCycles.currentOf(_projectId);

        // Must not be paused.
        require(
            ((_fundingCycle.metadata >> 32) & 1) == 1,
            "TerminalV2:_pay: PAUSED"
        );

        require(_fundingCycle.number > 0, "TerminalV2::_pay: NO_FUNDING_CYCLE");

        uint256 _weight;
        AccessType _accessType;

        // Get weight
        (_weight, _memo, _accessType) = IFundingCycleDelegate(
            address(uint160(_fundingCycle.metadata >> 34))
        ) ==
            IFundingCycleDelegate(address(0)) &&
            ((_fundingCycle.metadata >> 37) & 1) == 1
            ? (
                _fundingCycle.weight,
                _memo,
                AccessType(uint8(_fundingCycle.metadata >> 35))
            )
            : IFundingCycleDelegate(
                address(uint160(_fundingCycle.metadata >> 37))
            ).payParams(
                    _fundingCycle,
                    _amount,
                    _beneficiary,
                    _memo,
                    msg.sender
                );

        require(
            _accessType != AccessType.Disallow,
            "TerminalV2::_pay: DISALLOWED"
        );

        // Multiply the amount by the funding cycle's weight to determine the amount of tickets to print.
        uint256 _weightedAmount = PRBMathUD60x18.mul(_amount, _weight);

        // Only print the tickets that are unreserved.
        uint256 _ticketCountToPrint = PRBMath.mulDiv(
            _weightedAmount,
            // The reserved rate is stored in bits 8-15 of the metadata property.
            200 - uint256(uint8(_fundingCycle.metadata >> 8)),
            200
        );

        // The minimum amount of unreserved tickets must be printed.
        require(
            _ticketCountToPrint >= _minReturnedTickets,
            "TerminalV2::_pay: INADEQUATE"
        );

        // Add to the balance of the project.
        balanceOf[_projectId] = balanceOf[_projectId] + _amount;

        // If theres an unreserved weighted amount, print tickets representing this amount for the beneficiary.
        if (_ticketCountToPrint > 0) {
            // Print the project's tickets for the beneficiary.
            ticketBooth.print(
                _beneficiary,
                _projectId,
                _ticketCountToPrint,
                _preferUnstakedTickets
            );
        } else if (_weightedAmount > 0) {
            // If there is no unreserved weight amount but there is a weighted amount,
            // the full weighted amount should be explicitly tracked as reserved since no unreserved tickets were printed.
            // Subtract the total weighted amount from the tracker so the full reserved ticket amount can be printed later.
            // Make sure int casting isnt overflowing the int. 2^255 - 1 is the largest number that can be stored in an int.
            require(
                _processedTicketTrackerOf[_projectId] > 0 ||
                    uint256(-_processedTicketTrackerOf[_projectId]) +
                        uint256(_weightedAmount) <=
                    uint256(type(int256).max),
                "TerminalV2::_pay: INT_LIMIT_REACHED"
            );

            // Subtract the total weighted amount from the tracker so the full reserved ticket amount can be printed later.
            _processedTicketTrackerOf[_projectId] =
                _processedTicketTrackerOf[_projectId] -
                int256(_weightedAmount);
        }

        if (_accessType == AccessType.AllowWithCallback)
            IFundingCycleDelegate(
                address(uint160(_fundingCycle.metadata >> 37))
            ).payCallback(
                    _fundingCycle,
                    _amount,
                    _weight,
                    _ticketCountToPrint,
                    _beneficiary,
                    _memo,
                    msg.sender
                );

        emit Pay(
            _fundingCycle.number,
            _projectId,
            _beneficiary,
            _amount,
            _memo,
            msg.sender
        );

        return _fundingCycle.number;
    }

    /** 
      @notice 
      Gets the amount of reserved tickets currently tracked for a project given a reserved rate.

      @param _processedTicketTracker The tracker to make the calculation with.
      @param _reservedRate The reserved rate to use to make the calculation.
      @param _totalEligibleTickets The total amount to make the calculation with.

      @return amount reserved ticket amount.
    */
    function _reservedTicketAmountFrom(
        int256 _processedTicketTracker,
        uint256 _reservedRate,
        uint256 _totalEligibleTickets
    ) private pure returns (uint256) {
        // Get a reference to the amount of tickets that are unprocessed.
        uint256 _unprocessedTicketBalanceOf = _processedTicketTracker >= 0 // preconfigure tickets shouldn't contribute to the reserved ticket amount.
            ? _totalEligibleTickets - uint256(_processedTicketTracker)
            : _totalEligibleTickets + uint256(-_processedTicketTracker);

        // If there are no unprocessed tickets, return.
        if (_unprocessedTicketBalanceOf == 0) return 0;

        // If all tickets are reserved, return the full unprocessed amount.
        if (_reservedRate == 200) return _unprocessedTicketBalanceOf;

        return
            PRBMath.mulDiv(
                _unprocessedTicketBalanceOf,
                200,
                200 - _reservedRate
            ) - _unprocessedTicketBalanceOf;
    }

    /**
      @notice 
      Validate and pack the funding cycle metadata.

      @param _metadata The metadata to validate and pack.

      @return packed The packed uint256 of all metadata params. The first 8 bytes specify the version.
     */
    function _validateAndPackFundingCycleMetadata(
        FundingCycleMetadataV2 memory _metadata
    ) private pure returns (uint256 packed) {
        // The reserved project ticket rate must be less than or equal to 200.
        require(
            _metadata.reservedRate <= 200,
            "TerminalV2::_validateAndPackFundingCycleMetadata: BAD_RESERVED_RATE"
        );

        // The bonding curve rate must be between 0 and 200.
        require(
            _metadata.bondingCurveRate <= 200,
            "TerminalV2::_validateAndPackFundingCycleMetadata: BAD_BONDING_CURVE_RATE"
        );

        // The reconfiguration bonding curve rate must be less than or equal to 200.
        require(
            _metadata.reconfigurationBondingCurveRate <= 200,
            "TerminalV2::_validateAndPackFundingCycleMetadata: BAD_RECONFIGURATION_BONDING_CURVE_RATE"
        );

        // version 0 in the first 8 bytes.
        packed = 0;
        // reserved rate in bits 8-15.
        packed |= _metadata.reservedRate << 8;
        // bonding curve in bits 16-23.
        packed |= _metadata.bondingCurveRate << 16;
        // reconfiguration bonding curve rate in bits 24-31.
        packed |= _metadata.reconfigurationBondingCurveRate << 24;
        // pause pay in bit 32.
        packed |= (_metadata.pausePay ? 1 : 0) << 32;
        // pause tap in bit 33.
        packed |= (_metadata.pauseTap ? 1 : 0) << 33;
        // pause redeem  in bit 34.
        packed |= (_metadata.pauseRedeem ? 1 : 0) << 34;
        // use pay delegate in bit 32.
        packed |= (_metadata.usePayDelegate ? 1 : 0) << 35;
        // use redeem delegate in bit 33.
        packed |= (_metadata.useRedeemDelegate ? 1 : 0) << 36;
        // delegate address in bits 37-196.
        packed |= uint160(address(_metadata.delegate)) << 37;
    }

    /** 
      @notice 
      Takes a fee into the juiceboxDAO's project, which has an id of 1.

      @param _from The amount to take a fee from.
      @param _percent The percent fee to take. Out of 200.
      @param _beneficiary The address to print governance's tickets for.
      @param _memo A memo to send with the fee.

      @return feeAmount The amount of the fee taken.
    */
    function _takeFee(
        uint256 _from,
        uint256 _percent,
        address _beneficiary,
        string memory _memo
    ) private returns (uint256 feeAmount) {
        // The amount of ETH from the _tappedAmount to pay as a fee.
        feeAmount = _from - PRBMath.mulDiv(_from, 200, _percent + 200);

        // Nothing to do if there's no fee to take.
        if (feeAmount == 0) return 0;

        // Get the terminal for the JuiceboxDAO project.
        ITerminal _terminal = terminalDirectory.terminalOf(1);

        // When processing the admin fee, save gas if the admin is using this contract as its terminal.
        _terminal == this // Use the local pay call.
            ? _pay(1, feeAmount, _beneficiary, 0, _memo, false) // Use the external pay call of the correct terminal.
            : _terminal.pay{value: feeAmount}(1, _beneficiary, _memo, false);
    }

    /** 
      @notice See docs for `printReservedTickets`
    */
    function _printReservedTickets(uint256 _projectId, string memory _memo)
        private
        returns (uint256 amount)
    {
        // Get the current funding cycle to read the reserved rate from.
        FundingCycle memory _fundingCycle = fundingCycles.currentOf(_projectId);

        // If there's no funding cycle, there's no reserved tickets to print.
        if (_fundingCycle.number == 0) return 0;

        // Get a reference to new total supply of tickets before printing reserved tickets.
        uint256 _totalTickets = ticketBooth.totalSupplyOf(_projectId);

        // Get a reference to the number of tickets that need to be printed.
        // If there's no funding cycle, there's no tickets to print.
        // The reserved rate is in bits 8-15 of the metadata.
        amount = _reservedTicketAmountFrom(
            _processedTicketTrackerOf[_projectId],
            uint256(uint8(_fundingCycle.metadata >> 8)),
            _totalTickets
        );

        // Make sure int casting isnt overflowing the int. 2^255 - 1 is the largest number that can be stored in an int.
        require(
            _totalTickets + amount <= uint256(type(int256).max),
            "TerminalV1::printReservedTickets: INT_LIMIT_REACHED"
        );

        // Set the tracker to be the new total supply.
        _processedTicketTrackerOf[_projectId] = int256(_totalTickets + amount);

        // Get a reference to the project owner.
        address _owner = projects.ownerOf(_projectId);

        // Distribute tickets to mods and get a reference to the leftover amount to print after all mods have had their share printed.
        uint256 _leftoverTicketAmount = amount == 0
            ? 0
            : _distributeToTicketMods(_fundingCycle, amount);

        // If there's nothing to print, return.
        // TODO new: moved down to allow setting tracker when amount is 0.
        if (_leftoverTicketAmount > 0)
            // Print any remaining reserved tickets to the owner.
            ticketBooth.print(_owner, _projectId, _leftoverTicketAmount, false);

        emit PrintReserveTickets(
            _fundingCycle.number,
            _projectId,
            _owner,
            amount,
            _leftoverTicketAmount,
            _memo,
            msg.sender
        );
    }

    function _claimableOverflowOf(
        FundingCycle memory _fundingCycle,
        uint256 _count
    ) private view returns (uint256) {
        // Get the amount of current overflow.
        uint256 _currentOverflow = _overflowFrom(_fundingCycle);

        // If there is no overflow, nothing is claimable.
        if (_currentOverflow == 0) return 0;

        // Get the total number of tickets in circulation.
        uint256 _totalSupply = ticketBooth.totalSupplyOf(
            _fundingCycle.projectId
        );

        // Get the number of reserved tickets the project has.
        // The reserved rate is in bits 8-15 of the metadata.
        uint256 _reservedTicketAmount = _reservedTicketAmountFrom(
            _processedTicketTrackerOf[_fundingCycle.projectId],
            uint256(uint8(_fundingCycle.metadata >> 8)),
            _totalSupply
        );

        // If there are reserved tickets, add them to the total supply.
        if (_reservedTicketAmount > 0)
            _totalSupply = _totalSupply + _reservedTicketAmount;

        // If the amount being redeemed is the the total supply, return the rest of the overflow.
        if (_count == _totalSupply) return _currentOverflow;

        // Get a reference to the linear proportion.
        uint256 _base = PRBMath.mulDiv(_currentOverflow, _count, _totalSupply);

        // Use the reconfiguration bonding curve if the queued cycle is pending approval according to the previous funding cycle's ballot.
        uint256 _bondingCurveRate = fundingCycles.currentBallotStateOf(
            _fundingCycle.projectId
        ) == BallotState.Active // The reconfiguration bonding curve rate is stored in bits 24-31 of the metadata property.
            ? uint256(uint8(_fundingCycle.metadata >> 24)) // The bonding curve rate is stored in bits 16-23 of the data property after.
            : uint256(uint8(_fundingCycle.metadata >> 16));

        // The bonding curve formula.
        // https://www.desmos.com/calculator/sp9ru6zbpk
        // where x is _count, o is _currentOverflow, s is _totalSupply, and r is _bondingCurveRate.

        // These conditions are all part of the same curve. Edge conditions are separated because fewer operation are necessary.
        if (_bondingCurveRate == 200) return _base;
        // TODO NEW: 0 bonding curve means not redeemable.
        if (_bondingCurveRate == 0) return 0;
        // return PRBMath.mulDiv(_base, _count, _totalSupply);
        return
            PRBMath.mulDiv(
                _base,
                _bondingCurveRate +
                    PRBMath.mulDiv(
                        _count,
                        200 - _bondingCurveRate,
                        _totalSupply
                    ),
                200
            );
    }

    /** 
      @notice 
      Gets the amount overflowed in relation to the provided funding cycle.

      @dev
      This amount changes as the price of ETH changes against the funding cycle's currency.

      @param _currentFundingCycle The ID of the funding cycle to base the overflow on.

      @return overflow The current overflow of funds.
    */
    function _overflowFrom(FundingCycle memory _currentFundingCycle)
        private
        view
        returns (uint256)
    {
        // Get the current balance of the project.
        uint256 _balanceOf = balanceOf[_currentFundingCycle.projectId];

        if (_balanceOf == 0) return 0;

        // Get a reference to the amount still tappable in the current funding cycle.
        uint256 _limit = _currentFundingCycle.target -
            _currentFundingCycle.tapped;

        // The amount of ETH that the owner could currently still tap if its available. This amount isn't considered overflow.
        uint256 _ethLimit = _limit == 0
            ? 0 // Get the current price of ETH.
            : PRBMathUD60x18.div(
                _limit,
                prices.getETHPriceFor(_currentFundingCycle.currency)
            );

        // Overflow is the balance of this project minus the reserved amount.
        return _balanceOf < _ethLimit ? 0 : _balanceOf - _ethLimit;
    }
}