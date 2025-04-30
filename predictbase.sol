// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

contract PredictBase is ReentrancyGuard {
    address public superAdmin;
    IERC20 public usdcToken;

    uint256 public constant creatorFeePercent = 1;
    uint256 public createMarketFee = 0.001 ether;

    bool public paused;

    mapping(address => bool) public admins;
    mapping(address => bool) public subscribers;

    enum MarketStatus { Pending, Active, Resolved, Canceled }

    struct Market {
        address payable creator;
        string question;
        string category;
        string details;
        string image;
        uint256 endDate;
        uint256 optionCount;
        uint256 totalVolume;
        uint256 winningOption;
        uint256 creatorFee;
        uint256 protocolFee;
        MarketStatus status;
    }

    struct Bet {
        address user;
        uint256 marketId;
        uint256 option;
        uint256 amount;
        uint256 fee;
        bool claimed;
    }

    mapping(uint256 => Market) public markets;
    mapping(uint256 => bool) public marketExistsFlag;
    uint256 public marketCounter;

    mapping(uint256 => mapping(uint256 => mapping(address => Bet))) public userBets;
    // userBets[marketId][option][user] = Bet

    mapping(uint256 => mapping(uint256 => string)) public optionTitles;
    mapping(uint256 => mapping(uint256 => uint256)) public optionsBetAmount;

    event MarketCreated(
        uint256 indexed marketId,
        address indexed creator,
        string question,
        string details,
        string category,
        string image,
        uint256 endDate,
        string[] optionTitles,
        MarketStatus status
    );

    event MarketApproved(
        uint256 indexed marketId,
        string question,
        string details,
        string category,
        string image,
        uint256 endDate,
        string[] optionTitles
    );

    event BetPlaced(uint256 indexed marketId, address indexed user, uint256 option, uint256 amount, uint256 betCreatorFee, uint256 betProtocolFee);
    event WinningsClaimed(uint256 marketId, address user, uint256 option, uint256 amount, bool isRefund);
    event MarketResolved(uint256 indexed marketId, uint256 winningOption, address indexed creator, uint256 creatorRevenue, uint256 protocolRevenue);
    event MarketCanceled(uint256 indexed marketId);
    event MarketEndDateUpdated(uint256 indexed marketId, uint256 newEndDate);
    event AdminUpdated(address indexed admin, bool isAuthorized);
    event SuperAdminUpdated(address indexed newSuperAdmin);
    event Paused(bool status);
    event SubscriberUpdated(address indexed user, bool isSubscribed); 

    modifier onlySuperAdmin() {
        require(msg.sender == superAdmin, "Not super admin");
        _;
    }

    modifier onlyAdmin() {
        require(admins[msg.sender] || msg.sender == superAdmin, "Not an admin");
        _;
    }

    modifier marketExists(uint256 marketId) {
        require(marketExistsFlag[marketId], "Market does not exist");
        _;
    }

    modifier notPaused() {
        require(!paused, "Contract is paused");
        _;
    }

    constructor(address _usdcAddress) {
        superAdmin = msg.sender;
        usdcToken = IERC20(_usdcAddress);
        admins[msg.sender] = true;
        emit AdminUpdated(msg.sender, true);
    }

    function setSuperAdmin(address newAdmin) external onlySuperAdmin {
        require(newAdmin != address(0), "Invalid address");
        superAdmin = newAdmin;
        emit SuperAdminUpdated(newAdmin);
    }

    function setAdmin(address admin, bool isAuthorized) external onlySuperAdmin {
        require(admin != address(0), "Invalid address");
        admins[admin] = isAuthorized;
        emit AdminUpdated(admin, isAuthorized);
    }

    function setSubscriber(address user, bool isSubscribed) external onlySuperAdmin {
        require(user != address(0), "Invalid address");
        subscribers[user] = isSubscribed;
        emit SubscriberUpdated(user, isSubscribed);
    }

    function setCreateMarketFee(uint256 _newFee) external onlySuperAdmin {
        createMarketFee = _newFee;
    }

    function setPaused(bool _paused) external onlySuperAdmin {
        paused = _paused;
        emit Paused(_paused);
    }

    function createMarket(
        string memory _question,
        string memory _details,
        string memory _category,
        string memory _image,
        uint256 _endDate,
        string[] memory _optionTitles
    ) external payable notPaused {
        require(_optionTitles.length >= 2, "At least 2 options required");
        require(_endDate > block.timestamp, "End date must be in the future");

        if (!admins[msg.sender]) {
            if (!subscribers[msg.sender]) {
                require(msg.value == createMarketFee, "Must pay exact ETH fee");
                payable(superAdmin).transfer(msg.value);
            } else {
                require(msg.value == 0, "Subscribers shouldn't send ETH");
            }
        } else {
            require(msg.value == 0, "Admins shouldn't send ETH");
        }

        marketCounter++;
        uint256 marketId = marketCounter;
        Market storage market = markets[marketId];
        marketExistsFlag[marketId] = true;

        market.creator = payable(msg.sender);
        market.question = _question;
        market.category = _category;
        market.details = _details;
        market.image = _image;
        market.endDate = _endDate;
        market.optionCount = _optionTitles.length;
        market.status = admins[msg.sender] ? MarketStatus.Active : MarketStatus.Pending;

        for (uint256 i = 0; i < _optionTitles.length;) {
            optionTitles[marketId][i] = _optionTitles[i];
            unchecked { ++i; }
        }

        emit MarketCreated(marketId, msg.sender, _question, _details, _category, _image, _endDate, _optionTitles, market.status);
    }

    function approveMarket(
        uint256 marketId,
        string memory _question,
        string memory _details,
        string memory _category,
        string memory _image,
        uint256 _endDate,
        string[] memory _optionTitles
    ) external onlyAdmin marketExists(marketId) {
        Market storage market = markets[marketId];
        require(market.status == MarketStatus.Pending, "Market is not pending");
        require(_optionTitles.length >= 2, "At least 2 options required");
        require(_endDate > block.timestamp, "End date must be in the future");

        market.question = _question;
        market.details = _details;
        market.category = _category;
        market.image = _image;
        market.endDate = _endDate;

        // Clear old options (optional, only needed if you're updating options)
        for (uint256 i = 0; i < market.optionCount;) {
            delete optionTitles[marketId][i];
            unchecked { ++i; }
        }

        market.optionCount = _optionTitles.length;

        for (uint256 i = 0; i < _optionTitles.length;) {
            optionTitles[marketId][i] = _optionTitles[i];
            unchecked { ++i; }
        }

        market.status = MarketStatus.Active;
        emit MarketApproved(
            marketId,
            _question,
            _details,
            _category,
            _image,
            _endDate,
            _optionTitles
        );
    }

    function placeBet(uint256 marketId, uint256 option, uint256 totalAmount) external notPaused marketExists(marketId) {
        require(totalAmount > 0, "Amount must be greater than 0");

        Market storage market = markets[marketId];
        require(market.status == MarketStatus.Active, "Market not active");
        require(block.timestamp < market.endDate, "Betting deadline passed");
        require(option < market.optionCount, "Invalid option");

        require(usdcToken.transferFrom(msg.sender, address(this), totalAmount), "Transfer failed");

        uint256 actualAmount = (totalAmount * 100) / 102;
        uint256 betFee = totalAmount - actualAmount;
        uint256 betProtocolFee = (actualAmount * 1) / 100;
        uint256 betCreatorFee = (actualAmount * 1) / 100;

        Bet storage bet = userBets[marketId][option][msg.sender];

        if (bet.amount == 0) {
            // First time placing bet on this option
            bet.user = msg.sender;
            bet.marketId = marketId;
            bet.option = option;
            bet.claimed = false;
        }

        bet.amount += actualAmount;
        bet.fee += betFee;

        optionsBetAmount[marketId][option] += actualAmount;
        market.totalVolume += actualAmount;
        market.creatorFee += betCreatorFee;
        market.protocolFee += betProtocolFee;

        emit BetPlaced(marketId, msg.sender, option, actualAmount, betCreatorFee, betProtocolFee);
    }

    function claimBet(uint256 marketId, uint256 option) external nonReentrant marketExists(marketId) {
        Market storage market = markets[marketId];
        require(
            market.status == MarketStatus.Resolved || market.status == MarketStatus.Canceled,
            "Market not closed"
        );

        Bet storage bet = userBets[marketId][option][msg.sender];
        require(bet.user == msg.sender, "Not your bet");
        require(!bet.claimed, "Already claimed");
        require(bet.amount > 0, "No bet found");

        bet.claimed = true;

        uint256 totalAmount;
        bool isRefund = market.status == MarketStatus.Canceled;

        if (isRefund) {
            totalAmount = bet.amount + bet.fee;
        } else {
            require(option == market.winningOption, "Not winning option");
            uint256 totalWinningPool = optionsBetAmount[marketId][option];
            require(totalWinningPool > 0, "No bets on winning option");
            totalAmount = (bet.amount * market.totalVolume) / totalWinningPool;
        }

        require(usdcToken.transfer(msg.sender, totalAmount), "Transfer failed");
        emit WinningsClaimed(marketId, msg.sender, option, totalAmount, isRefund);
    }

    function resolveMarket(uint256 marketId, uint256 winningOption) external nonReentrant onlyAdmin marketExists(marketId) {
        Market storage market = markets[marketId];
        require(market.status == MarketStatus.Active, "Market not active");
        require(winningOption < market.optionCount, "Invalid option");

        uint256 activeOptions = 0;
        for (uint256 i = 0; i < market.optionCount;) {
            if (optionsBetAmount[marketId][i] > 0) {
                activeOptions++;
            }
            unchecked { ++i; }
        }

        if (activeOptions <= 1) {
            market.status = MarketStatus.Canceled;
            emit MarketCanceled(marketId);
            return;
        }

        market.status = MarketStatus.Resolved;
        market.winningOption = winningOption;

        if (market.creatorFee > 0) {
            require(usdcToken.transfer(market.creator, market.creatorFee), "Creator fee failed");
        }

        if (market.protocolFee > 0) {
            require(usdcToken.transfer(superAdmin, market.protocolFee), "Protocol fee failed");
        }
        emit MarketResolved(marketId, winningOption, market.creator, market.creatorFee, market.protocolFee);
    }

    function cancelMarket(uint256 marketId) external onlyAdmin marketExists(marketId) {
        Market storage market = markets[marketId];
        require(
            market.status == MarketStatus.Active || market.status == MarketStatus.Pending,
            "Market must be active or pending"
        );
        market.status = MarketStatus.Canceled;
        emit MarketCanceled(marketId);
    }

    function updateMarketEndDate(uint256 marketId, uint256 newEndDate) external onlyAdmin marketExists(marketId) {
        Market storage market = markets[marketId];
        require(
            market.status == MarketStatus.Pending || market.status == MarketStatus.Active,
            "Can only update date for pending or active markets"
        );

        market.endDate = newEndDate;
        emit MarketEndDateUpdated(marketId, newEndDate);
    }

    function getCreateMarketFee() external view returns (uint256) {
        return createMarketFee;
    }

    function getMarketStatus(uint256 marketId) external view returns (MarketStatus) {
        return markets[marketId].status;
    }

    function getUserBet(uint256 marketId, uint256 option, address user) external view returns (Bet memory) {
        return userBets[marketId][option][user];
    }

    function getOptionTitle(uint256 marketId, uint256 option) external view returns (string memory) {
        return optionTitles[marketId][option];
    }

    function getOptionBetAmount(uint256 marketId, uint256 option) external view returns (uint256) {
        return optionsBetAmount[marketId][option];
    }

    function getMarketInfo(uint256 marketId) external view returns (
        address creator,
        string memory question,
        string memory category,
        string memory details,
        string memory image,
        uint256 endDate,
        uint256 totalVolume,
        uint256 optionCount,
        MarketStatus status
    ) {
        Market storage m = markets[marketId];
        return (
            m.creator,
            m.question,
            m.category,
            m.details,
            m.image,
            m.endDate,
            m.totalVolume,
            m.optionCount,
            m.status
        );
    }

    receive() external payable {
        revert("Direct ETH not allowed");
    }

    fallback() external payable {
        revert("Fallback not allowed");
    }
}