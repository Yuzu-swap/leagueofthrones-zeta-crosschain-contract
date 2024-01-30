// SPDX-License-Identifier: MIT
pragma solidity 0.8.7;

import "@zetachain/protocol-contracts/contracts/zevm/SystemContract.sol";
import "@zetachain/protocol-contracts/contracts/zevm/interfaces/zContract.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@zetachain/toolkit/contracts/BytesHelperLib.sol";



enum SeasonStatus { Invalid, WaitForNTF ,Pending, End }

enum MappingStatus { Invalid, Valid }


struct ExtraGeneralIds {
    uint256[] generalIds;
    MappingStatus status;
}

//union Record
struct UnionRecord{
    address[] playerAddresses;
    uint256 unionId;
    mapping(address => ExtraGeneralIds) playerExtraGeneralIds;
    MappingStatus status;
}


//season record
struct SeasonRecord{
    mapping(uint256 => UnionRecord) unionRecords;
    mapping(address => uint256) unionIdMapping;
    mapping(address => uint256) unionRewardRecord;
    mapping(address => uint256) gloryRewardRecord;
    mapping(address => uint256) rechargeRecord;
    MappingStatus rechargeStatus;
    address rechargeAddress;
    uint256 sumPlayers;
    address ntf1ContractAddress;
    address ntf2ContractAddress;
    address rewardAddress;
    uint256 playerLimit;
    uint256 reward1Amount;
    uint256 reward2Amount;
    uint256 sumRecharge;
    uint256[] rankConfigFromTo;
    uint256[] rankConfigValue;
    //reservation open ready end
    uint256[] seasonTimeConfig;
    SeasonStatus seasonStatus;
    uint256 maxUnionDiffNum;

    mapping(address => bytes) playerStates;
}

struct SeaSonInfoResult{
    uint256 unionId;
    uint256[] generalIds;
}

struct SeasonStatusResult{
    uint256 sumPlayerNum;
    uint256[] unionsPlayerNum;
    uint256 maxUnionDiffNum;
}


struct NftAndRechargeConfig {
    address ntf1Address;
    address ntf2Address;
    address tokenAddress;
}

