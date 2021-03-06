// SPDX-License-Identifier: GNU GPLv3
pragma solidity ^0.8.4;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "contracts/staking/StakedEthAndTokenHolder.sol";
import "contracts/strategies/nyan/NyanRewards.sol";
import "contracts/interfaces/IStrategy.sol";


contract NyanStrategy is ERC20, IStrategy {
  
  address private _admin;

  uint public totalDeposits;

  IERC20 public arbi;
  IERC20 public nyanToken;
  NyanRewards public stakingContract;

  uint public MIN_TOKENS_TO_REINVEST = 20;
  uint public REINVEST_REWARD_BIPS = 100;
  uint public ADMIN_FEE_BIPS = 50;
  uint constant private BIPS_DIVISOR = 10000;

  event Deposit(address account, uint amount);
  event Withdraw(address account, uint amount);
  event Reinvest(uint newTotalDeposits, uint newTotalSupply);
  event Recovered(address token, uint amount);
  event UpdateAdminFee(uint oldValue, uint newValue);
  event UpdateReinvestReward(uint oldValue, uint newValue);
  event UpdateMinTokensToReinvest(uint oldValue, uint newValue);

  constructor(
    address _nyanToken, 
    address _stakingContract
  ) ERC20("NYAN Stake Shares", "NYAN-SHARES"){
    _admin = msg.sender;
    nyanToken = IERC20(_nyanToken);
    stakingContract = NyanRewards(_stakingContract);
    uint256 ts = nyanToken.totalSupply();
    nyanToken.approve(_stakingContract, ts);
  }
  
  function reapproveStaking() public {
    uint256 ts = nyanToken.totalSupply();
    nyanToken.approve(address(stakingContract), ts);
  }
  
  function getName() external override view returns(string memory) {
      return name();
  }
  
  function getUnderlying() external override view returns(address) {
      return address(nyanToken);
  }
  
  function updateAdmin(address newAdmin) public onlyAdmin {
      _admin = newAdmin;
  }
  
  function setArbi(address arbiAddress) public onlyAdmin {
      require(address(arbi) == 0x0000000000000000000000000000000000000000, "arbi already set");
      arbi = IERC20(arbiAddress);
  }
  
  modifier onlyAdmin() {
      require(msg.sender == _admin, "onlyadmin");
      _;
  }
  
  function admin() public view returns (address payable) {
      return payable(_admin);
  }

  /**
    * @dev Throws if called by smart contract
    */
  modifier onlyEOA() {
      require(tx.origin == msg.sender, "onlyEOA");
      _;
  }

  /**
   * @notice Deposit LP tokens to receive Snowball tokens
   * @param amount Amount of LP tokens to deposit
   */
  function deposit(uint amount) override external {
    _deposit(amount);
  }


  function _deposit(uint amount) internal {
    require(totalDeposits >= totalSupply(), "deposit failed");
    require(nyanToken.transferFrom(msg.sender, address(this), amount), "transferFrom failed");
    _stakeTokens(amount);
    _mint(msg.sender, getSharesPerToken(amount));
    totalDeposits = totalDeposits + amount;
    emit Deposit(msg.sender, amount);
  }

  /**
   * @notice Withdraw LP tokens by redeeming Snowball tokens
   * @param amount Amount of Snowball tokens to redeem
   */
  function withdraw(uint amount) override external {
    uint lpTokenAmount = getTokensPerShare(amount);
    if (lpTokenAmount > 0) {
      _withdrawStakedTokens(lpTokenAmount);
      require(nyanToken.transfer(msg.sender, lpTokenAmount), "transfer failed");
      _burn(msg.sender, amount);
      totalDeposits = totalDeposits - lpTokenAmount;
      emit Withdraw(msg.sender, lpTokenAmount);
    }
  }

  /**
   * @notice Calculate Shares per staked NYAN token
   * @dev If contract is empty, use 1:1 ratio
   * @dev Could return zero shares for very low amounts of LP tokens
   * @param amount LP tokens
   * @return share tokens
   */
  function getSharesPerToken(uint amount) public view returns (uint) {
    if (totalSupply() * totalDeposits == 0) {
      return amount;
    }
    return (amount * totalSupply()) / totalDeposits;
  }

  /**
   * @notice Calculate nyan tokens for a given amount of share tokens
   * @param amount NYAN tokens
   * @return share tokens
   */
  function getTokensPerShare(uint amount) public view returns (uint) {
    if (totalSupply() * totalDeposits == 0) {
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
    return stakingContract.earned(address(this));
    //uint contractBalance = rewardToken.balanceOf(address(this));
    //return pendingReward + contractBalance;
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
   * @notice Reinvest rewards from staking contract to LP tokens
   */
  function reinvest() override external onlyEOA {
    uint unclaimedRewards = checkReward();
    require(unclaimedRewards >= MIN_TOKENS_TO_REINVEST, "MIN_TOKENS_TO_REINVEST");
    
    if (address(arbi) != 0x0000000000000000000000000000000000000000) {
        require(arbi.balanceOf(msg.sender) >= 69000000000000000000, "insufficent ARBI balance");
    }
    
    stakingContract.getReward();
    uint adminFee = (unclaimedRewards * ADMIN_FEE_BIPS) / BIPS_DIVISOR;
    if (adminFee > 0) {
      require(nyanToken.transfer(admin(), adminFee), "admin fee transfer failed");
    }

    uint reinvestFee = (unclaimedRewards * REINVEST_REWARD_BIPS) / BIPS_DIVISOR;
    if (reinvestFee > 0) {
      require(nyanToken.transfer(msg.sender, reinvestFee), "reinvest fee transfer failed");
    }
    
    uint256 restaking = nyanToken.balanceOf(address(this));
    _stakeTokens(restaking);

    totalDeposits = totalDeposits + restaking;

    emit Reinvest(totalDeposits, totalSupply());
  }

  /**
   * @notice Stakes tokens in Staking Contract
   * @param amount tokens to stake
   */
  function _stakeTokens(uint amount) internal {
    require(amount > 0, "amount too low");
    stakingContract.stake(uint128(amount));
  }

  /**
   * @notice Withdraws LP tokens from Staking Contract
   * @dev Rewards are not automatically collected from the Staking Contract
   * @param amount LP tokens to remove;
   */
  function _withdrawStakedTokens(uint amount) internal {
    require(amount > 0, "amount too low");
    stakingContract.withdraw( uint128(amount));
  }


  /**
   * @notice Update reinvest minimum threshold
   * @param newValue min threshold in wei
   */
  function updateMinTokensToReinvest(uint newValue) external onlyAdmin {
    emit UpdateMinTokensToReinvest(MIN_TOKENS_TO_REINVEST, newValue);
    MIN_TOKENS_TO_REINVEST = newValue;
  }

  /**
   * @notice Update admin fee
   * @dev Total fees cannot be greater than BIPS_DIVISOR (5% max)
   * @param newValue specified in BIPS
   */
  function updateAdminFee(uint newValue) external onlyAdmin {
    require(newValue + REINVEST_REWARD_BIPS <= BIPS_DIVISOR / 20, "admin fee too high");
    emit UpdateAdminFee(ADMIN_FEE_BIPS, newValue);
    ADMIN_FEE_BIPS = newValue;
  }

  /**
   * @notice Update reinvest reward
   * @dev Total fees cannot be greater than BIPS_DIVISOR (5% max)
   * @param newValue specified in BIPS
   */
  function updateReinvestReward(uint newValue) external onlyAdmin {
    require(newValue + ADMIN_FEE_BIPS <= BIPS_DIVISOR / 20, "reinvest reward too high");
    emit UpdateReinvestReward(REINVEST_REWARD_BIPS, newValue);
    REINVEST_REWARD_BIPS = newValue;
  }

  /**
   * @notice Recover ETH from contract (there should never be any in this contract)
   * @param amount amount
   */
  function recoverETH(uint amount) external onlyAdmin {
    require(amount > 0, 'amount too low');
    admin().transfer(amount);
    emit Recovered(address(0), amount);
  }
}