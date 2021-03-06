// SPDX-License-Identifier: GNU GPLv3
pragma solidity ^0.8.4;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "contracts/staking/StakedEthAndTokenHolder.sol";
import "contracts/interfaces/IStrategy.sol";
import "contracts/interfaces/IRouter.sol";
import "contracts/interfaces/IPair.sol";
import "contracts/interfaces/IMiniChefV2.sol";


contract USDCETHStrategy is ERC20, Ownable, IStrategy {

  uint public totalDeposits;

  IERC20 public arbi;
  IRouter public router;
  IPair public depositToken;
  IERC20 public token0;
  IERC20 public token1;
  IERC20 public rewardToken;
  IMiniChefV2 public stakingContract;
  uint256 public pid;

  uint public MIN_TOKENS_TO_REINVEST = 10000;
  uint public REINVEST_REWARD_BIPS = 300;
  uint public ADMIN_FEE_BIPS = 50;
  uint constant private BIPS_DIVISOR = 10000;

  bool public REQUIRE_REINVEST_BEFORE_DEPOSIT;
  uint public MIN_TOKENS_TO_REINVEST_BEFORE_DEPOSIT = 20;

  event Deposit(address indexed account, uint amount);
  event Withdraw(address indexed account, uint amount);
  event Reinvest(uint newTotalDeposits, uint newTotalSupply);
  event Recovered(address token, uint amount);
  event UpdateAdminFee(uint oldValue, uint newValue);
  event UpdateReinvestReward(uint oldValue, uint newValue);
  event UpdateMinTokensToReinvest(uint oldValue, uint newValue);
  event UpdateRequireReinvestBeforeDeposit(bool newValue);
  event UpdateMinTokensToReinvestBeforeDeposit(uint oldValue, uint newValue);

  constructor() ERC20("USDC/ETH ARBI Shares", "USDC/ETH-SHARES") {
    depositToken = IPair(0x905dfCD5649217c42684f23958568e533C711Aa3);
    rewardToken = IERC20(0xd4d42F0b6DEF4CE0383636770eF773390d85c61A);
    stakingContract = IMiniChefV2(0xF4d73326C13a4Fc5FD7A064217e12780e9Bd62c3);
    router = IRouter(0x1b02dA8Cb0d097eB8D57A175b88c7D8b47997506);
    pid = 0;

    address _token0 = IPair(0x905dfCD5649217c42684f23958568e533C711Aa3).token0();
    address _token1 = IPair(0x905dfCD5649217c42684f23958568e533C711Aa3).token1();
    token0 = IERC20(_token0);
    token1 = IERC20(_token1);

    setAllowances();
    emit Reinvest(0, 0);
  }

  /**
    * @dev Throws if called by smart contract
    */
  modifier onlyEOA() {
      require(tx.origin == msg.sender, "onlyEOA");
      _;
  }
  
  function setArbi(address arbiAddress) public onlyOwner {
      require(address(arbi) == 0x0000000000000000000000000000000000000000, "arbi already set");
      arbi = IERC20(arbiAddress);
  }

  /**
   * @notice Approve tokens for use in Strategy
   * @dev Restricted to avoid griefing attacks
   */
  function setAllowances() public onlyOwner {
    depositToken.approve(address(stakingContract), depositToken.totalSupply());
    rewardToken.approve(address(stakingContract), rewardToken.totalSupply());
    token0.approve(address(stakingContract), token0.totalSupply());
    token1.approve(address(stakingContract), token1.totalSupply());
    depositToken.approve(address(stakingContract), depositToken.totalSupply());
    rewardToken.approve(address(router), rewardToken.totalSupply());
    token0.approve(address(router), token0.totalSupply());
    token1.approve(address(router), token1.totalSupply());
  }

  /**
    * @notice Revoke token allowance
    * @dev Restricted to avoid griefing attacks
    * @param token address
    * @param spender address
    */
  function revokeAllowance(address token, address spender) external onlyOwner {
    require(IERC20(token).approve(spender, 0));
  }

  /**
   * @notice Deposit tokens to receive receipt tokens
   * @param amount Amount of tokens to deposit
   */
  function deposit(uint amount) override external {
    _deposit(amount);
  }

  function _deposit(uint amount) internal {
    require(totalDeposits >= totalSupply(), "deposit failed");
    if (REQUIRE_REINVEST_BEFORE_DEPOSIT) {
      uint unclaimedRewards = checkReward();
      if (unclaimedRewards >= MIN_TOKENS_TO_REINVEST_BEFORE_DEPOSIT) {
        _reinvest(unclaimedRewards);
      }
    }
    require(depositToken.transferFrom(msg.sender, address(this), amount), "transferFrom failed");
    _stakeDepositTokens(amount);
    _mint(msg.sender, getSharesForDepositTokens(amount));
    totalDeposits = totalDeposits + amount;
    emit Deposit(msg.sender, amount);
  }

  /**
   * @notice Withdraw LP tokens by redeeming receipt tokens
   * @param amount Amount of receipt tokens to redeem
   */
  function withdraw(uint amount) override external {
    uint depositTokenAmount = getDepositTokensForShares(amount);
    if (depositTokenAmount > 0) {
      _withdrawDepositTokens(depositTokenAmount);
      require(depositToken.transfer(msg.sender, depositTokenAmount), "transfer failed");
      _burn(msg.sender, amount);
      totalDeposits = totalDeposits - depositTokenAmount;
      emit Withdraw(msg.sender, depositTokenAmount);
    }
  }

  /**
   * @notice Calculate receipt tokens for a given amount of deposit tokens
   * @dev If contract is empty, use 1:1 ratio
   * @dev Could return zero shares for very low amounts of deposit tokens
   * @param amount deposit tokens
   * @return receipt tokens
   */
  function getSharesForDepositTokens(uint amount) public view returns (uint) {
    if ((totalSupply() * totalDeposits) == 0) {
      return amount;
    }
    return (amount * totalSupply()) / totalDeposits;
  }

  /**
   * @notice Calculate deposit tokens for a given amount of receipt tokens
   * @param amount receipt tokens
   * @return deposit tokens
   */
  function getDepositTokensForShares(uint amount) public view returns (uint) {
    if ((totalSupply() * totalDeposits) == 0) {
      return 0;
    }
    return (amount * totalDeposits) / totalSupply();
  }

  /**
   * @notice Reward token balance that can be reinvested
   * @dev Staking rewards accurue to contract on each deposit/withdrawal
   * @return Unclaimed rewards, plus contract balance
   */
  function checkReward() public view returns (uint) {
    uint pendingReward = stakingContract.pendingSushi(pid, address(this));
    uint contractBalance = rewardToken.balanceOf(address(this));
    return pendingReward + contractBalance;
  }

  /**
   * @notice Estimate reinvest reward for caller
   * @return Estimated rewards tokens earned for calling `reinvest()`
   */
  function estimateReinvestReward() external view returns (uint) {
    uint unclaimedRewards = checkReward();
    if (unclaimedRewards >= MIN_TOKENS_TO_REINVEST) {
      return (unclaimedRewards * REINVEST_REWARD_BIPS) / BIPS_DIVISOR;
    }
    return 0;
  }

  /**
   * @notice Reinvest rewards from staking contract to deposit tokens
   * @dev This external function requires minimum tokens to be met
   */
  function reinvest() override external onlyEOA {
    uint unclaimedRewards = checkReward();
    require(unclaimedRewards >= MIN_TOKENS_TO_REINVEST, "MIN_TOKENS_TO_REINVEST");
     if (address(arbi) != 0x0000000000000000000000000000000000000000) {
        require(arbi.balanceOf(msg.sender) >= 69000000000000000000, "insufficent ARBI balance");
    }
    _reinvest(unclaimedRewards);
  }

  /**
   * @notice Reinvest rewards from staking contract to deposit tokens
   * @dev This internal function does not require mininmum tokens to be met
   */
  function _reinvest(uint amount) internal {
    stakingContract.harvest(pid, address(this));

    uint adminFee = (amount * ADMIN_FEE_BIPS) / BIPS_DIVISOR;
    if (adminFee > 0) {
      require(rewardToken.transfer(owner(), adminFee), "admin fee transfer failed");
    }

    uint reinvestFee = (amount * REINVEST_REWARD_BIPS) / BIPS_DIVISOR;
    if (reinvestFee > 0) {
      require(rewardToken.transfer(msg.sender, reinvestFee), "reinvest fee transfer failed");
    }

    uint lpTokenAmount = _convertRewardTokensToDepositTokens((amount - adminFee) - reinvestFee);
    _stakeDepositTokens(lpTokenAmount);
    totalDeposits = totalDeposits + lpTokenAmount;

    emit Reinvest(totalDeposits, totalSupply());
  }

  /**
   * @notice Converts entire reward token balance to deposit tokens
   * @dev Always converts through router; there are no price checks enabled
   * @return deposit tokens received
   */
  function _convertRewardTokensToDepositTokens(uint amount) internal returns (uint) {
    uint amountIn = amount / 2;
    require(amountIn > 0, "amount too low");

    // swap to token0
    address[] memory path0 = new address[](3);
    path0[0] = address(rewardToken);
    path0[1] = address(token0);
    path0[2] = address(token1);

    uint amountOutToken0 = amountIn;
    if (path0[0] != path0[path0.length - 1]) {
      uint[] memory amountsOutToken0 = router.getAmountsOut(amountIn, path0);
      amountOutToken0 = amountsOutToken0[amountsOutToken0.length - 1];
      router.swapExactTokensForTokens(amountIn, amountOutToken0, path0, address(this), block.timestamp);
    }

    // swap to token1 
    address[] memory path1 = new address[](3);
    path1[0] = path0[0];
    path1[1] = address(token1);
    path1[2] = address(token0);

    uint amountOutToken1 = amountIn;
   if (path1[0] != path1[path1.length - 1]) {
     uint[] memory amountsOutToken1 = router.getAmountsOut(amountIn, path1);
      amountOutToken1 = amountsOutToken1[amountsOutToken1.length - 2];
      router.swapExactTokensForTokens(amountIn, amountOutToken1, path1, address(this), block.timestamp);
    }

    (,,uint liquidity) = router.addLiquidity(
      path0[path0.length - 1], address(rewardToken),
      amountOutToken0, amountOutToken1,
      0, 0,
      address(this),
      block.timestamp
    );

    return liquidity;
  }

  /**
   * @notice Stakes deposit tokens in Staking Contract
   * @param amount deposit tokens to stake
   */
  function _stakeDepositTokens(uint amount) internal {
    require(amount > 0, "amount too low");
    stakingContract.deposit(pid, uint128(amount), address(this));
  }

  /**
   * @notice Withdraws deposit tokens from Staking Contract
   * @dev Reward tokens are automatically collected
   * @dev Reward tokens are not automatically reinvested
   * @param amount deposit tokens to remove
   */
  function _withdrawDepositTokens(uint amount) internal {
    require(amount > 0, "amount too low");
    stakingContract.withdraw(pid, uint128(amount), address(this));
  }

  /**
   * @notice Update reinvest minimum threshold for external callers
   * @param newValue min threshold in wei
   */
  function updateMinTokensToReinvest(uint newValue) external onlyOwner {
    emit UpdateMinTokensToReinvest(MIN_TOKENS_TO_REINVEST, newValue);
    MIN_TOKENS_TO_REINVEST = newValue;
  }

  /**
   * @notice Update admin fee
   * @dev Total fees cannot be greater than BIPS_DIVISOR (max 5%)
   * @param newValue specified in BIPS
   */
  function updateAdminFee(uint newValue) external onlyOwner {
    require(newValue + REINVEST_REWARD_BIPS <= BIPS_DIVISOR / 20, "admin fee too high");
    emit UpdateAdminFee(ADMIN_FEE_BIPS, newValue);
    ADMIN_FEE_BIPS = newValue;
  }

  /**
   * @notice Update reinvest reward
   * @dev Total fees cannot be greater than BIPS_DIVISOR (max 5%)
   * @param newValue specified in BIPS
   */
  function updateReinvestReward(uint newValue) external onlyOwner {
    require(newValue + ADMIN_FEE_BIPS <= BIPS_DIVISOR / 20, "reinvest reward too high");
    emit UpdateReinvestReward(REINVEST_REWARD_BIPS, newValue);
    REINVEST_REWARD_BIPS = newValue;
  }

  /**
   * @notice Toggle requirement to reinvest before deposit
   */
  function updateRequireReinvestBeforeDeposit() external onlyOwner {
    REQUIRE_REINVEST_BEFORE_DEPOSIT = !REQUIRE_REINVEST_BEFORE_DEPOSIT;
    emit UpdateRequireReinvestBeforeDeposit(REQUIRE_REINVEST_BEFORE_DEPOSIT);
  }

  /**
   * @notice Update reinvest minimum threshold before a deposit
   * @param newValue min threshold in wei
   */
  function updateMinTokensToReinvestBeforeDeposit(uint newValue) external onlyOwner {
    emit UpdateMinTokensToReinvestBeforeDeposit(MIN_TOKENS_TO_REINVEST_BEFORE_DEPOSIT, newValue);
    MIN_TOKENS_TO_REINVEST_BEFORE_DEPOSIT = newValue;
  }


  /**
   * @notice Recover ether from contract (should never be any in it)
   * @param amount amount
   */
  function recoverETH(uint amount) external onlyOwner {
    require(amount > 0, "amount too low");
    payable(msg.sender).transfer(amount);
    emit Recovered(address(0), amount);
  }

  function getName() override external view returns(string memory) {
    return name();
  }

  function getUnderlying() override external view returns (address) {
    return address(depositToken);
  }
}