contract LeagueOfThronesV2 is Ownable,zContract{

    SystemContract public immutable systemContract;

    event OnCrossChainCall( zContext context, address zrc20, uint256 amount, bytes message);
    event PlayerStatesChanged( string seasonId, address player, bytes states);
    event startSeasonInfo( string seasonId, uint256 playerLimit, address rewardAddress, uint256 rewardAmount1, uint256 rewardAmount2, uint256[] rankConfigFromTo, uint256[] rankConfigValue, uint256[] seasonTimeConfig);
    event endSeasonInfo( string seasonId, uint256 unionId, address[] playerAddresses, uint256[] glorys, uint256 unionSumGlory);
    event sendRankRewardInfo( string seasonId, address player, uint256 rank, uint256 amount);
    event sendUnionRewardInfo( string seasonId, address player, uint256 glory, uint256 amount);
    event signUpInfo( string seasonId, uint256 chainId,address player, uint256 unionId, uint256[] extraGeneralIds,uint256 []originNFTIds,uint256 originUnionId);
    event rechargeInfo( string seasonId,uint256 chainId, address player, uint256 rechargeId,address token, uint256 amount, uint256 totalAmount);
    mapping( string => SeasonRecord) public seasonRecords;
    string public nowSeasonId;

    constructor(address systemContractAddress) public onlyOwner{
        systemContract = SystemContract(systemContractAddress);
    }


    modifier onlySystem() {
        require(
            msg.sender == address(systemContract),
            "Only system contract can call this function"
        );
        _;
    }

 

    //start season and transfer reward to contract
    function startSeason(
        string memory seasonId,
        uint256 playerLimit,
        address rewardAddress,
        uint256 rewardAmount1, 
        uint256 rewardAmount2, 
        uint256[] memory rankConfigFromTo,
        uint256[] memory rankConfigValue,
        uint256[] memory seasonTimeConfig,
        uint256 maxUnionDiffNum,
        NftAndRechargeConfig memory nftAndRechargeConfig
        ) external onlyOwner payable {
        SeasonRecord storage sRecord = seasonRecords[seasonId];
        require(sRecord.seasonStatus == SeasonStatus.Invalid, "Season can not start repeat");
        require(seasonTimeConfig.length == 4, "time config length error" );
        require(maxUnionDiffNum > 0, "maxUnionDiffNum must above zero" );

        uint256 rewordAmount = rewardAmount1 + rewardAmount2;
        //BSC version modify ,no need to pre transfer
        if (false) {
            if(rewardAddress == address(0x0)){
                require( msg.value == rewordAmount, "Check the ETH amount" );
            }
            else{
                IERC20 token = IERC20(rewardAddress);
                uint256 allowance = token.allowance(msg.sender, address(this));
                require(allowance >= rewordAmount, "Check the token allowance");
                token.transferFrom(msg.sender, address(this), rewordAmount);
            }
        }


       
        sRecord.rewardAddress = rewardAddress;
        sRecord.reward1Amount = rewardAmount1;
        sRecord.reward2Amount = rewardAmount2;
        sRecord.playerLimit = playerLimit;
        sRecord.maxUnionDiffNum = maxUnionDiffNum;
        require(rankConfigFromTo.length == rankConfigValue.length * 2, "rewardConfig length error");
        uint256 sumReward = 0;
        bool indexRight = true;
        uint256 lastEnd = 0;
        for(uint256 i = 0; i < rankConfigValue.length; i++){
            if(rankConfigFromTo[i * 2] != lastEnd + 1){
                indexRight = false;
                break;
            }
            lastEnd = rankConfigFromTo[i * 2 + 1];
            sumReward += ((rankConfigFromTo[i * 2 + 1] - rankConfigFromTo[i * 2 ] + 1) * rankConfigValue[i]);
        }
        require(indexRight && sumReward == rewardAmount2, "reward config error");
        sRecord.rankConfigFromTo = rankConfigFromTo;
        sRecord.rankConfigValue = rankConfigValue;
        sRecord.seasonTimeConfig = seasonTimeConfig;


        sRecord.ntf1ContractAddress = nftAndRechargeConfig.ntf1Address;
        sRecord.ntf2ContractAddress = nftAndRechargeConfig.ntf2Address;
        sRecord.rechargeStatus = MappingStatus.Valid;
        sRecord.rechargeAddress = nftAndRechargeConfig.tokenAddress;
        sRecord.seasonStatus = SeasonStatus.Pending;


        emit startSeasonInfo(seasonId, playerLimit, rewardAddress, rewardAmount1, rewardAmount2, rankConfigFromTo, rankConfigValue, seasonTimeConfig);
    }


    function setPlayerStates(string memory seasonId, uint unionId, bytes memory states) public {
        address player = msg.sender;
        SeasonRecord storage sRecord = seasonRecords[seasonId];
        bool hasSignUp = false;
        UnionRecord storage unionRecord = sRecord.unionRecords[unionId];
        if(unionRecord.status != MappingStatus.Invalid ){
            ExtraGeneralIds storage extraIds =  unionRecord.playerExtraGeneralIds[player];
            if(extraIds.status == MappingStatus.Valid){
                hasSignUp = true;
            }
        }

        require(hasSignUp == true , "player has not signUp");
        sRecord.playerStates[player] = states;
        emit PlayerStatesChanged(seasonId, player, states);
    }

    function getPlayerStates(string memory seasonId,address player ) public view returns (bytes memory){
        SeasonRecord storage sRecord = seasonRecords[seasonId];
        return sRecord.playerStates[player];
    }


    function getNFTAddresses(string memory seasonId ) public view returns (address[] memory){
        SeasonRecord storage sRecord = seasonRecords[seasonId];
        address[] memory addresses = new address[](2);
        addresses[0] = sRecord.ntf1ContractAddress;
        addresses[1] = sRecord.ntf2ContractAddress;
        return addresses;
    }

    function random(uint number) public view returns(uint) {
        return uint(keccak256(abi.encodePacked(block.timestamp,block.difficulty,  
            msg.sender))) % number;
    }


    function getRechargeToken(string memory seasonId) public view returns( address ) {
        SeasonRecord storage sRecord = seasonRecords[seasonId];
        return sRecord.rechargeAddress;
    }

    // params: 
    //  unionId:  0 for random
    function onSignUpGame(uint256 chainId,address player,string memory seasonId,uint256 unionId, uint256 ntf1TokenId, uint256 ntf2TokenId) internal{

        SeasonRecord storage sRecord = seasonRecords[seasonId];
        require(sRecord.seasonStatus == SeasonStatus.Pending, "Season Status Error");
        require( block.timestamp >= sRecord.seasonTimeConfig[0] && block.timestamp <= sRecord.seasonTimeConfig[3], "It is not signUp time now");
        require( sRecord.sumPlayers < sRecord.playerLimit, "the number of players has reached the limit");
        require( unionId >= 0 && unionId <= 4, "unionId error");


        // Record original unionId to detect whether the player select random unionId
        uint256 orginUnionId = unionId;
        uint256[] memory originNFTIds = new uint256[](2);
        originNFTIds[0] = ntf1TokenId;
        originNFTIds[1] = ntf2TokenId;




        // find wheather player has signUp and get union's player number
        uint256[] memory unionPlayerNum = new uint256[](5);
        uint256 minumUnionPlayerNum = sRecord.playerLimit;

        bool hasSignUp = false;
        for( uint i = 1 ; i <= 4 ; i ++ ){
            UnionRecord storage unionRecord = sRecord.unionRecords[i];
            if(unionRecord.status != MappingStatus.Invalid ){
                unionPlayerNum[i] = unionRecord.playerAddresses.length;
                ExtraGeneralIds storage extraIds =  unionRecord.playerExtraGeneralIds[player];
                if(extraIds.status == MappingStatus.Valid){
                    hasSignUp = true;
                    break;
                }
            }

            if(unionPlayerNum[i] < minumUnionPlayerNum){
                minumUnionPlayerNum = unionPlayerNum[i];
            }
        }
        require(hasSignUp == false , "player has signUp");
        // random unionId
        if (unionId!=0){
            // unionId maxUnionDiffNum check
            require(unionPlayerNum[unionId] - minumUnionPlayerNum < sRecord.maxUnionDiffNum, "unionId maxUnionDiffNum check error");
        }else{
            // random unionId of which player number is not above maxUnionDiffNum + currentUnionPlayerNum
            uint256[] memory unionIdsList = new uint256[](4);
            uint256 unionIdsListLen = 0;
            for( uint i = 1 ; i <= 4 ; i ++ ){
                if(unionPlayerNum[i] - minumUnionPlayerNum < sRecord.maxUnionDiffNum){
                    // add to unionIdsList
                    unionIdsList[unionIdsListLen] = i;
                    unionIdsListLen ++ ;
                }
            }

            // random unionId by block.timestamp
            bytes32 randomId = keccak256(abi.encodePacked(block.timestamp,block.difficulty,player));
            unionId = unionIdsList[uint(randomId) % unionIdsListLen];
        }

        // update season record
        sRecord.sumPlayers ++ ;
        sRecord.unionIdMapping[player] = unionId;
        UnionRecord storage unionRecord = sRecord.unionRecords[unionId];
        if(unionRecord.status == MappingStatus.Invalid){
            //gen union record
            unionRecord.status = MappingStatus.Valid;
            unionRecord.playerAddresses = new address[](0);
        }
        unionRecord.playerAddresses.push(player);

        //Random extra general
        ExtraGeneralIds storage extraIds = unionRecord.playerExtraGeneralIds[player];
        extraIds.generalIds = new uint256[](0);
        extraIds.status = MappingStatus.Valid;

        if(sRecord.ntf1ContractAddress != 0x0000000000000000000000000000000000000000  && ntf1TokenId != 0){
            IERC721 ntf1Contract = IERC721(sRecord.ntf1ContractAddress);
            try ntf1Contract.ownerOf(ntf1TokenId) returns(address owner){
                if(owner == player){
                    extraIds.generalIds.push(random(4) + 7);
                }
            }
            catch{
            }
        }


        if(sRecord.ntf2ContractAddress != 0x0000000000000000000000000000000000000000 && ntf2TokenId != 0){
            IERC721 ntf2Contract = IERC721(sRecord.ntf2ContractAddress);
            try ntf2Contract.ownerOf(ntf2TokenId) returns(address owner){
                if(owner == player){
                    extraIds.generalIds.push(random(4) + 11);
                }
            }
            catch{
                
            }
        }
        emit signUpInfo(seasonId ,chainId, player, unionId, extraIds.generalIds, originNFTIds, orginUnionId);
    }



    function onRecharge(uint256 chainId,address player,string memory seasonId, uint256 rechargeId ,address zrc20,uint256 amount) internal  {
        SeasonRecord storage sRecord = seasonRecords[seasonId];
        require(sRecord.seasonStatus == SeasonStatus.Pending, "Season Status Error");
        require(sRecord.rechargeStatus == MappingStatus.Valid, "recharge token have not set");
       // require(sRecord.rechargeAddress == zrc20, "recharge token address error");
        sRecord.rechargeRecord[player] += amount;
        sRecord.sumRecharge += amount;
        emit rechargeInfo(seasonId,chainId, player, rechargeId,zrc20, amount, sRecord.rechargeRecord[player]);
    }


    function onCrossChainCall(
        zContext calldata context,
        address zrc20,
        uint256 amount,
        bytes calldata message
    ) external virtual override onlySystem {
        address user = BytesHelperLib.bytesToAddress(context.origin, 0);
        uint8 action;
        string memory seasonId;

        (action,seasonId ) =  abi.decode(message, (uint8,string));
        if (action == 1) { // signUp
            uint256 unionId;
            uint256 ntf1TokenId;
            uint256 ntf2TokenId;
            (,, unionId, ntf1TokenId, ntf2TokenId)   = abi.decode(message, (uint8,string,uint256,uint256,uint256));
            onSignUpGame(context.chainID,user,seasonId,unionId, ntf1TokenId, ntf2TokenId);

        } else if (action ==2) { //recharge
            uint256 rechargeId;
            (,,rechargeId)   = abi.decode(message, (uint8,string,uint256));
            onRecharge(context.chainID,user,seasonId, rechargeId ,zrc20,amount);
        }

        emit OnCrossChainCall(context, zrc20, amount, message);

    }

    function getRechargeInfo( string memory seasonId, address player) public view returns (uint256, uint256){
        SeasonRecord storage sRecord = seasonRecords[seasonId];
        require(sRecord.seasonStatus != SeasonStatus.Invalid, "Season is not exist");
        return (sRecord.rechargeRecord[player], sRecord.sumRecharge);
    }


    function getSeasonStatus( string memory seasonId ) public view returns ( SeasonStatusResult memory ){
        SeasonRecord storage sRecord = seasonRecords[seasonId];
        require(sRecord.seasonStatus == SeasonStatus.Pending, "Season Status Error");
        SeasonStatusResult memory re = SeasonStatusResult( sRecord.sumPlayers , new uint256[](4),sRecord.maxUnionDiffNum);
        for( uint i = 1 ; i <= 4 ; i ++ ){
            UnionRecord storage unionRecord = sRecord.unionRecords[i];
            if(unionRecord.status == MappingStatus.Invalid ){
                re.unionsPlayerNum[i-1] = 0;
            }
            else{
                re.unionsPlayerNum[i-1] = unionRecord.playerAddresses.length;
            }
        }
        return re;
    } 

    function getSignUpInfo( string memory seasonId, address playerAddress) public view returns ( SeaSonInfoResult memory){
        SeasonRecord storage sRecord = seasonRecords[seasonId];
        SeaSonInfoResult memory re = SeaSonInfoResult(0, new uint256[](0));
        for( uint i = 1 ; i <= 4 ; i ++ ){
            UnionRecord storage unionRecord = sRecord.unionRecords[i];
            if(unionRecord.status == MappingStatus.Invalid ){
                continue;
            }
            else{
                ExtraGeneralIds storage extraIds = unionRecord.playerExtraGeneralIds[playerAddress];
                if(extraIds.status == MappingStatus.Invalid){
                    continue;
                }
                re.unionId = i;
                re.generalIds = extraIds.generalIds;
            }
        }
        return re;
    }

    function endSeason(  string memory seasonId, uint256 unionId, address[] memory playerAddresses, uint256[] memory glorys, uint256 unionSumGlory) external onlyOwner {
        SeasonRecord storage sRecord = seasonRecords[seasonId];
        require(sRecord.seasonStatus == SeasonStatus.Pending,  "Season Status Error");
        require(playerAddresses.length == glorys.length, "input array length do not equal");
        uint fromToIndex = 0;
        uint rankMax = sRecord.rankConfigFromTo[sRecord.rankConfigFromTo.length - 1];
        //IERC20 token = IERC20(sRecord.rewardAddress);
        for(uint i = 0; i < playerAddresses.length; i++ ){  
            address playerAddress = playerAddresses[i];
            uint256 glory = glorys[i];
            if(sRecord.unionIdMapping[playerAddress] == unionId){
               uint256 amount = glory * sRecord.reward1Amount / unionSumGlory;
               sRecord.unionRewardRecord[playerAddress] = amount; 
               transferReward(sRecord.rewardAddress, playerAddress, amount);
               //if( token.transfer(playerAddress, amount)){
               emit sendUnionRewardInfo(seasonId, playerAddress, glory, amount);
               //}
            }
            if(i < rankMax){
               uint256 to = sRecord.rankConfigFromTo[fromToIndex * 2 + 1];
               if( i + 1 > to ){
                  fromToIndex += 1;
               }
               uint256 amount = sRecord.rankConfigValue[fromToIndex];
               sRecord.gloryRewardRecord[playerAddress] = amount;
               transferReward(sRecord.rewardAddress, playerAddress, amount);
               //if( token.transfer(playerAddress, amount)){
               emit sendRankRewardInfo(seasonId, playerAddress, i + 1, amount);
               //}
            }
        }
        emit endSeasonInfo( seasonId,  unionId,  playerAddresses, glorys, unionSumGlory);
    }

    function withdraw( address tokenAddress, uint256 amount) external  onlyOwner{
        if(tokenAddress == address(0x0)){
            require(address(this).balance >=  amount, "balance is not enough");
            payable(msg.sender).transfer(amount);
        }
        else{
            IERC20 token = IERC20(tokenAddress);
            uint256 balance = token.balanceOf(address(this));
            require(balance >= amount, "balance is not enough");
            token.transfer(msg.sender, amount);
        }
    }

    function transferReward(address rewardAddress, address toAddress, uint256 amount) internal {
        if(rewardAddress == address(0x0)){
            require(address(this).balance >=  amount, "balance is not enough");
            payable(toAddress).transfer(amount);
        }
        else{
            IERC20 token = IERC20(rewardAddress);
            uint256 balance = token.balanceOf(address(this));
            require(balance >= amount, "balance is not enough");
            token.transfer(toAddress, amount);
        }
    }

 
}






