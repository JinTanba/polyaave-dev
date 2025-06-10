// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../src/ConditionalTokensIndexFactory.sol";
import "../src/ConditionalTokensIndex.sol";
import "../src/interfaces/ICTFExchange.sol";
import "../src/CTFExchangePriceOracle.sol";
import "../src/SplitAndOracleImpl.sol";
import "forge-std/Script.sol";
import "forge-std/console.sol";
import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract Compose is Script {
    address polymarket = 0xC5d563A36AE78145C45a50134d48A1215220f80a;
    address collateral =0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174;
    IConditionalTokens ctf = IConditionalTokens(0x4D97DCd97eC945f40cF65F87097ACe5EA0476045);
    ConditionalTokensIndexFactory factory = ConditionalTokensIndexFactory(0xC01BbFC94C41F0D8Fc242cFe8465ea4dcD4f20C5);
    ConditionalTokensIndex indexImpl = ConditionalTokensIndex(0x70f7f2299B254e2E53ae7D67eb85d7bBE10CaDde);
    SplitAndOracleImpl splitImpl = SplitAndOracleImpl(0x7bcd278Bb230fF014149cE32c5a9663812Da9810);
    CTFExchangePriceOracle priceOracle = CTFExchangePriceOracle(0x3De278A5acdD0123eD668478ac8cCd2E178510BC);
//   {
//     conditionId: '0x41a7b02edc7e1e56661022289f4462a8870239e73b389b8eadd0b5ecde161a78',
//     exchangeId: '522638',
//     position: 'No'
//   },
//   {
//     conditionId: '0x0b9f873f001fa5ccf06fb55a21663401a86ba8af20c2452baea618a32c08c88f',
//     exchangeId: '522637',
//     position: 'Yes'
//   },
//   {
//     conditionId: '0x88fad6af135ca7cbd55a8bda5a1243125ded68b1e521066009cc990b13960b88',
//     exchangeId: '517000',
//     position: 'No'
//   },
//   {
//     conditionId: '0x22bfce8b3fc9e6b23088dad87c8b90771b3b47495d5f2dd76a0b8e45c2e5637b',
//     exchangeId: '532750',
//     position: 'No'
//   }
    function run() public {
        vm.startBroadcast();
        ERC20(collateral).approve(address(ctf), type(uint256).max);
        // const indexAddresses = [
        // "0xC01BbFC94C41F0D8Fc242cFe8465ea4dcD4f20C5",
        // "0x787dE5d30d327Ed20b3CaE7227f0aEcAcda2852E",
        // "0x2f583fa67768b4d0c092ce35455202602ec60c76",
        // "0x0557EceeAD263249368B07E12e9f6C1FC59878eB",
        // "0xd189321231B8A71493506eC87b959bed191E8f4d",
        // ]
        address[] memory indexAddresses = new address[](5);
        indexAddresses[0] = 0xd189321231B8A71493506eC87b959bed191E8f4d;
        indexAddresses[1] = 0x787dE5d30d327Ed20b3CaE7227f0aEcAcda2852E;
        indexAddresses[2] = 0x0557EceeAD263249368B07E12e9f6C1FC59878eB;
        indexAddresses[3] = 0x0557EceeAD263249368B07E12e9f6C1FC59878eB;
        indexAddresses[4] = 0xd189321231B8A71493506eC87b959bed191E8f4d;
        
        for(uint256 i;i<indexAddresses.length;i++) {
            // ERC20(collateral).approve(indexAddresses[i], 6**6);
            SplitAndOracleImpl(indexAddresses[i]).deposit(6**6);
        }
            
        // bytes32[] memory conditions = new bytes32[](4);
        // uint256[] memory indexSets = new uint256[](4);
        // conditions[0] = 0x41a7b02edc7e1e56661022289f4462a8870239e73b389b8eadd0b5ecde161a78;
        // indexSets[0] = 1;//516960
        // conditions[1] = 0x0b9f873f001fa5ccf06fb55a21663401a86ba8af20c2452baea618a32c08c88f;
        // indexSets[1] = 0;//543148
        // conditions[2] = 0x88fad6af135ca7cbd55a8bda5a1243125ded68b1e521066009cc990b13960b88;
        // indexSets[2] = 1;//528716
        // conditions[3] = 0x22bfce8b3fc9e6b23088dad87c8b90771b3b47495d5f2dd76a0b8e45c2e5637b;
        // indexSets[3] = 1;//528717

        // uint256 perUsdc = 1*10**6;
        // uint256[] memory yesSlots = new uint256[](conditions.length);
        // uint256[] memory noSlots = new uint256[](conditions.length);
        // uint256[] memory binary = new uint256[](2);
        // binary[0] = 1;
        // binary[1] = 2;
        // for(uint256 i=0;i<conditions.length;i++){
        //     bytes32 conditionId = conditions[i];
        //     uint256 slots = ctf.getOutcomeSlotCount(conditionId);
        //     require(slots>0,"InvalidCondition");
        //     yesSlots[i] = 1;
        //     noSlots[i] = 2;
        //     // ctf.splitPosition(collateral,bytes32(0),conditionId,binary,perUsdc);
        // } 

        // ConditionalTokensIndexFactory.IndexImage memory yes517=ConditionalTokensIndexFactory.IndexImage({
        //     impl:address(splitImpl),
        //     conditionIds:conditions,
        //     indexSets:yesSlots,
        //     specifications:abi.encode("Cos Similarity 0.7 Japan"),
        //     priceOracle:address(priceOracle)
        // });

        // console.log("yes517");
        
        // ctf.setApprovalForAll(address(factory),true);
        // address yes517Instance = factory.createIndex(yes517,bytes(""));

        // ERC20(collateral).approve(yes517Instance, type(uint256).max);
        // ctf.setApprovalForAll(yes517Instance,true);
        // SplitAndOracleImpl(yes517Instance).deposit(perUsdc);
        // if(SplitAndOracleImpl(yes517Instance).balanceOf(msg.sender)==0)revert("InvalidBalance");  
        // uint256 totalSupply = SplitAndOracleImpl(yes517Instance).totalSupply();
        // if(totalSupply==0)revert("InvalidTotalSupply");
        // SplitAndOracleImpl(yes517Instance).withdraw(SplitAndOracleImpl(yes517Instance).balanceOf(msg.sender));
        // console.log("yes517Instance");
        // console.logAddress(yes517Instance);
        // require(ctf.balanceOf(msg.sender,SplitAndOracleImpl(yes517Instance).components()[0])==perUsdc,"InvalidBalance");
        // vm.stopBroadcast();
    }


}
