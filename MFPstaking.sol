// SPDX-License-Identifier: MIT
// Creator: andreitoma8
pragma solidity ^0.8.4;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

contract MFPStaking is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // Interfaces for ERC20 and ERC721
    IERC20 public immutable mfpToken;
    IERC721 public immutable mfpNFT;

    // Staker info
    struct Staker {
        // Last time of details update for this User
        uint256 timeOfLastUpdate;
        // Calculated, but unclaimed rewards for the User. The rewards are
        // calculated each time the user writes to the Smart Contract
        uint256 unclaimedRewards;
        //Ids of ERC721 Tokens staked and length of array holds total number of tokens staked
        uint256[] stakedTokens;
    }

    // Rewards per hour per token deposited in wei.
    // Rewards are cumulated once every hour.
    uint256 private rewardsPerHour = 100000;

    // Mapping of User Address to Staker info
    mapping(address => Staker) public stakers;
    // Mapping of Token Id to staker. Made for the SC to remeber
    // who to send back the ERC721 Token to.

    // Constructor function
    constructor(IERC721 _mfpNFT, IERC20 _mfpToken) {
        mfpNFT = _mfpNFT;
        mfpToken = _mfpToken;
    }

    // If address already has ERC721 Token/s staked, calculate the rewards.
    // For every new Token Id in param transferFrom user to this Smart Contract,
    // increment the amountStaked and map msg.sender to the Token Id of the staked
    // Token to later send back on withdrawal. Finally give timeOfLastUpdate the
    // value of now.
    function stake(uint256[] calldata _tokenIds) external nonReentrant {
    	address _sender=msg.sender;
        if (stakers[_sender].stakedTokens.length > 0) {
            uint256 rewards = calculateRewards(_sender);
            stakers[_sender].unclaimedRewards += rewards;
        } 
	
        uint256 len = _tokenIds.length;
        for (uint256 i; i < len; ++i) {
            require(
                mfpNFT.ownerOf(_tokenIds[i]) == _sender,
                "Can't stake tokens you don't own!"
            );
            ensureApproval(_sender);
            mfpNFT.transferFrom(_sender, address(this), _tokenIds[i]);
            stakers[_sender].stakedTokens.push(_tokenIds[i]);
        }
        stakers[_sender].timeOfLastUpdate = block.timestamp;
    }

    // Check if user has any ERC721 Tokens Staked and if he tried to withdraw,
    // calculate the rewards and store them in the unclaimedRewards and for each
    // ERC721 Token in param: check if msg.sender is the original stake, attempt to pop the token Id from the  stalkers.stakedTokens and transfer the ERC721 token back to them
    function withdraw(uint256[] calldata _tokenIds) external nonReentrant payable{
    	address _sender=msg.sender;
        require(
            stakers[_sender].stakedTokens.length > 0,
            "You have no tokens staked"
        );
        uint256 rewards = calculateRewards(_sender);
        stakers[_sender].unclaimedRewards += rewards;
        uint256 len = _tokenIds.length;
        for (uint256 i; i < len; ++i) {
        	int256 tokenStakeIndex=getTokenStakeIndex(_sender,_tokenIds[i]);
            require(tokenStakeIndex>=0, 'Can only withdraw own staked tokens');
            popStakedToken(_sender,uint256(tokenStakeIndex));
			attemptDeleteStaker(_sender);
            mfpNFT.transferFrom(address(this), _sender, _tokenIds[i]);
        }
        stakers[_sender].timeOfLastUpdate = block.timestamp;
    }

    // Calculate rewards for the msg.sender, check if there are any rewards
    // claim, set unclaimedRewards to 0 and transfer the ERC20 Reward token
    // to the user.
    function claimRewards() external payable{
    		address _sender=msg.sender;
        uint256 rewards = calculateRewards(_sender) +
            stakers[_sender].unclaimedRewards;
        require(rewards > 0, "You have no rewards to claim");
        stakers[_sender].timeOfLastUpdate = block.timestamp;
        stakers[_sender].unclaimedRewards = 0;
        mfpToken.safeTransfer(_sender, rewards);
    }

    // Set the rewardsPerHour variable
    function setRewardsPerHour(uint256 _newValue) public onlyOwner {
        rewardsPerHour = _newValue;
    }

    //////////
    // View //
    //////////

    function userStakeInfo(address stake_address)
        public
        view
        returns (uint256[] memory tokensStaked, uint256 _availableRewards)
    {
    	require(stake_address!=address(0),'No info for zero address');
        return (stakers[stake_address].stakedTokens, availableRewards(stake_address));
    }

    function availableRewards(address stake_address) internal view returns (uint256) {
        if (stakers[stake_address].stakedTokens.length == 0) {
            return stakers[stake_address].unclaimedRewards;
        }
        uint256 _rewards = stakers[stake_address].unclaimedRewards +
            calculateRewards(stake_address);
        return _rewards;
    }

    /////////////
    // Internal//
    /////////////

    // Calculate rewards for param stake_address by calculating the time passed
    // since last update in hours and mulitplying it to ERC721 Tokens Staked
    // and rewardsPerHour.
    function calculateRewards(address stake_address)
        internal
        view
        returns (uint256 _rewards)
    {
        Staker memory staker = stakers[stake_address];
        return (((
            ((block.timestamp - staker.timeOfLastUpdate) * staker.stakedTokens.length)
        ) * rewardsPerHour) / 3600);
    }
    
    function getTokenStakeIndex(address stake_address, uint256 tokenId)
        internal view returns (int256){
		require(stake_address!=address(0) && tokenId>0 && stakers[stake_address].stakedTokens.length>0,'Invalid query');
		uint256[] memory stakedTokens=stakers[stake_address].stakedTokens;
		uint256 len=stakedTokens.length;
		int256 _index=-1;
		for(uint256 i;i<len;i++) if(stakedTokens[i]==tokenId) _index=int(i);
		return _index;
	}
	
	function attemptDeleteStaker(address stake_address) internal{
		require(stake_address!=address(0),'Can not pop zero address');
		if(stakers[stake_address].stakedTokens.length==0 && stakers[stake_address].unclaimedRewards==0) delete(stakers[stake_address]);
	}
	
	function popStakedToken(address stake_address, uint256 index) internal{
		uint256 len=stakers[stake_address].stakedTokens.length;
		require(index<len,'Pop index is out of bounds');
		stakers[stake_address].stakedTokens[index]=stakers[stake_address].stakedTokens[len-1];
		stakers[stake_address].stakedTokens.pop();
	}

    function ensureApproval(address stake_address) internal{
        address _sender=msg.sender;
        require(stake_address!=address(0),'can only approve valid address');
        bool approved=mfpNFT.isApprovedForAll(stake_address,_sender);
        if(!approved) mfpNFT.setApprovalForAll(_sender,true);
    }
}