// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {VRFConsumerBaseV2} from "@chainlink/contracts/src/v0.8/VRFConsumerBaseV2.sol";
import {VRFCoordinatorV2Interface} from "@chainlink/contracts/src/v0.8/interfaces/VRFCoordinatorV2Interface.sol";
import {AutomationCompatible} from "@chainlink/contracts/src/v0.8/AutomationCompatible.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {console} from "forge-std/console.sol";

contract Lottery is VRFConsumerBaseV2, AutomationCompatible {
    //** Errors */
    error Lottery__MustBetween1And99();
    error Lottery__NotEnoughTokensSent();
    error Lottery__TransferFailed();
    error Lottery__OnlyOwner();
    error Lottery__NotOpen();
    error Lottery__UpkeepNotNeeded(uint256 timeLeft, uint256 lotteryState, bool hasPlayers);
    error Lottery__NoCommision();

    //** Type Declaration */
    enum LotteryState {
        OPEN,
        CALCULATING
    }

    //** State Varibales */
    uint16 private constant REQUEST_CONFIRMATIONS = 3; // Minimum
    uint32 private constant NUM_WORDS = 1;

    address private immutable i_owner;
    uint256 private immutable i_costOfATicket;
    uint256 private s_roundCount;
    uint256 private s_poolBalance;
    uint256 private s_commissionBalance;
    uint256 private immutable i_commisionRate;
    uint256 private immutable i_interval;

    VRFCoordinatorV2Interface private immutable i_vrfCoordinator;
    bytes32 private immutable i_gasLane;
    uint64 private immutable i_subscriptionId;
    uint32 private immutable i_callbackGasLimit;
    LotteryState private s_lotteryState;
    uint256 private s_lastTimeStamp;
    bool private s_hasPlayers;

    IERC20 public rxctoken;

    mapping(uint256 => mapping(uint256 => address[])) private s_roundToSelectedNumToAddresses;
    mapping(uint256 => address[]) private s_roundToAllPlayers;
    mapping(uint256 => mapping(address => uint256[])) private s_roundToAddressToSelectedNumbers;
    mapping(uint256 => uint256) private s_roundToWinningNumer;

    //** Eevent */
    event PurchasedTicket(uint256 indexed round, address indexed player, uint256 indexed number);
    event DrawnLuckyNumber(uint256 indexed round, uint256 indexed luckyNumber);
    event SentPrizeToWinners(uint256 indexed round, address[] indexed winners, uint256 indexed prize);
    event ThisRoundNoWinners(uint256 indexed round);
    event RequestedRandomWords(uint256 indexed requestId);

    modifier onlyOwner() {
        if (msg.sender != i_owner) {
            revert Lottery__OnlyOwner();
        }
        _;
    }

    constructor(
        uint256 costOfATicket,
        uint256 commisionRate,
        uint256 interval,
        address vrfCoordinator,
        bytes32 gasLane,
        uint64 subscriptionId,
        uint32 callbackGasLimit,
        address rxctokenAddress  // Dodaj ovo kao novi parametar
    ) VRFConsumerBaseV2(vrfCoordinator) {
        i_costOfATicket = costOfATicket;
        i_commisionRate = commisionRate;
        i_interval = interval;

        i_vrfCoordinator = VRFCoordinatorV2Interface(vrfCoordinator);
        i_gasLane = gasLane;
        i_subscriptionId = subscriptionId;
        i_callbackGasLimit = callbackGasLimit;

        i_owner = msg.sender;
        s_roundCount = 1;
        s_lotteryState = LotteryState.OPEN;
        s_lastTimeStamp = block.timestamp;

        rxctoken = IERC20(rxctokenAddress);  // Inicijalizacija RXCG tokena
    }

    function buyTicket(uint256 number) public {
        if (s_lotteryState != LotteryState.OPEN) {
            revert Lottery__NotOpen();
        }
        if (number < 1 || number > 99) {
            revert Lottery__MustBetween1And99();
        }
        if (rxctoken.balanceOf(msg.sender) < i_costOfATicket) {
            revert Lottery__NotEnoughTokensSent();
        }
        s_hasPlayers = true;
        s_roundToSelectedNumToAddresses[s_roundCount][number].push(msg.sender);
        s_roundToAddressToSelectedNumbers[s_roundCount][msg.sender].push(number);
        s_roundToAllPlayers[s_roundCount].push(msg.sender);

        uint256 commision = (i_costOfATicket * i_commisionRate) / 100;
        s_commissionBalance += commision;
        s_poolBalance += (i_costOfATicket - commision);

        require(rxctoken.transferFrom(msg.sender, address(this), i_costOfATicket), "Token transfer failed");

        emit PurchasedTicket(s_roundCount, msg.sender, number);
    }

    function checkUpkeep(bytes memory /* checkData */ )
        public
        view
        override
        returns (bool upkeepNeeded, bytes memory /* performData */ )
    {
        bool timeHasPassed = (block.timestamp - s_lastTimeStamp) >= i_interval;
        bool isOpen = s_lotteryState == LotteryState.OPEN;
        bool hasBalance = s_poolBalance > 0;

        upkeepNeeded = (timeHasPassed && isOpen && s_hasPlayers && hasBalance);
        return (upkeepNeeded, "0x0");
    }

    function performUpkeep(bytes calldata /* performData */ ) external override {
        (bool upkeepNeeded,) = checkUpkeep("");
        if (!upkeepNeeded) {
            revert Lottery__UpkeepNotNeeded((block.timestamp - s_lastTimeStamp), uint256(s_lotteryState), s_hasPlayers);
        }

        s_lotteryState = LotteryState.CALCULATING;

        uint256 requestId = i_vrfCoordinator.requestRandomWords(
            i_gasLane,
            i_subscriptionId,
            REQUEST_CONFIRMATIONS,
            i_callbackGasLimit,
            NUM_WORDS
        );
        emit RequestedRandomWords(requestId);
    }

    function fulfillRandomWords(uint256, /* requestId */ uint256[] memory randomWords) internal override {
        uint256 luckyNumber = (randomWords[0] % 99) + 1;
        emit DrawnLuckyNumber(s_roundCount, luckyNumber);
        s_roundToWinningNumer[s_roundCount] = luckyNumber;

        s_lotteryState = LotteryState.OPEN;
        s_lastTimeStamp = block.timestamp;
        s_hasPlayers = false;
        uint256 numOfWinners = s_roundToSelectedNumToAddresses[s_roundCount][luckyNumber].length;
        if (numOfWinners > 0) {
            uint256 prize = s_poolBalance / numOfWinners;
            address[] memory winners = s_roundToSelectedNumToAddresses[s_roundCount][luckyNumber];

            for (uint256 i = 0; i < numOfWinners; i++) {
                address winner = winners[i];
                require(rxctoken.transfer(winner, prize), "Token transfer to winner failed");
            }
            s_poolBalance = 0;

            emit SentPrizeToWinners(s_roundCount, winners, prize);
        } else {
            emit ThisRoundNoWinners(s_roundCount);
        }

        s_roundCount++;
    }

    function withdrawCommision() external onlyOwner {
        if (s_commissionBalance <= 0) {
            revert Lottery__NoCommision();
        }
        require(rxctoken.transfer(i_owner, s_commissionBalance), "Token transfer failed");
        s_commissionBalance = 0;
    }

    //** Getter functions */
    function getRoundToSelectedNumToAddresses(uint256 round, uint256 number) external view returns (address[] memory) {
        return s_roundToSelectedNumToAddresses[round][number];
    }

    function getRoundToAddressToSelectedNumbers(uint256 round, address player)
        external
        view
        returns (uint256[] memory)
    {
        return s_roundToAddressToSelectedNumbers[round][player];
    }

    function getRoundToWinningNumber(uint256 round) external view returns (uint256) {
        return s_roundToWinningNumer[round];
    }

    function getRoundToAllPlayers(uint256 round) external view returns (address[] memory) {
        return s_roundToAllPlayers[round];
    }

    function getPoolBalance() external view returns (uint256) {
        return s_poolBalance;
    }

    function getCommisionBalance() external view returns (uint256) {
        return s_commissionBalance;
    }

    function getTimeLeftToDraw() external view returns (uint256) {
        require((s_lastTimeStamp + i_interval) > block.timestamp, "Now is time to draw!");
        return ((s_lastTimeStamp + i_interval) - block.timestamp);
    }

    function getLotteryState() external view returns (LotteryState) {
        return s_lotteryState;
    }

    function getHasPlayers() external view returns (bool) {
        return s_hasPlayers;
    }

    function getLastTimeStamp() external view returns (uint256) {
        return s_lastTimeStamp;
    }

    function getRoundCount() external view returns (uint256) {
        return s_roundCount;
    }

    function getOwner() external view returns (address) {
        return i_owner;
    }

    function getCostOfTicket() external view returns (uint256) {
        return i_costOfATicket;
    }
}
