// SPDX-License-Identifier: UNLICENSED

// Pragma statements
// ------------------------------------
pragma solidity ^0.8.10;

// Import statements
// ------------------------------------
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./IPancakeFactory.sol";
import "./IPancakeRouter02.sol";
import "./IPancakePair.sol";

// ~~~~~~~~~~~~~~ Contract ~~~~~~~~~~~~~~
//
contract Launchpad is Ownable, ReentrancyGuard {
    address constant private PANCAKE_FACTORY =
        0x6725F303b657a9451d8BA641348b6761A6CC7a17;
    address constant private PANCAKE_ROUTER =
        0xD99D1c33F9fC3444f8101754aBC46c52416550D1;
    uint256 public immutable decimals = 10**18;
    uint256 public immutable USDT_PERCENTAGE_FOR_LP;
    IERC20 public immutable IUSDT; //ERC20 needed to buy this projectToken
    IERC20 public immutable IPROJECT_TOKEN; //ERC20 of the project
    uint256 public s_projectPrice; //price in _USDT token
    uint256 public s_projectSupply; //Initial supply of the project Token
    uint256 public s_minimumAmountToPurchase; //minimum quantity of tokens the users can buy
    bool public s_isActive;
    uint256 public s_ProjectTokenAmountForLP; //amount of projectTokens that will be sent to the LP
    address[] private s_partners;
    uint256[] private s_shares;
    mapping(address => uint256) public s_tokensPurchased;

    // ~~~~~~~~~~~~~~ Events ~~~~~~~~~~~~~~
    //

    event RoundFinished(uint256 time, uint256 collectedAmount);
    event TokensBought(address indexed buyer, IERC20 usdt,uint256 amountUsdt, IERC20 projectToken, uint256 amountProjectToken);
    event SupplyAddedForLaunchpad(address from, uint256 amount);
    event SupplyAddedForLP(address from, uint256 amount);
    event SupplyReduced(address to, uint256 amount);

    // ~~~~~~~~~~~~~~ Functions ~~~~~~~~~~~~~~
    //
    constructor(
        uint256 percentageForLP_,
        IERC20 USDT_,
        IERC20 projectToken_,
        uint256 projectPrice_,
        uint256 minAmountToPurchase_,
        address[] memory payees_,
        uint256[] memory shares_
    ) {
        USDT_PERCENTAGE_FOR_LP = percentageForLP_;
        IUSDT = USDT_;
        IPROJECT_TOKEN = projectToken_;
        s_projectPrice = projectPrice_;
        s_minimumAmountToPurchase = minAmountToPurchase_ * decimals;
        s_isActive = true;
        s_partners = payees_;
        s_shares = shares_;
        uint256 totalShares = 0;
        for(uint i=0; i<shares_.length;++i){
            totalShares+= shares_[i];
        }
        require(totalShares == 100, "Launchpad, please set 100 shares");
    }

    /*
        finishRound() onlyowner
        * Function to close the round for this project
        * 1. close the round, updating state variables
        * 2. first create the LP
        * 3. secondly, add liquidity to the pool
        * 2. call _distributeFunds() and require to return true
        * 3. emit event
    */

    function finishRound() external onlyOwner {
        require(s_isActive, "Launchpad: Round is over.");
        s_isActive = false;
        uint256 collectedAmount = getCollectedUSDT();

        (address pair) = IPancakeFactory(PANCAKE_FACTORY).createPair(
            address(IUSDT),
            address(IPROJECT_TOKEN)
        );
        require(pair != address(0),"Launchpad: Failed creating liquidity pool pair");

        require(_addLiquidityToLP());

        require(_distributeFunds(), "Launchpad: Unable to send funds.");
        emit RoundFinished(block.timestamp, collectedAmount);
    }
    
    function _addLiquidityToLP() internal returns(bool){
        uint256 collectedAmount = getCollectedUSDT();
        uint256 amountUSDTForLP = (collectedAmount *  USDT_PERCENTAGE_FOR_LP) / 100;
        uint256 amountProjectTokenForLP = s_ProjectTokenAmountForLP;
        require(amountProjectTokenForLP > 0, "Launchpad: There are not tokens for the Liquidity Pool"); 
        
        IUSDT.approve(PANCAKE_ROUTER, amountUSDTForLP);
        IPROJECT_TOKEN.approve(PANCAKE_ROUTER, amountProjectTokenForLP);

        (, , uint256 liquidity) = IPancakeRouter02(PANCAKE_ROUTER).addLiquidity(
            address(IUSDT),
            address(IPROJECT_TOKEN),
            amountUSDTForLP,
            amountProjectTokenForLP,
            amountUSDTForLP,
            amountProjectTokenForLP,
            owner(),
            block.timestamp + 10 minutes);
        require(liquidity > 0, "Launchpad: Failed adding liquidity to the LP");
        //require(IPancakePair(pair_).balanceOf(owner()) > 0, "Launchpad: Balance of owner for LP should be greater than 0");
        return true;
    }

    /*
        addSupply() 
        1. FRONTEND: from_ address must approve tokens first & decimals
        2. execute transferFrom to this contract to add projectToken
        3. update projectSupply variable
        4. emit event
    */
    function addSupplyToSell(address from_, uint256 amount_) external onlyOwner {
        require(
            IPROJECT_TOKEN.transferFrom(from_, address(this), amount_ * decimals),
            "Launchpad: Failed adding supply"
        );
        s_projectSupply += amount_ * decimals;
        emit SupplyAddedForLaunchpad(from_, amount_ * decimals);
    }
    
    function addSupplyForLP(address from_, uint256 amount_) external onlyOwner {
        require(
            IPROJECT_TOKEN.transferFrom(from_, address(this), amount_ * decimals),
            "Launchpad: Failed adding supply"
        );
        s_ProjectTokenAmountForLP += amount_ * decimals;
        emit SupplyAddedForLaunchpad(from_, amount_ * decimals);
    }

    /*
        reduceSupply()
        1. send tokens from this contract to to_
        2. update projectSupply variable
    */
    function reduceSupply(address to_, uint256 amount_) external onlyOwner {
        require(
            IPROJECT_TOKEN.transfer(to_, amount_),
            "Failed transfering the tokens"
        );
        s_projectSupply -= amount_;
        emit SupplyReduced(to_, amount_);
    }

    /*
        buyTokens() public
        * 1. FRONTEND: Approve() tokens from the msg.sender & decimals
        * 2. require isActive & there is enough supply.
        * 3. calculate the total amount of USDT to transferFrom msg.sender
        * 4. update state variables
        * 4. transferFrom() USDT from msg.sender to this contract
        * 5. transfer() projectTokens to the user
    */
    function buyTokens(uint256 amountToBuy_)
        external
        nonReentrant
        returns (bool)
    {
        uint256 minAmountToBuy = s_minimumAmountToPurchase * s_projectPrice;
        require(s_isActive, "Launchapad: Round is over");
        require(
            minAmountToBuy <= amountToBuy_ * decimals,
            "Launchpad: Amount is less than the minimum amount you may purchase"
        );
        require(
            s_projectSupply >= amountToBuy_ * decimals,
            "Launchpad: Not enough supply"
        );
        address sender = msg.sender;
        uint256 amountUSDT = amountToBuy_ * s_projectPrice;
        s_projectSupply -= amountToBuy_ * decimals;
        s_tokensPurchased[sender] += amountToBuy_ * decimals;
        require(
            IUSDT.transferFrom(
                sender,
                address(this),
                amountUSDT
            ),
            "Launchpad: Failed transfering USDT"
        );
        emit TokensBought(sender, IUSDT, amountUSDT, IPROJECT_TOKEN, amountToBuy_* decimals);
        return true;
    }


    function claimTokens() external nonReentrant {
        require(!s_isActive, "Launchpad: Please wait until the round is over");
        address sender = msg.sender;
        uint256 amountPurchasedByUser = s_tokensPurchased[sender];
        s_tokensPurchased[sender] = 0;
        require(
            amountPurchasedByUser > 0,
            "Launchpad: You did not purchase tokens"
        );
        require(
            IPROJECT_TOKEN.transfer(sender, amountPurchasedByUser),
            "Launchpad: Failed transfering projectToken to the user"
        );
    }

    function changePrice(uint256 newPrice_) external onlyOwner {
        s_projectPrice = newPrice_;
    }

    function pauseOrStartRound() external onlyOwner {
        s_isActive = !s_isActive;
    }

    function setMinimumAmountToPurchase(uint256 amount_) external onlyOwner {
        s_minimumAmountToPurchase = amount_;
    }

    //~~~~~~~~~~~~~~ Internal functions ~~~~~~~~~~~~~~

    /*
        _distributeFunds() internal
        * 1. copy in memory the partners length
        * 2. make a for loop to send the tokens
        * 3. return true
    */
    function _distributeFunds() internal returns (bool) {
        uint256 totalUSDTFunds = getCollectedUSDT();
        uint256 totalUSDTForLP = (totalUSDTFunds * USDT_PERCENTAGE_FOR_LP) / 100;
        uint256 totalUSDTForPartners = totalUSDTFunds - totalUSDTForLP;
        address[] memory partners = s_partners;
        uint256[] memory shares = s_shares;
        uint256 partnersLength = partners.length;
        
        for (uint256 i = 0; i < partnersLength;) {
            uint256 amountForPartnerI = (totalUSDTForPartners * shares[i]) / 100;
            IUSDT.transfer(partners[i], amountForPartnerI);
            unchecked {
                i++;
            }
        }
        return true;
    }

    //~~~~~~~~~~~~~~ View/Pure functions ~~~~~~~~~~~~~~

    function getCollectedUSDT() public view returns(uint256){
        return IUSDT.balanceOf(address(this));
    }

}
