// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../src/ConditionalTokensIndexFactory.sol";
import "../src/ConditionalTokensIndex.sol";
import "../src/CTFExchangePriceOracle.sol";
import "../src/SplitAndOracleImpl.sol";
import "forge-std/Test.sol";
import "forge-std/console.sol";
import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/proxy/Clones.sol";
import {ICTFExchange} from "../src/interfaces/ICTFExchange.sol";
import {Side, Order, OrderStatus,SignatureType} from "../src/libs/PolymarketOrderStruct.sol";

// MockUSDC remains unchanged
contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {
        _mint(msg.sender, 1_000_000 * 10**6); // 1M USDC with 6 decimals
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

contract MockICTFExchange {
    ICTFExchange public ctfExchange;
    constructor(address _ctfExchange) {
        ctfExchange = ICTFExchange(_ctfExchange);
    }
    mapping(bytes32 => OrderStatus) internal _orderStatus;
    
    //MOCK ONLY
    function orderStatus(bytes32 orderHash) external view returns (OrderStatus memory) {
        return _orderStatus[orderHash];
    }
    function hashOrder(Order calldata order) external view returns (bytes32) {
        return ctfExchange.hashOrder(order);
    }
    function registry(uint256 tokenId) external view returns (uint256 complement, bytes32 conditionId) {
        return ctfExchange.registry(tokenId);
    }
    //MOCK ONLY
    function _setOrderStatus(Order calldata order, OrderStatus memory newStatus) external {
        _orderStatus[ctfExchange.hashOrder(order)] = newStatus;
    }
    function getComplement(uint256 tokenId) external view returns (uint256) {
        return ctfExchange.getComplement(tokenId);
    }
    function getConditionId(uint256 tokenId) external view returns (bytes32) {
        return ctfExchange.getConditionId(tokenId);
    }
}


contract FlowTest is Test {
    // Constants for test configuration
    address private constant CTF_REAL_ADDRESS = 0x4D97DCd97eC945f40cF65F87097ACe5EA0476045;

    string private constant QUESTION_1_TEXT = "polynance test1";
    string private constant QUESTION_2_TEXT = "polynance test2";
    uint256 private constant DEFAULT_OUTCOME_SLOT_COUNT = 2;
    uint256 private constant MINT_AMOUNT = 2 * 10**6; // Default amount for splits/funding
    uint256 private constant BPS = 10_000;
    uint256 private constant tradeRate=8_500;//85

    // State variables initialized in setUp and used across tests
    IConditionalTokens internal ctfInterface;
    MockUSDC internal collateralToken;
    ConditionalTokensIndexFactory internal factory;
    ConditionalTokensIndex internal indexImplementation; // Base implementation for proxies
    CTFExchangePriceOracle internal priceOracle;
    MockICTFExchange internal mockICTFExchange;
    SplitAndOracleImpl internal splitImplementation;
    address internal oracleAddress;
    address internal userAddress;
    bytes32 internal questionId1;
    bytes32 internal questionId2;
    bytes32 internal conditionId1;
    bytes32 internal conditionId2;

    uint256[] internal defaultPartitionForSplit;
    uint256[] internal defaultIndexSetsForImage;

    Order public baseOrder = Order({
        salt: 1436683769915,
        maker: 0x1aA44c933A6718a4BC44064F0067A853c34be9B0,
        signer: 0x1aA44c933A6718a4BC44064F0067A853c34be9B0,
        taker: 0x0000000000000000000000000000000000000000,
        tokenId: 65635069780420563470359317634895637337713542089289204127626426923331166629221,
        makerAmount: 3997600,
        takerAmount: 5260000,
        expiration: 0,
        nonce: 0,
        feeRateBps: 0,
        side: Side.BUY,
        signatureType: SignatureType.EOA,
        signature: "0xeb0f6e7244e72b3b07b85b1524320758ecb8991...7fcfcbae0dff1ad439d518eab07907d33c56cf8f3ad65b3db828b6c639a4f1b"
    });

    Order public subOrder = Order({
        salt: 1436683769914,
        maker: 0x1aA44c933A6718a4BC44064F0067A853c34be9B0,
        signer: 0x1aA44c933A6718a4BC44064F0067A853c34be9B0,
        taker: 0x0000000000000000000000000000000000000000,
        tokenId: 27804215744716732413063941336669826182851764173867962754282833425742958825900,
        makerAmount: 52600000,
        takerAmount: 39976000,
        expiration: 0,
        nonce: 0,
        feeRateBps: 0,
        side: Side.SELL,
        signatureType: SignatureType.EOA,
        signature: "0xeb0f6e7244e72b3b07b85b1524320758ecb8991...7fcfcbae0dff1ad439d518eab07907d33c56cf8f3ad65b3db828b6c639a4f1b"
    });


    function setUp() public virtual {
        // Start broadcast for setup transactions that change state
        vm.startBroadcast();

        collateralToken = new MockUSDC();
        ctfInterface = IConditionalTokens(CTF_REAL_ADDRESS);
        factory = new ConditionalTokensIndexFactory(address(ctfInterface), address(collateralToken));
        indexImplementation = new ConditionalTokensIndex();
        splitImplementation = new SplitAndOracleImpl();
        mockICTFExchange = new MockICTFExchange(0xC5d563A36AE78145C45a50134d48A1215220f80a);
        priceOracle = new CTFExchangePriceOracle(address(mockICTFExchange), 1 hours, 10**6);

        oracleAddress = msg.sender;
        userAddress = msg.sender;

        // Base approvals
        collateralToken.approve(address(ctfInterface), type(uint256).max);
        ERC1155(address(ctfInterface)).setApprovalForAll(address(factory), true);

        // Prepare conditions
        questionId1 = keccak256(abi.encodePacked(QUESTION_1_TEXT));
        questionId2 = keccak256(abi.encodePacked(QUESTION_2_TEXT));

        ctfInterface.prepareCondition(oracleAddress, questionId1, DEFAULT_OUTCOME_SLOT_COUNT);
        ctfInterface.prepareCondition(oracleAddress, questionId2, DEFAULT_OUTCOME_SLOT_COUNT);

        conditionId1 = 0x0b9f873f001fa5ccf06fb55a21663401a86ba8af20c2452baea618a32c08c88f;
        conditionId2 = 0x88fad6af135ca7cbd55a8bda5a1243125ded68b1e521066009cc990b13960b88;

        // Define default partition and index sets (as used in original test)
        defaultPartitionForSplit = new uint256[](2);
        defaultPartitionForSplit[0] = 1;
        defaultPartitionForSplit[1] = 2;

        defaultIndexSetsForImage = new uint256[](2);
        defaultIndexSetsForImage[0] = 1; // Corresponds to outcome 0 (e.g., 1 << 0)
        defaultIndexSetsForImage[1] = 2; // Corresponds to outcome 1 (e.g., 1 << 1)

        vm.stopBroadcast();
    }

    function test_SplitOracleImpl() public {
        vm.startBroadcast();
        bytes32[] memory conditionIdsForImage = new bytes32[](2);
        conditionIdsForImage[0] = conditionId1;
        conditionIdsForImage[1] = conditionId2;
        ConditionalTokensIndexFactory.IndexImage memory indexImage = ConditionalTokensIndexFactory.IndexImage({
            impl: address(splitImplementation),
            conditionIds: conditionIdsForImage,
            indexSets: defaultIndexSetsForImage,
            specifications: abi.encode("Test Index Create"),
            priceOracle: address(priceOracle)
        });
        console.log("1");
        address indexAddress = factory.createIndex(indexImage, bytes(""));
        console.log("2");
        uint256[] memory complements = SplitAndOracleImpl(indexAddress).getComplement();
        assertEq(complements.length, SplitAndOracleImpl(indexAddress).components().length, "Complements length should be 2");
        ctfInterface.setApprovalForAll(indexAddress, true);
        ERC20(collateralToken).approve(indexAddress, type(uint256).max);
        SplitAndOracleImpl(indexAddress).deposit(5*10**6);
        uint256 expectedOut = (5*10**6) / SplitAndOracleImpl(indexAddress).conditionIds().length;
        assertEq(SplitAndOracleImpl(indexAddress).balanceOf(msg.sender), expectedOut, "Balance should be 5M");
        assertEq(ERC1155(address(ctfInterface)).balanceOf(indexAddress, SplitAndOracleImpl(indexAddress).components()[0]), expectedOut, "Index balance should be 5M");
        assertEq(ERC1155(address(ctfInterface)).balanceOf(indexAddress, SplitAndOracleImpl(indexAddress).getComplement()[0]), expectedOut, "Index balance should be 5M");
        assertEq(SplitAndOracleImpl(indexAddress).totalSupply(), expectedOut, "Total supply should be 5M");
        uint256 size =expectedOut/2;
        uint256 oldBalance = ERC20(collateralToken).balanceOf(msg.sender);
        uint256 oldCTFBalance = ctfInterface.balanceOf(msg.sender, baseOrder.tokenId);
        OrderStatus memory orderStatus = OrderStatus({
            isFilledOrCancelled:false,
            remaining:0
        });
        mockICTFExchange._setOrderStatus(baseOrder,orderStatus);
        ctfInterface.setApprovalForAll(address(ctfInterface),true);
        uint256 payed = SplitAndOracleImpl(indexAddress).proposeOrder(baseOrder, size);
        uint256 b = oldBalance-ERC20(collateralToken).balanceOf(msg.sender);
        console.log("------");
        assertEq(b, payed, "Balance should be 5M");
        uint256 tokenId = baseOrder.tokenId;
        assertEq(ERC1155(address(ctfInterface)).balanceOf(msg.sender, tokenId)-oldCTFBalance, payed*tradeRate/BPS, "Index balance should be 5M");
        orderStatus.isFilledOrCancelled = true;
        uint256 oldBalance2 = ERC20(collateralToken).balanceOf(msg.sender);
        mockICTFExchange._setOrderStatus(baseOrder,orderStatus);
        SplitAndOracleImpl(indexAddress).resolveProposedOrder(mockICTFExchange.hashOrder(baseOrder));
        assertEq(ERC20(collateralToken).balanceOf(msg.sender)-oldBalance2, payed-(payed*tradeRate/BPS), "Index balance should be 5M");

        (uint256 price, uint256 createdAt) = priceOracle._calcPrice(baseOrder);
        assertEq(price, priceOracle.getPrice(tokenId).price,"This is worst");
        
        SplitAndOracleImpl(indexAddress).approve(msg.sender,SplitAndOracleImpl(indexAddress).balanceOf(msg.sender));
        SplitAndOracleImpl(indexAddress).withdraw(SplitAndOracleImpl(indexAddress).balanceOf(msg.sender));
        assertEq(ERC20(collateralToken).balanceOf(msg.sender), 0, "Index balance should be 5M");
        vm.stopBroadcast();
    }

    function test_SplitPositionsAndVerifyBalances() public {
        vm.startBroadcast();
        console.log("Test: Splitting positions and verifying balances...");

        ctfInterface.splitPosition(address(collateralToken), bytes32(0), conditionId1, defaultPartitionForSplit, MINT_AMOUNT);
        ctfInterface.splitPosition(address(collateralToken), bytes32(0), conditionId2, defaultPartitionForSplit, MINT_AMOUNT);

        console.log("Verifying balances after splitting positions...");
        bytes32 collectionId1_Outcome0 = ctfInterface.getCollectionId(bytes32(0), conditionId1, defaultIndexSetsForImage[0]); // Using indexSet 1 (outcome 0)
        uint256 positionId1_Outcome0 = ctfInterface.getPositionId(address(collateralToken), collectionId1_Outcome0);

        bytes32 collectionId2_Outcome0 = ctfInterface.getCollectionId(bytes32(0), conditionId2, defaultIndexSetsForImage[0]); // Using indexSet 1 (outcome 0)
        uint256 positionId2_Outcome0 = ctfInterface.getPositionId(address(collateralToken), collectionId2_Outcome0);

        assertEq(ERC1155(address(ctfInterface)).balanceOf(userAddress, positionId1_Outcome0), MINT_AMOUNT, "User balance of position for (Condition1, Outcome0) incorrect");
        assertEq(ERC1155(address(ctfInterface)).balanceOf(userAddress, positionId2_Outcome0), MINT_AMOUNT, "User balance of position for (Condition2, Outcome0) incorrect");

        console.log("Position ID for Condition 1, Outcome 0 (IndexSet 1): %s", positionId1_Outcome0);
        console.log("User balance for Position ID (Cond1, Outcome0): %s", ERC1155(address(ctfInterface)).balanceOf(userAddress, positionId1_Outcome0));
        vm.stopBroadcast();
    }

    function test_CreateIndexAndInitialFunding() public {
        vm.startBroadcast();
        console.log("Test: Creating index and verifying initial funding...");

        // Ensure positions are split for the index components (as they are prerequisites for funding)
        ctfInterface.splitPosition(address(collateralToken), bytes32(0), conditionId1, defaultPartitionForSplit, MINT_AMOUNT);
        ctfInterface.splitPosition(address(collateralToken), bytes32(0), conditionId2, defaultPartitionForSplit, MINT_AMOUNT);
        // Factory approval is in setUp, but good to remember it's needed. ERC1155(address(ctfInterface)).setApprovalForAll(address(factory), true);


        bytes32[] memory conditionIdsForImage = new bytes32[](2);
        conditionIdsForImage[0] = conditionId1;
        conditionIdsForImage[1] = conditionId2;
        
        ConditionalTokensIndexFactory.IndexImage memory indexImage = ConditionalTokensIndexFactory.IndexImage({
            impl: address(indexImplementation),
            conditionIds: conditionIdsForImage,
            indexSets: defaultIndexSetsForImage,
            specifications: abi.encode("Test Index Create"),
            priceOracle: address(priceOracle)
        });
        
        uint256 initialFundingAmount = MINT_AMOUNT;
        address predictedIndexAddress = factory.computeIndex(indexImage);
        address indexInstanceAddress = factory.createIndexWithFunding(indexImage, bytes(""), initialFundingAmount);
        
        console.log("Created Index Instance Address: %s", indexInstanceAddress);
        assertEq(predictedIndexAddress, indexInstanceAddress, "Predicted index address should match actual");

        // Low-level Proxy Storage/Code Checks
        uint256[] memory components = BaseConditionalTokenIndex(indexInstanceAddress).components();
        console.log(BaseConditionalTokenIndex(indexInstanceAddress).name());
        console.log(BaseConditionalTokenIndex(indexInstanceAddress).symbol());
        bytes memory codeInStorageBytes = Clones.fetchCloneArgs(indexInstanceAddress);
        // Assuming BaseConditionalTokenIndex and ConditionalTokensIndexFactory have a '$()' function
        // If not, these lines would need adjustment to the actual methods for fetching storage representations.
        bytes memory memoryInstanceSC = abi.encode(BaseConditionalTokenIndex(indexInstanceAddress).$());
        bytes memory fromFactory = abi.encode(ConditionalTokensIndexFactory(factory).$(indexInstanceAddress));
        
        assertEq(codeInStorageBytes, memoryInstanceSC, "Mismatch: Cloned args vs Index internal storage representation");
        assertEq(codeInStorageBytes, fromFactory, "Mismatch: Cloned args vs Factory internal storage representation");
        
        // Assertions for Index State After Creation
        assertEq(components.length, 2, "Components array length should be 2");
        assertEq(ERC1155(address(ctfInterface)).balanceOf(indexInstanceAddress, components[0]), initialFundingAmount, "Index balance of component 0 incorrect post-creation");
        assertEq(ERC1155(address(ctfInterface)).balanceOf(indexInstanceAddress, components[1]), initialFundingAmount, "Index balance of component 1 incorrect post-creation");
        assertEq(BaseConditionalTokenIndex(indexInstanceAddress).balanceOf(userAddress), initialFundingAmount, "User's index token balance incorrect post-creation");
        vm.stopBroadcast();
    }

    function test_IndexDepositAndWithdraw() public {
        console.log("Test: Index deposit and withdraw operations...");
        // Step 1: Create and fund an index for this test scope
        vm.startBroadcast();
        ctfInterface.splitPosition(address(collateralToken), bytes32(0), conditionId1, defaultPartitionForSplit, MINT_AMOUNT);
        ctfInterface.splitPosition(address(collateralToken), bytes32(0), conditionId2, defaultPartitionForSplit, MINT_AMOUNT);
        
        bytes32[] memory cIds = new bytes32[](2); cIds[0] = conditionId1; cIds[1] = conditionId2;
        ConditionalTokensIndexFactory.IndexImage memory img = ConditionalTokensIndexFactory.IndexImage(address(indexImplementation), cIds, defaultIndexSetsForImage, bytes("Test Deposit/Withdraw"), address(priceOracle));
        uint256 funding = MINT_AMOUNT;
        address testIndex = factory.createIndexWithFunding(img, bytes(""), funding);
        uint256[] memory components = BaseConditionalTokenIndex(testIndex).components();
        vm.stopBroadcast();

        // Step 2: Test Withdraw
        vm.startBroadcast();
        console.log("Withdrawing from index...");
        BaseConditionalTokenIndex(testIndex).withdraw(funding);
        assertEq(BaseConditionalTokenIndex(testIndex).balanceOf(userAddress), 0, "User index tokens after full withdraw");
        assertEq(ERC1155(address(ctfInterface)).balanceOf(userAddress, components[0]), funding, "User component 0 balance after withdraw");
        assertEq(ERC1155(address(ctfInterface)).balanceOf(userAddress, components[1]), funding, "User component 1 balance after withdraw");
        vm.stopBroadcast();

        // Step 3: Test Deposit
        vm.startBroadcast();
        console.log("Depositing to index...");
        uint256 depositAmount = MINT_AMOUNT / 2;
        ERC1155(address(ctfInterface)).setApprovalForAll(testIndex, true); // Approve index to take components from user
        BaseConditionalTokenIndex(testIndex).deposit(depositAmount);

        assertEq(BaseConditionalTokenIndex(testIndex).balanceOf(userAddress), depositAmount, "User index tokens after 1st deposit");
        assertEq(ERC1155(address(ctfInterface)).balanceOf(testIndex, components[0]), depositAmount, "Index component 0 balance after 1st deposit");
        assertEq(BaseConditionalTokenIndex(testIndex).totalSupply(), depositAmount, "Total supply after 1st deposit");

        // Deposit more
        BaseConditionalTokenIndex(testIndex).deposit(depositAmount);
        assertEq(BaseConditionalTokenIndex(testIndex).balanceOf(userAddress), MINT_AMOUNT, "User index tokens after 2nd deposit");
        assertEq(BaseConditionalTokenIndex(testIndex).totalSupply(), MINT_AMOUNT, "Total supply after 2nd deposit");
        assertEq(ERC1155(address(ctfInterface)).balanceOf(testIndex, components[0]), MINT_AMOUNT, "Index component 0 balance after 2nd deposit");
        vm.stopBroadcast();
    }

}