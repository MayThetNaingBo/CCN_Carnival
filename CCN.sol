// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

contract CCNCarnival {
    // Global(Time) Configuration
    uint256 public stallCounter;

    // Test-time scale: 1 "day" = 3 minutes (change to 1 days for real)  
    uint256 private constant DAY_UNIT = 1 days;

    // Organizer & Registration Gate 
    address public organizer; // can manage membership/allowlist
    mapping(address => bool) public isTPMember;
    bool public requireMemberToRegister; // off by default

    modifier onlyOrganizer() {
        require(msg.sender == organizer, "Only organizer");
        _;
    }

    // Domain Model Types 
    enum StallStatus { Open, Closed }

    struct Stall {
        uint256 id;                 // unique identifier
        address payable owner;      // stall owner
        string name;                // display name
        uint8 operatingDays;        // 1=Friday, 2=Friday+Saturday, 3=Friday+Saturday+Sunday
        uint256 balance;            // balance held for this stall
        bool exists;                // guard to validate IDs
        uint256 createdAt;          // registration timestamp
        StallStatus status;         // Open / Closed (Closed includes early-close by owner)
        uint256 pricePerItem;       // wei per item (0 = donation/variable-price)
    }

    struct Payment {
        address payer;
        uint256 amount;
        uint256 timestamp;
    }

    // Storage
    mapping(uint256 => Stall) public stalls;                   
    mapping(address => uint256[]) public userPayments;         
    mapping(uint256 => Payment[]) public paymentsByStall;     

    // Cumulative amount a buyer has paid/refunded per stall in wei
    mapping(uint256 => mapping(address => uint256)) public totalPaidByBuyer;      
    mapping(uint256 => mapping(address => uint256)) public totalRefundedToBuyer; 

    // Events
    event StallRegistered(uint256 indexed id, address indexed owner, uint256 pricePerItem);
    event PaymentMade(address indexed payer, uint256 indexed stallId, uint256 amount);
    event RefundIssued(address indexed to, uint256 indexed stallId, uint256 amount);
    event FundsWithdrawn(address indexed owner, uint256 indexed stallId, uint256 amount);
    event StallClosed(uint256 indexed stallId);
    event StallClosedEarly(uint256 indexed stallId);
    event PriceUpdated(uint256 indexed stallId, uint256 newPrice);

    // Organizer / allowlist events
    event OrganizerTransferred(address indexed oldOrganizer, address indexed newOrganizer);
    event MemberUpdated(address indexed account, bool isMember);
    event RequireMemberToRegisterSet(bool enabled);

    // Reentrancy Guard
    bool private _entered;
    modifier nonReentrant() {
        require(!_entered, "ReentrancyGuard: reentrant");
        _entered = true;
        _;
        _entered = false;
    }

    // Constructor
    constructor() {
        organizer = msg.sender;
        // Optionally, organizer can pre-add known members later using setMember(...)
        // By default, registration is OPEN to all until toggled on.
    }

    // Modifiers
    modifier stallExists(uint256 _stallId) {
        require(stalls[_stallId].exists, "Stall: not found");
        _;
    }

    modifier onlyStallOwner(uint256 _stallId) {
        require(msg.sender == stalls[_stallId].owner, "Stall: not owner");
        _;
    }

    modifier stallOpen(uint256 _stallId) {
        _closeIfExpired(_stallId);
        require(stalls[_stallId].status == StallStatus.Open, "Stall: closed");
        _;
    }

    function _closeIfExpired(uint256 _stallId) internal {
        Stall storage s = stalls[_stallId];
        if (s.exists && s.status == StallStatus.Open) {
            uint256 duration = uint256(s.operatingDays) * DAY_UNIT;
            if (block.timestamp >= s.createdAt + duration) {
                s.status = StallStatus.Closed;
                emit StallClosed(_stallId);
            }
        }
    }

    function _durationOf(uint256 _stallId) internal view returns (uint256) {
        return uint256(stalls[_stallId].operatingDays) * DAY_UNIT;
    }

  
    // Organizer Controls
    function transferOrganizer(address _newOrganizer) external onlyOrganizer {
        require(_newOrganizer != address(0), "Zero address");
        emit OrganizerTransferred(organizer, _newOrganizer);
        organizer = _newOrganizer;
    }

    // Add/remove an address from the member allowlist
    function setMember(address _account, bool _isMember) external onlyOrganizer {
        isTPMember[_account] = _isMember;
        emit MemberUpdated(_account, _isMember);
    }

    // Toggle whether registration requires membership
    function setRequireMemberToRegister(bool _enabled) external onlyOrganizer {
        requireMemberToRegister = _enabled;
        emit RequireMemberToRegisterSet(_enabled);
    }

    // Actions
    // Register a new stall with a chosen duration (1 to 3 days) and an optional fixed price.
    // Set pricePerItem to 0 to allow donation/variable payments via payToStall.
    function registerStall(string memory _name, uint8 _operatingDays, uint256 _pricePerItem) external {
        if (requireMemberToRegister) {
            require(isTPMember[msg.sender], "Register: not an authorized member");
        }
        require(_operatingDays >= 1 && _operatingDays <= 3, "Stall: invalid days");
        require(bytes(_name).length > 0 && bytes(_name).length <= 64, "Stall: name length");

        stallCounter++;
        stalls[stallCounter] = Stall({
            id: stallCounter,
            owner: payable(msg.sender),
            name: _name,
            operatingDays: _operatingDays,
            balance: 0,
            exists: true,
            createdAt: block.timestamp,
            status: StallStatus.Open,
            pricePerItem: _pricePerItem
        });

        emit StallRegistered(stallCounter, msg.sender, _pricePerItem);
    }

    // Owner can change the fixed price (0 = donation mode)
    function updatePrice(uint256 _stallId, uint256 _newPrice)
        external
        stallExists(_stallId)
        onlyStallOwner(_stallId)
    {
        stalls[_stallId].pricePerItem = _newPrice;
        emit PriceUpdated(_stallId, _newPrice);
    }

    // Close the stall early (e.g., stockout). Payments stop immediately.
    // Does NOT allow early withdrawal; withdraw is still after scheduled end.
    function closeEarly(uint256 _stallId)
        external
        stallExists(_stallId)
        onlyStallOwner(_stallId)
    {
        Stall storage s = stalls[_stallId];
        if (s.status == StallStatus.Open) {
            s.status = StallStatus.Closed;
            emit StallClosedEarly(_stallId);
        }
    }

    // Pay any amount to a stall while it is open (for donation/variable-price stalls)
    function payToStall(uint256 _stallId)
        external
        payable
        stallExists(_stallId)
        stallOpen(_stallId)
    {
        require(msg.value > 0, "Pay: amount required");

        Stall storage s = stalls[_stallId];
        s.balance += msg.value;

        userPayments[msg.sender].push(_stallId);
        paymentsByStall[_stallId].push(Payment({
            payer: msg.sender,
            amount: msg.value,
            timestamp: block.timestamp
        }));

        totalPaidByBuyer[_stallId][msg.sender] += msg.value;

        emit PaymentMade(msg.sender, _stallId, msg.value);
    }

    // Buy items at the stall's fixed price (requires pricePerItem > 0)
    function buyFromStall(uint256 _stallId, uint256 qty)
        external
        payable
        stallExists(_stallId)
        stallOpen(_stallId)
    {
        require(qty > 0, "Buy: qty > 0");
        Stall storage s = stalls[_stallId];
        require(s.pricePerItem > 0, "Buy: stall not fixed-price");

        uint256 totalCost = s.pricePerItem * qty;
        require(msg.value == totalCost, "Buy: incorrect payment");

        s.balance += msg.value;

        userPayments[msg.sender].push(_stallId);
        paymentsByStall[_stallId].push(Payment({
            payer: msg.sender,
            amount: msg.value,
            timestamp: block.timestamp
        }));

        totalPaidByBuyer[_stallId][msg.sender] += msg.value;

        emit PaymentMade(msg.sender, _stallId, msg.value);
    }

    // Refund a buyer from a stall's balance (owner-only). Buyer must have paid this stall before and can't be refunded more than they've paid in total.
    function issueRefund(address payable _buyer, uint256 _stallId, uint256 _amount)
        external
        stallExists(_stallId)
        onlyStallOwner(_stallId)
        nonReentrant
    {
        require(_buyer != address(0), "Refund: zero address");
        require(_amount > 0, "Refund: amount required");

        Stall storage s = stalls[_stallId];

        // Block refunds after the scheduled end (clear error message)
        uint256 endTime = s.createdAt + _durationOf(_stallId);
        require(block.timestamp < endTime, "Refund: stall has closed");

        // Enforce refunds only to recorded buyers
        uint256 paid = totalPaidByBuyer[_stallId][_buyer];
        require(paid > 0, "Refund: buyer has no payments for this stall");

        // Enforce cap: total refunded cannot exceed total paid
        uint256 alreadyRefunded = totalRefundedToBuyer[_stallId][_buyer];
        require(alreadyRefunded + _amount <= paid, "Refund exceeds buyer's total paid");

        require(s.balance >= _amount, "Refund: insufficient stall balance");

        s.balance -= _amount;

        (bool ok, ) = _buyer.call{value: _amount}("");
        require(ok, "Refund: transfer failed");

        // Track cumulative refunds
        totalRefundedToBuyer[_stallId][_buyer] = alreadyRefunded + _amount;

        emit RefundIssued(_buyer, _stallId, _amount);
    }

    /// @notice Withdraw all funds after stall's operating duration is over (owner-only)
    function withdrawFunds(uint256 _stallId)
        external
        stallExists(_stallId)
        onlyStallOwner(_stallId)
        nonReentrant
    {
        Stall storage s = stalls[_stallId];

        // Enforce that operating duration has ended
        uint256 endTime = s.createdAt + _durationOf(_stallId);
        require(block.timestamp >= endTime, "Withdraw: stall still operating");

        // Mark closed if not already
        if (s.status != StallStatus.Closed) {
            s.status = StallStatus.Closed;
            emit StallClosed(_stallId);
        }

        uint256 amount = s.balance;
        require(amount > 0, "Withdraw: no funds");

        s.balance = 0;

        (bool ok, ) = s.owner.call{value: amount}("");
        require(ok, "Withdraw: transfer failed");

        emit FundsWithdrawn(s.owner, _stallId, amount);
    }

 

    function getStallById(uint256 _id) external view stallExists(_id) returns (Stall memory) {
        return stalls[_id];
    }

    function isStallClosed(uint256 _stallId) external view returns (bool) {
        Stall memory s = stalls[_stallId];
        if (!s.exists) return true;
        if (s.status == StallStatus.Closed) return true;
        return block.timestamp >= s.createdAt + (uint256(s.operatingDays) * DAY_UNIT);
    }

    function getPaymentCount(uint256 _stallId) external view stallExists(_stallId) returns (uint256) {
        return paymentsByStall[_stallId].length;
    }

    function getPaymentByIndex(uint256 _stallId, uint256 _index)
        external
        view
        stallExists(_stallId)
        returns (Payment memory)
    {
        require(_index < paymentsByStall[_stallId].length, "Pay: index oob");
        return paymentsByStall[_stallId][_index];
    }

// FallBack
    receive() external payable {
        revert("Direct payments not allowed. Use pay/buy.");
    }
}
